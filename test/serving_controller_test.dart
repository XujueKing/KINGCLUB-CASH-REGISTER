import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/auth/session_vault.dart';
import 'package:kingclub_cash_register/src/auth/staff_auth_controller.dart';
import 'package:kingclub_cash_register/src/live/serving_command.dart';
import 'package:kingclub_cash_register/src/live/serving_journal.dart';
import 'package:kingclub_cash_register/src/network/ccsop_client.dart';

import 'serving_command_test.dart' as s;
import 'staff_session_test.dart' as a;
import 'cash_command_test.dart' show Storage;

class Api extends a.TestApi {
  Api(this.storage);
  final Storage storage;
  final calls = <(String, Map<String, dynamic>)>[];
  Object? saved;
  bool loseResponse = false, rejectBeforeCommit = false, badReceipt = false;
  Completer<void>? gate;
  final sending = Completer<void>();
  @override
  Future<Object?> call(String id, Map<String, dynamic> params) async {
    if (id == 'K260929001904') return super.call(id, params);
    calls.add((id, Map.of(params)));
    final raw = storage.data[ServingJournal.storageKey];
    expect(raw, isNotNull);
    final command = PendingServing.decode(
      (jsonDecode(raw!)['entries'] as List).single,
    );
    if (id == (command.recall ? 'K261002001968' : 'K260929001920')) {
      expect(params, command.lookup);
      return saved ??
          {
            'result': {'state': 'not_observed', 'requestId': command.requestId},
          };
    }
    expect(id, command.recall ? 'K261002001967' : 'K260929001919');
    expect(params, command.params);
    if (!sending.isCompleted) sending.complete();
    if (gate != null) await gate!.future;
    if (rejectBeforeCommit) {
      throw const CcsopFailure('TRANSPORT_FAILED', deliveryUncertain: true);
    }
    saved = s.result(command);
    if (loseResponse) {
      throw const CcsopFailure('TRANSPORT_FAILED', deliveryUncertain: true);
    }
    if (badReceipt) {
      return {
        'result': {
          'state': 'confirmed',
          'requestId': command.requestId,
          'receipt': {...s.receipt(command), 'servedBy': 'E00000000002'},
        },
      };
    }
    return saved;
  }
}

