import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/auth/session_vault.dart';
import 'package:kingclub_cash_register/src/auth/staff_auth_controller.dart';
import 'package:kingclub_cash_register/src/live/cash_command.dart';
import 'package:kingclub_cash_register/src/live/cash_journal.dart';
import 'package:kingclub_cash_register/src/network/ccsop_client.dart';

import 'cash_command_test.dart' as c;
import 'staff_session_test.dart' as a;

class Api extends a.TestApi {
  Api(this.storage);
  final c.Storage storage;
  final calls = <(String, Map<String, dynamic>)>[];
  Map<String, dynamic>? prepared, paid, closureReceipt;
  bool soldOut = false,
      failPrepare = false,
      failConfirm = false,
      expired = false,
      lookupFails = false;
  Completer<void>? gate;
  final confirming = Completer<void>();
  @override
  Future<Object?> call(String id, Map<String, dynamic> params) async {
    if (id == 'K260929001904') return super.call(id, params);
    calls.add((id, Map.of(params)));
    final raw = storage.data[CashJournal.storageKey];
    expect(raw, isNotNull);
    final entry = PendingCash.decode(
      (jsonDecode(raw!)['entries'] as List).single,
    );
    if (id == 'K260929001915') {
      expect(entry.params, params);
      prepared = c.prepared(entry);
      if (failPrepare) {
        throw const CcsopFailure('TRANSPORT_FAILED', deliveryUncertain: true);
      }
      return {'result': prepared};
    }
    if (id == 'K260929001917') {
      if (lookupFails) throw const CcsopFailure('TRANSPORT_FAILED');
      if (paid != null || closureReceipt != null) {
        return {
          'result': {
            'state': paid != null ? 'confirmed' : 'closed',
            'requestId': entry.requestId,
            'receipt': paid ?? closureReceipt,
          },
        };
      }
      if (prepared == null) {
        return {
          'result': {'state': 'not_observed', 'requestId': entry.requestId},
        };
      }
      return {
        'result': {...c.observed(entry), 'canConfirmCash': !expired},
      };
    }
    if (id == 'K260929001916') {
      expect(entry.confirm, params);
      expect(entry.receivedCents, 200);
      if (soldOut) throw const CcsopFailure('ORDERING_OUT_OF_STOCK');
      paid = c.receipt(entry);
      if (!confirming.isCompleted) confirming.complete();
      if (gate != null) await gate!.future;
      if (failConfirm) {
        throw const CcsopFailure('TRANSPORT_FAILED', deliveryUncertain: true);
      }
      return {'result': paid};
    }
    if (id == 'K260929001918') {
      expect(entry.close, params);
      closureReceipt = c.closure(entry);
      return {'result': closureReceipt};
    }
    throw StateError('UNEXPECTED_TEST_INTERFACE');
  }
}

Future<StaffAuthController> controller(
  c.Storage storage,
  Api api, {
  DateTime Function()? now,
}) async {
  storage.data[SessionVault.deviceKey] = a.device;
  final auth = a.TestAuth()
    ..result = {
      ...a.response(),
      'permissions': ['workbench.read', 'payment.cash'],
    };
  final value = StaffAuthController(
    vault: SessionVault(storage: storage),
    cashJournal: CashJournal(storage: storage),
    authFactory: (_) => auth,
    sessionFactory: (_) => api,
    now: now ?? () => a.now,
  );
  await value.login(
    base: 'https://service.invalid/prefix',
    storeRef: 'test-store',
    loginName: 'TEST_ONLY',
    password: 'TEST_ONLY',
  );
  return value;
}

Future<String> prepare(StaffAuthController auth) async {
  expect(
    (await auth.prepareCash(
      orderRef: 'D00000000001',
      totalCents: 100,
      confirmed: true,
    )).state,
    CashState.needsLookup,
  );
  return (await auth.pendingCash()).single.requestId;
}

