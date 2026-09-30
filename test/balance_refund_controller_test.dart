import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:kingclub_cash_register/src/auth/session_vault.dart';
import 'package:kingclub_cash_register/src/auth/staff_auth_controller.dart';
import 'package:kingclub_cash_register/src/live/balance_refund_command.dart';
import 'package:kingclub_cash_register/src/live/balance_refund_journal.dart';
import 'package:kingclub_cash_register/src/network/ccsop_client.dart';
import 'staff_session_test.dart' as a;
import 'balance_refund_command_test.dart' as c;
import 'balance_refund_result_test.dart' as r;

class Api extends a.TestApi {
  Api(this.storage);
  final c.Storage storage;
  final calls = <(String, Map<String, dynamic>)>[];
  Object? saved;
  bool loseReply = false, reject = false, badReply = false;
  Completer<void>? gate;
  final sending = Completer<void>();
  @override
  Future<Object?> call(String id, Map<String, dynamic> params) async {
    if (id == 'K260929001904') return super.call(id, params);
    calls.add((id, Map.of(params)));
    final raw = storage.data[BalanceRefundJournal.storageKey];
    expect(raw, isNotNull);
    final command = PendingBalanceRefund.decode(
      (jsonDecode(raw!)['entries'] as List).single,
    );
    expect(params, command.params);
    if (id == 'K260930001930') {
      return saved ??
          {
            'result': {'state': 'not_observed', 'refundRef': command.refundRef},
          };
    }
    expect(id, 'K260930001929');
    if (!sending.isCompleted) sending.complete();
    if (gate != null) await gate!.future;
    if (reject) {
      throw const CcsopFailure('TRANSPORT_FAILED', deliveryUncertain: true);
    }
    final response = await r.response(command);
    saved = response;
    if (loseReply) {
      throw const CcsopFailure('TRANSPORT_FAILED', deliveryUncertain: true);
    }
    if (badReply) response['result']['receipt']['refundedBy'] = 'E00000000002';
    return response;
  }
}

Future<StaffAuthController> controller(
  c.Storage storage,
  Api api, {
  bool allowed = true,
}) async {
  storage.data[SessionVault.deviceKey] = a.device;
  final auth = a.TestAuth()
    ..result = {
      ...a.response(),
      'permissions': ['workbench.read', if (allowed) 'payment.refund'],
    };
  final result = StaffAuthController(
    vault: SessionVault(storage: storage),
    balanceRefundJournal: BalanceRefundJournal(storage: storage),
    authFactory: (_) => auth,
    sessionFactory: (_) => api,
    now: () => a.now,
  );
  await result.login(
    base: 'https://service.invalid/prefix',
    storeRef: 'test-store',
    loginName: 'TEST_ONLY',
    password: 'TEST_ONLY',
  );
  return result;
}

void main() {
  Future<dynamic> submit(
    StaffAuthController auth, {
    bool Function()? current,
  }) => auth.confirmBalanceRefund(
    context: c.context(),
    reason: 'TEST_ONLY refund',
    dispositions: c.choices(),
    confirmed: true,
    stillCurrent: current ?? () => true,
  );
  test(
    'persists before sending and removes only matched confirmed original',
    () async {
      final storage = c.Storage(),
          api = Api(storage),
          auth = await controller(storage, api);
      addTearDown(auth.dispose);
      expect((await submit(auth)).confirmed, isTrue);
      expect(api.calls.map((e) => e.$1), ['K260930001929']);
      expect(await auth.pendingBalanceRefunds(), isEmpty);
    },
  );
  test(
    'restart after lost response queries original without repeating refund',
    () async {
      final storage = c.Storage(), api = Api(storage)..loseReply = true;
      final auth = await controller(storage, api);
      await expectLater(submit(auth), c.fails('TRANSPORT_FAILED'));
      final original = (await auth.pendingBalanceRefunds()).single;
      auth.dispose();
      final nextApi = Api(storage)..saved = api.saved;
      final next = await controller(storage, nextApi);
      addTearDown(next.dispose);
      expect(
        (await next.recoverBalanceRefund(
          original.refundRef,
          stillCurrent: () => true,
        )).confirmed,
        isTrue,
      );
      expect(nextApi.calls.map((e) => e.$1), ['K260930001930']);
      expect(nextApi.calls.single.$2, original.params);
    },
  );
  test('unknown original is retained and only explicit retry sends identical parameters', () async {
    final storage = c.Storage(), api = Api(storage)..reject = true;
    final auth = await controller(storage, api);
    addTearDown(auth.dispose);
    await expectLater(submit(auth), c.fails('TRANSPORT_FAILED'));
    final original = (await auth.pendingBalanceRefunds()).single;
    expect(
      (await auth.recoverBalanceRefund(
        original.refundRef,
        stillCurrent: () => true,
      )).confirmed,
      isFalse,
    );
    await expectLater(submit(auth), c.fails('BALANCE_REFUND_ALREADY_PENDING'));
    api.reject = false;
    expect(
      (await auth.recoverBalanceRefund(
        original.refundRef,
        retryOriginal: true,
        stillCurrent: () => true,
      )).confirmed,
      isTrue,
    );
    expect(api.calls.map((e) => e.$1), [
      'K260930001929',
      'K260930001930',
      'K260930001930',
      'K260930001929',
    ]);
    expect(api.calls.last.$2, original.params);
  });
  test('failed storage or permission prevents any financial packet', () async {
    final storage = c.Storage(),
        api = Api(storage),
        auth = await controller(storage, api);
    addTearDown(auth.dispose);
    storage.discardWrite = true;
    await expectLater(
      submit(auth),
      c.fails('BALANCE_REFUND_JOURNAL_UNAVAILABLE'),
    );
    expect(api.calls, isEmpty);
    storage.discardWrite = false;
    final denied = await controller(storage, api, allowed: false);
    addTearDown(denied.dispose);
    await expectLater(submit(denied), c.fails('CASHIER_PERMISSION_DENIED'));
    expect(api.calls, isEmpty);
  });
  test('invalid receipt is not success and retains the original', () async {
    final storage = c.Storage(), api = Api(storage)..badReply = true;
    final auth = await controller(storage, api);
    addTearDown(auth.dispose);
    await expectLater(submit(auth), c.fails('BALANCE_REFUND_RESPONSE_INVALID'));
    expect(await auth.pendingBalanceRefunds(), hasLength(1));
  });
  test(
    'page invalidation after persistence blocks first send and keeps recovery',
    () async {
      final storage = c.Storage(),
          api = Api(storage),
          auth = await controller(storage, api);
      addTearDown(auth.dispose);
      var checks = 0;
      await expectLater(
        submit(auth, current: () => ++checks == 1),
        c.fails('BALANCE_REFUND_SCOPE_CHANGED'),
      );
      expect(api.calls, isEmpty);
      expect(await auth.pendingBalanceRefunds(), hasLength(1));
    },
  );
  test('concurrent submission rejected; disposed session cannot consume late receipt', () async {
    final storage = c.Storage(), api = Api(storage)..gate = Completer<void>();
    final auth = await controller(storage, api);
    final first = submit(auth);
    final rejected = expectLater(first, c.fails('SESSION_CHANGED'));
    await api.sending.future;
    await expectLater(submit(auth), c.fails('BALANCE_REFUND_IN_PROGRESS'));
    auth.dispose();
    api.gate!.complete();
    await rejected;
    expect(
      await BalanceRefundJournal(storage: storage).load(c.identity),
      hasLength(1),
    );
  });
}