Future<StaffAuthController> controller(
  Storage storage,
  Api api, {
  DateTime Function()? now,
  bool allowed = true,
}) async {
  storage.data[SessionVault.deviceKey] = a.device;
  final auth = a.TestAuth()
    ..result = {
      ...a.response(),
      'permissions': ['workbench.read', if (allowed) 'orders.serve'],
    };
  final value = StaffAuthController(
    vault: SessionVault(storage: storage),
    servingJournal: ServingJournal(storage: storage),
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

Future<ServingResult> submit(
  StaffAuthController auth, {
  bool confirmed = true,
}) => auth.confirmServing(
  tableRef: 'TEST_TABLE',
  sessionRef: 'H00000000001',
  orderRef: 'D00000000001',
  productRef: 'TEST_PRODUCT',
  quantity: 4,
  expectedServedQuantity: 1,
  targetServedQuantity: 3,
  confirmed: confirmed,
);

void main() {
  test('lost recall response recovers the same durable command without repeating the write', () async {
    final storage = Storage();
    final actualApi = Api(storage)..loseResponse = true;
    final auth = await controller(storage, actualApi);
    await expectLater(
      auth.confirmServing(
        tableRef: 'TEST_TABLE',
        sessionRef: 'H00000000001',
        orderRef: 'D00000000001',
        productRef: 'TEST_PRODUCT',
        quantity: 4,
        expectedServedQuantity: 2,
        targetServedQuantity: 0,
        expectedServingEpoch: 1,
        confirmed: true,
      ),
      throwsA(isA<CcsopFailure>()),
    );
    final pending = (await auth.pendingServing()).single;
    expect(pending.recall, true);
    expect((await auth.recoverServing(pending.requestId)).confirmed, true);
    expect(actualApi.calls.map((c) => c.$1), [
      'K261002001967',
      'K261002001968',
    ]);
    expect(await auth.pendingServing(), isEmpty);
    auth.dispose();
  });
  test(
    'durable original exists before network; verified receipt alone clears it',
    () async {
      final storage = Storage(),
          api = Api(storage),
          auth = await controller(storage, api);
      addTearDown(auth.dispose);
      expect((await submit(auth)).confirmed, true);
      expect(await auth.pendingServing(), isEmpty);
      expect(api.calls.map((e) => e.$1), ['K260929001919']);
    },
  );
  test('restart after lost response only looks up original and never repeats physical delivery', () async {
    final storage = Storage(),
        api = Api(storage)..loseResponse = true,
        auth = await controller(storage, api);
    await expectLater(submit(auth), s.fails('TRANSPORT_FAILED'));
    final id = (await auth.pendingServing()).single.requestId;
    auth.dispose();
    final nextApi = Api(storage)..saved = api.saved,
        next = await controller(storage, nextApi);
    addTearDown(next.dispose);
    expect((await next.recoverServing(id)).confirmed, true);
    expect(nextApi.calls.map((e) => e.$1), ['K260929001920']);
    expect(await next.pendingServing(), isEmpty);
  });
  test('not observed stays unresolved until explicitly retrying identical original parameters', () async {
    final storage = Storage(),
        api = Api(storage)..rejectBeforeCommit = true,
        auth = await controller(storage, api);
    addTearDown(auth.dispose);
    await expectLater(submit(auth), s.fails('TRANSPORT_FAILED'));
    final original = (await auth.pendingServing()).single;
    expect((await auth.recoverServing(original.requestId)).confirmed, false);
    expect(api.calls.map((e) => e.$1), ['K260929001919', 'K260929001920']);
    await expectLater(submit(auth), s.fails('SERVING_ALREADY_PENDING'));
    api.rejectBeforeCommit = false;
    expect(
      (await auth.recoverServing(
        original.requestId,
        retryOriginal: true,
      )).confirmed,
      true,
    );
    expect(api.calls.last.$2, original.params);
    expect(api.calls.map((e) => e.$1), [
      'K260929001919',
      'K260929001920',
      'K260929001920',
      'K260929001919',
    ]);
  });
  test('storage failure blocks network; missing confirmation and permission never save', () async {
    final storage = Storage(),
        api = Api(storage),
        auth = await controller(storage, api);
    addTearDown(auth.dispose);
    await expectLater(
      submit(auth, confirmed: false),
      s.fails('SERVING_CONFIRMATION_REQUIRED'),
    );
    storage.drop = true;
    await expectLater(submit(auth), s.fails('SERVING_JOURNAL_UNAVAILABLE'));
    expect(api.calls, isEmpty);
    storage.drop = false;
    final denied = await controller(storage, api, allowed: false);
    addTearDown(denied.dispose);
    await expectLater(submit(denied), s.fails('CASHIER_PERMISSION_DENIED'));
    expect(api.calls, isEmpty);
  });
  test(
    'bad success receipt stays recoverable and never becomes local success',
    () async {
      final storage = Storage(),
          api = Api(storage)..badReceipt = true,
          auth = await controller(storage, api);
      addTearDown(auth.dispose);
      await expectLater(submit(auth), s.fails('SERVING_RESPONSE_INVALID'));
      expect((await auth.pendingServing()).length, 1);
    },
  );
  test('concurrent operation rejected; dispose fences late reply and preserves original', () async {
    final storage = Storage(),
        api = Api(storage)..gate = Completer<void>(),
        auth = await controller(storage, api);
    final sending = submit(auth);
    final rejected = expectLater(sending, s.fails('SESSION_CHANGED'));
    await api.sending.future;
    await expectLater(submit(auth), s.fails('SERVING_IN_PROGRESS'));
    auth.dispose();
    api.gate!.complete();
    await rejected;
    expect((await ServingJournal(storage: storage).load(s.identity)).length, 1);
  });
  test('expiry before a call does not send or erase the original', () async {
    var now = a.now;
    final storage = Storage(),
        api = Api(storage)..rejectBeforeCommit = true,
        auth = await controller(storage, api, now: () => now);
    addTearDown(auth.dispose);
    await expectLater(submit(auth), s.fails('TRANSPORT_FAILED'));
    final id = (await auth.pendingServing()).single.requestId;
    now = a.now.add(const Duration(hours: 1));
    await expectLater(
      auth.recoverServing(id, retryOriginal: true),
      s.fails('SESSION_REQUIRED'),
    );
    expect(api.calls.length, 1);
    expect((await ServingJournal(storage: storage).load(s.identity)).length, 1);
  });
}
