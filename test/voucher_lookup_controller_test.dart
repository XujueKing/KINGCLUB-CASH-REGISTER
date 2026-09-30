import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/auth/session_vault.dart';
import 'package:kingclub_cash_register/src/auth/staff_auth_controller.dart';
import 'package:kingclub_cash_register/src/network/ccsop_client.dart';

import 'staff_session_test.dart' as staff;
import 'voucher_lookup_test.dart' as data;

class LookupApi extends staff.TestApi {
  final calls = <String>[];
  @override
  Future<Object?> call(String id, Map<String, dynamic> params) {
    calls.add(id);
    return super.call(id, params);
  }
}

Map<String, Object?> receipt(String provider) => {
  'result': {...data.fixture(), 'storeRef': 'test-store', 'provider': provider},
};

void main() {
  for (final provider in ['douyin', 'meituan']) {
    test(
      '$provider uses original request and current store through 1950 only',
      () async {
        final api = LookupApi()..pendingRead = Completer<Object?>();
        final auth = staff.TestAuth()
          ..result = {
            ...staff.response(),
            'permissions': ['workbench.read', 'voucher.$provider'],
          };
        final c = staff.controller(staff.TestStorage(), auth, api);
        addTearDown(c.dispose);
        await staff.login(c);
        final reading = c.lookupVoucher(
          provider: provider,
          requestId: data.requestId,
        );
        api.pendingRead!.complete(receipt(provider));
        final result = await reading;
        expect(api.calls, ['K260930001950']);
        expect(api.params, {
          'storeRef': 'test-store',
          'provider': provider,
          'requestId': data.requestId,
        });
        expect(result.rows.map((r) => r.code), [0, 1208]);
      },
    );
  }

  test(
    'other-channel permission, invalid provider and coupon text never send',
    () async {
      final api = LookupApi();
      final auth = staff.TestAuth()
        ..result = {
          ...staff.response(),
          'permissions': ['workbench.read', 'voucher.douyin'],
        };
      final c = staff.controller(staff.TestStorage(), auth, api);
      addTearDown(c.dispose);
      await staff.login(c);
      await expectLater(
        c.lookupVoucher(provider: 'meituan', requestId: data.requestId),
        throwsA(
          isA<CcsopFailure>().having(
            (e) => e.code,
            'code',
            'CASHIER_PERMISSION_DENIED',
          ),
        ),
      );
      for (final args in [
        ('unknown', data.requestId),
        ('douyin', 'TEST_COUPON'),
      ]) {
        await expectLater(
          c.lookupVoucher(provider: args.$1, requestId: args.$2),
          throwsFormatException,
        );
      }
      expect(api.calls, isEmpty);
    },
  );

  for (final expireBeforeSend in [false, true]) {
    test('expiry rejects lookup beforeSend=$expireBeforeSend', () async {
      var clock = staff.now;
      final api = LookupApi()..pendingRead = Completer<Object?>();
      final auth = staff.TestAuth()
        ..result = {
          ...staff.response(),
          'permissions': ['workbench.read', 'voucher.douyin'],
        };
      final c = StaffAuthController(
        vault: SessionVault(storage: staff.TestStorage()),
        authFactory: (_) => auth,
        sessionFactory: (_) => api,
        now: () => clock,
      );
      addTearDown(c.dispose);
      await staff.login(c);
      if (expireBeforeSend) clock = clock.add(const Duration(minutes: 15));
      final reading = c.lookupVoucher(
        provider: 'douyin',
        requestId: data.requestId,
      );
      final rejected = expectLater(reading, throwsA(isA<CcsopFailure>()));
      if (!expireBeforeSend) {
        clock = clock.add(const Duration(minutes: 15));
        api.pendingRead!.complete(receipt('douyin'));
      }
      await rejected;
      expect(api.calls, expireBeforeSend ? isEmpty : ['K260930001950']);
    });
  }

  test(
    'logout rejects late service receipt and never repeats lookup',
    () async {
      final api = LookupApi()..pendingRead = Completer<Object?>();
      final auth = staff.TestAuth()
        ..result = {
          ...staff.response(),
          'permissions': ['workbench.read', 'voucher.douyin'],
        };
      final c = staff.controller(staff.TestStorage(), auth, api);
      addTearDown(c.dispose);
      await staff.login(c);
      final reading = c.lookupVoucher(
        provider: 'douyin',
        requestId: data.requestId,
      );
      final rejected = expectLater(reading, throwsA(isA<CcsopFailure>()));
      await c.logout();
      api.pendingRead!.complete(receipt('douyin'));
      await rejected;
      expect(api.calls, ['K260930001950', 'K260929001904']);
    },
  );

  for (final field in ['storeRef', 'employeeRef', 'provider', 'requestId']) {
    test('controller rejects service response with wrong $field', () async {
      final api = LookupApi()..pendingRead = Completer<Object?>();
      final auth = staff.TestAuth()
        ..result = {
          ...staff.response(),
          'permissions': ['workbench.read', 'voucher.douyin'],
        };
      final c = staff.controller(staff.TestStorage(), auth, api);
      addTearDown(c.dispose);
      await staff.login(c);
      final reading = c.lookupVoucher(
        provider: 'douyin',
        requestId: data.requestId,
      );
      final rejected = expectLater(reading, throwsFormatException);
      final wrong = receipt('douyin');
      (wrong['result'] as Map<String, Object?>)[field] = 'OTHER';
      api.pendingRead!.complete(wrong);
      await rejected;
      expect(api.calls, ['K260930001950']);
    });
  }
}
