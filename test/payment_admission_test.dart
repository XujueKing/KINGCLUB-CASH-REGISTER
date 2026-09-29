import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/auth/session_vault.dart';
import 'package:kingclub_cash_register/src/auth/staff_auth_controller.dart';
import 'package:kingclub_cash_register/src/auth/staff_session.dart';
import 'package:kingclub_cash_register/src/live/payment_admission.dart';
import 'package:kingclub_cash_register/src/network/ccsop_client.dart';

import 'staff_session_test.dart' as a;
import 'cash_command_test.dart' show Storage;

PaymentAdmissionQuery query({
  StaffSession? identity,
  String channel = 'alipay',
  String request = '00000000-0000-4000-8000-000000000005',
  int cents = 200,
  String order = 'D00000000001',
  String currency = 'CNY',
}) => PaymentAdmissionQuery.original(
  identity: identity ?? a.session(),
  orderRef: order,
  requestId: request,
  channel: channel,
  expectedTotalCents: cents,
  currency: currency,
);
Map<String, dynamic> reply(
  PaymentAdmissionQuery q, {
  String status = 'prepared',
}) => {
  'result': {
    'state': 'intent_observed',
    'requestId': q.requestId,
    'intent': {
      'intentRef': '00000000-0000-4000-8000-000000000006',
      'storeRef': q.params['storeRef'],
      'orderRef': q.params['orderRef'],
      'requestId': q.requestId,
      'channel': q.channel,
      'totalCents': q.params['expectedTotalCents'],
      'currency': 'CNY',
      'intentStatus': status,
    },
  },
};
Matcher fails(String code) =>
    throwsA(isA<CcsopFailure>().having((e) => e.code, 'code', code));

class LookupApi extends a.TestApi {
  final calls = <String>[];
  Object? response;
  Completer<void>? gate;
  final started = Completer<void>();
  bool fail = false;
  @override
  Future<Object?> call(String id, Map<String, dynamic> params) async {
    calls.add(id);
    expect(id, 'K260929001923');
    if (!started.isCompleted) started.complete();
    if (gate != null) await gate!.future;
    if (fail) throw const CcsopFailure('TRANSPORT_FAILED');
    return response ??
        {
          'result': {'state': 'not_observed', 'requestId': params['requestId']},
        };
  }
}