void main() {
  test('sold-out cash preserves receipt decision and only closes after explicit cash return', () async {
    final storage = c.Storage(),
        api = Api(storage)..soldOut = true,
        auth = await controller(storage, api);
    addTearDown(auth.dispose);
    final id = await prepare(auth);
    await expectLater(
      auth.confirmCash(id, receivedCents: 200, cashReceivedConfirmed: true),
      c.fails('ORDERING_OUT_OF_STOCK'),
    );
    expect((await auth.pendingCash()).single.receivedCents, 200);
    expect(api.paid, isNull);
    expect(
      (await auth.closeCash(id, cashReturnedConfirmed: true)).state,
      CashState.closed,
    );
    expect(api.closureReceipt!['cashReturnedConfirmed'], isTrue);
    expect(
      api.closureReceipt!.containsKey('noCashCollectedConfirmed'),
      isFalse,
    );
    expect(await auth.pendingCash(), isEmpty);
  });

  test('new controller reloads lost payment decision and only looks up the original request', () async {
    final storage = c.Storage(),
        api = Api(storage)..failConfirm = true,
        auth = await controller(storage, api);
    final id = await prepare(auth);
    await expectLater(
      auth.confirmCash(id, receivedCents: 200, cashReceivedConfirmed: true),
      c.fails('TRANSPORT_FAILED'),
    );
    auth.dispose();
    final nextApi = Api(storage)
      ..prepared = api.prepared
      ..paid = api.paid;
    final resumed = await controller(storage, nextApi);
    addTearDown(resumed.dispose);
    expect((await resumed.pendingCash()).single.receivedCents, 200);
    expect((await resumed.recoverCash(id)).state, CashState.confirmed);
    expect(nextApi.calls.map((c) => c.$1), ['K260929001917']);
    expect(await resumed.pendingCash(), isEmpty);
  });
  test('persist then prepare, lookup and explicit confirmation; only verified receipt clears', () async {
    final storage = c.Storage(),
        api = Api(storage),
        auth = await controller(storage, api);
    addTearDown(auth.dispose);
    final id = await prepare(auth);
    expect((await auth.recoverCash(id)).state, CashState.prepared);
    final result = await auth.confirmCash(
      id,
      receivedCents: 200,
      cashReceivedConfirmed: true,
    );
    expect(result.state, CashState.confirmed);
    expect(await auth.pendingCash(), isEmpty);
    expect(api.calls.map((v) => v.$1), [
      'K260929001915',
      'K260929001917',
      'K260929001917',
      'K260929001916',
    ]);
  });
  test('lost prepare response retains same UUID and recovers without another prepare', () async {
    final storage = c.Storage(),
        api = Api(storage)..failPrepare = true,
        auth = await controller(storage, api);
    addTearDown(auth.dispose);
    await expectLater(
      auth.prepareCash(
        orderRef: 'D00000000001',
        totalCents: 100,
        confirmed: true,
      ),
      c.fails('TRANSPORT_FAILED'),
    );
    final pending = (await auth.pendingCash()).single;
    expect(pending.intentRef, isNull);
    expect(
      (await auth.recoverCash(pending.requestId)).state,
      CashState.prepared,
    );
    expect((await auth.pendingCash()).single.intentRef, c.intent);
    expect(api.calls.where((v) => v.$1 == 'K260929001915'), hasLength(1));
  });
  test('lost confirmation response only reads back; physical decision remains immutable', () async {
    final storage = c.Storage(),
        api = Api(storage)..failConfirm = true,
        auth = await controller(storage, api);
    addTearDown(auth.dispose);
    final id = await prepare(auth);
    await expectLater(
      auth.confirmCash(id, receivedCents: 200, cashReceivedConfirmed: true),
      c.fails('TRANSPORT_FAILED'),
    );
    expect((await auth.pendingCash()).single.receivedCents, 200);
    await expectLater(
      auth.closeCash(id, noCashCollectedConfirmed: true),
      c.fails('CASH_DECISION_CONFLICT'),
    );
    await expectLater(
      auth.confirmCash(id, receivedCents: 201, cashReceivedConfirmed: true),
      c.fails('CASH_DECISION_CONFLICT'),
    );
    expect((await auth.recoverCash(id)).state, CashState.confirmed);
    expect(api.calls.where((v) => v.$1 == 'K260929001916'), hasLength(1));
    expect(await auth.pendingCash(), isEmpty);
  });
  test(
    'explicit no-cash closure is durable first, including expired preparation',
    () async {
      final storage = c.Storage(),
          api = Api(storage)..expired = true,
          auth = await controller(storage, api);
      addTearDown(auth.dispose);
      final id = await prepare(auth);
      expect(
        (await auth.closeCash(id, noCashCollectedConfirmed: true)).state,
        CashState.closed,
      );
      expect(api.calls.map((v) => v.$1), [
        'K260929001915',
        'K260929001917',
        'K260929001918',
      ]);
      expect(await auth.pendingCash(), isEmpty);
    },
  );
  test(
    'no automatic retry after not_observed; explicit original retry keeps UUID',
    () async {
      final storage = c.Storage(),
          api = Api(storage)..failPrepare = true,
          auth = await controller(storage, api);
      addTearDown(auth.dispose);
      await expectLater(
        auth.prepareCash(
          orderRef: 'D00000000001',
          totalCents: 100,
          confirmed: true,
        ),
        c.fails('TRANSPORT_FAILED'),
      );
      api.prepared = null;
      api.failPrepare = false;
      final id = (await auth.pendingCash()).single.requestId;
      expect((await auth.recoverCash(id)).state, CashState.notObserved);
      expect(api.calls, hasLength(2));
      await auth.recoverCash(id, retryOriginalPreparation: true);
      final sent = api.calls.where((v) => v.$1 == 'K260929001915').toList();
      expect(sent, hasLength(2));
      expect(sent[0].$2, sent[1].$2);
    },
  );
  test('storage failure prevents first packet and decision packets', () async {
    final storage = c.Storage(),
        api = Api(storage),
        auth = await controller(storage, api);
    addTearDown(auth.dispose);
    storage.drop = true;
    await expectLater(
      auth.prepareCash(
        orderRef: 'D00000000001',
        totalCents: 100,
        confirmed: true,
      ),
      c.fails('CASH_JOURNAL_UNAVAILABLE'),
    );
    expect(api.calls, isEmpty);
    storage.drop = false;
    final id = await prepare(auth);
    storage.drop = true;
    await expectLater(
      auth.confirmCash(id, receivedCents: 200, cashReceivedConfirmed: true),
      c.fails('CASH_JOURNAL_UNAVAILABLE'),
    );
    expect(api.calls, hasLength(1));
  });
  test(
    'failed lookup preserves cash decision and does not send confirm',
    () async {
      final storage = c.Storage(),
          api = Api(storage),
          auth = await controller(storage, api);
      addTearDown(auth.dispose);
      final id = await prepare(auth);
      api.lookupFails = true;
      await expectLater(
        auth.confirmCash(id, receivedCents: 200, cashReceivedConfirmed: true),
        c.fails('TRANSPORT_FAILED'),
      );
      expect((await auth.pendingCash()).single.receivedCents, 200);
      expect(api.calls.where((v) => v.$1 == 'K260929001916'), isEmpty);
    },
  );
  test('expired order cannot confirm; no-cash lie remains forbidden after physical receipt', () async {
    final storage = c.Storage(),
        api = Api(storage)..expired = true,
        auth = await controller(storage, api);
    addTearDown(auth.dispose);
    final id = await prepare(auth);
    await expectLater(
      auth.confirmCash(id, receivedCents: 200, cashReceivedConfirmed: true),
      c.fails('CASH_REVIEW_REQUIRED'),
    );
    expect(api.calls.where((v) => v.$1 == 'K260929001916'), isEmpty);
    expect((await auth.pendingCash()).single.receivedCents, 200);
  });
  test('logout rejects late successful receipt without clearing original decision; concurrent cash blocked', () async {
    final storage = c.Storage(),
        api = Api(storage)..gate = Completer<void>(),
        auth = await controller(storage, api);
    addTearDown(auth.dispose);
    final id = await prepare(auth),
        pending = auth.confirmCash(
          id,
          receivedCents: 200,
          cashReceivedConfirmed: true,
        );
    final rejected = expectLater(pending, c.fails('SESSION_CHANGED'));
    await api.confirming.future;
    await expectLater(auth.recoverCash(id), c.fails('CASH_IN_PROGRESS'));
    await auth.logout();
    api.gate!.complete();
    await rejected;
    expect(
      (await CashJournal(storage: storage).load(c.identity))
          .single
          .receivedCents,
      200,
    );
  });
  test(
    'unconfirmed actions and expired employee session send nothing',
    () async {
      var now = a.now;
      final storage = c.Storage(),
          api = Api(storage),
          auth = await controller(storage, api, now: () => now);
      addTearDown(auth.dispose);
      await expectLater(
        auth.prepareCash(
          orderRef: 'D00000000001',
          totalCents: 100,
          confirmed: false,
        ),
        c.fails('CASH_CONFIRMATION_REQUIRED'),
      );
      await expectLater(
        auth.confirmCash(
          'missing',
          receivedCents: 200,
          cashReceivedConfirmed: false,
        ),
        c.fails('CASH_CONFIRMATION_REQUIRED'),
      );
      now = now.add(const Duration(hours: 1));
      await expectLater(auth.pendingCash(), c.fails('SESSION_REQUIRED'));
      expect(api.calls, isEmpty);
    },
  );
}