Future<StaffAuthController> controller(
  Storage storage,
  LookupApi api, {
  bool allowed = true,
  DateTime Function()? now,
}) async {
  storage.data[SessionVault.deviceKey] = a.device;
  final auth = a.TestAuth()
    ..result = {
      ...a.response(),
      'permissions': [
        'workbench.read',
        if (allowed) ...paymentPermissions.values,
      ],
    };
  final result = StaffAuthController(
    vault: SessionVault(storage: storage),
    authFactory: (_) => auth,
    sessionFactory: (_) => api,
    now: now ?? () => a.now,
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
  for (final channel in paymentPermissions.keys) {
    test('immutable original $channel scope and permission', () {
      final q = query(channel: channel);
      expect(q.params.length, 6);
      expect(q.permission, paymentPermissions[channel]);
      expect(q.belongsTo(a.session()), true);
      expect(() => q.params['channel'] = 'cash', throwsUnsupportedError);
      expect(q.params, isNot(contains('authCode')));
    });
  }
  test('invalid original input never becomes a replacement command', () {
    for (final f in <void Function()>[
      () => query(channel: 'voucher'),
      () => query(request: 'bad'),
      () => query(order: 'bad'),
      () => query(cents: 0),
      () => query(cents: 100000001),
      () => query(currency: 'USD'),
    ]) {
      expect(f, fails('PAYMENT_ADMISSION_REQUEST_INVALID'));
    }
  });
  for (final status in [
    'prepared',
    'pending',
    'unknown',
    'confirmed',
    'closed',
  ]) {
    test('$status is only observed admission evidence', () {
      final q = query(),
          result = PaymentAdmissionResult.parse(reply(q, status: status), q);
      expect(result.observed, true);
      expect(result.admissionStatus, status);
      expect(result.intentRef, isNotNull);
    });
  }
  test('not observed is exactly scoped and has no financial status', () {
    final q = query();
    final result = PaymentAdmissionResult.parse({
      'result': {'state': 'not_observed', 'requestId': q.requestId},
    }, q);
    expect(result.observed, false);
    expect(result.intentRef, isNull);
    expect(result.admissionStatus, isNull);
    for (final patch in [
      {'requestId': 'other'},
      {'paid': true},
      {'receipt': {}},
      {'state': 'confirmed'},
    ]) {
      expect(
        () => PaymentAdmissionResult.parse({
          'result': {
            'state': 'not_observed',
            'requestId': q.requestId,
            ...patch,
          },
        }, q),
        fails('PAYMENT_ADMISSION_RESPONSE_INVALID'),
      );
    }
  });
  test('mismatched or malformed admission cannot be accepted', () {
    final q = query();
    for (final patch in <Map<String, dynamic>>[
      {'storeRef': 'OTHER'},
      {'orderRef': 'D00000000002'},
      {'requestId': 'other'},
      {'channel': 'wechat'},
      {'totalCents': 201},
      {'totalCents': 200.0},
      {'currency': 'USD'},
      {'intentRef': 'bad'},
      {'intentStatus': 'paid'},
      {'receipt': {}},
      {'authCode': 'SECRET'},
    ]) {
      final raw = reply(q);
      final result = raw['result'] as Map;
      result['intent'] = {...result['intent'] as Map, ...patch};
      expect(
        () => PaymentAdmissionResult.parse(raw, q),
        fails('PAYMENT_ADMISSION_RESPONSE_INVALID'),
      );
    }
  });
  test(
    'controller calls only1923 and never clears stored unresolved requests',
    () async {
      final storage = Storage(),
          api = LookupApi(),
          auth = await controller(storage, api);
      addTearDown(auth.dispose);
      storage.data['TEST_ONLY_PENDING'] = 'retain';
      final before = Map.of(storage.data), q = query(identity: auth.session);
      api.response = reply(q, status: 'confirmed');
      expect(
        (await auth.lookupPaymentAdmission(q)).admissionStatus,
        'confirmed',
      );
      expect(api.calls, ['K260929001923']);
      expect(storage.data, before);
    },
  );
  test(
    'controller rejects missing channel permission and different owner',
    () async {
      final storage = Storage(),
          api = LookupApi(),
          auth = await controller(storage, api, allowed: false);
      addTearDown(auth.dispose);
      await expectLater(
        auth.lookupPaymentAdmission(query(identity: auth.session)),
        fails('CASHIER_PERMISSION_DENIED'),
      );
      final other = a.session({
        ...a.response(),
        'employee': {'employeeRef': 'E00000000002', 'displayName': 'TEST'},
      });
      await expectLater(
        auth.lookupPaymentAdmission(query(identity: other)),
        fails('PAYMENT_ADMISSION_SCOPE_CHANGED'),
      );
      expect(api.calls, isEmpty);
    },
  );
  test(
    'controller rejects expiry before call and after in-flight response',
    () async {
      var now = a.now;
      final storage = Storage(),
          api = LookupApi(),
          auth = await controller(storage, api, now: () => now);
      addTearDown(auth.dispose);
      final q = query(identity: auth.session);
      api.gate = Completer<void>();
      final pending = auth.lookupPaymentAdmission(q);
      await api.started.future;
      now = a.now.add(const Duration(hours: 1));
      final checked = expectLater(pending, fails('SESSION_REQUIRED'));
      api.gate!.complete();
      await checked;
      await expectLater(
        auth.lookupPaymentAdmission(q),
        fails('SESSION_REQUIRED'),
      );
      expect(api.calls, hasLength(1));
    },
  );
  test(
    'disposed controller ignores late result without changing journal',
    () async {
      final storage = Storage(),
          api = LookupApi()..gate = Completer<void>(),
          auth = await controller(storage, api);
      final q = query(identity: auth.session), before = Map.of(storage.data);
      final pending = auth.lookupPaymentAdmission(q);
      await api.started.future;
      auth.dispose();
      final checked = expectLater(pending, fails('SESSION_CHANGED'));
      api.gate!.complete();
      await checked;
      expect(storage.data, before);
    },
  );
  test('transport failure is not retried', () async {
    final storage = Storage(),
        api = LookupApi()..fail = true,
        auth = await controller(storage, api);
    addTearDown(auth.dispose);
    await expectLater(
      auth.lookupPaymentAdmission(query(identity: auth.session)),
      fails('TRANSPORT_FAILED'),
    );
    expect(api.calls, ['K260929001923']);
  });
}
