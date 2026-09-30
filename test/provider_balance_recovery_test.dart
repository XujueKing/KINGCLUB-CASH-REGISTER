import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/auth/session_vault.dart';
import 'package:kingclub_cash_register/src/auth/staff_auth_controller.dart';
import 'package:kingclub_cash_register/src/live/provider_payment.dart';
import 'staff_session_test.dart' as staff;

const intent = '00000000-0000-4000-8000-000000000011';
const refund = '00000000-0000-4000-8000-000000000012';

class RefundApi extends staff.TestApi {
  final calls = <String>[];
  Map<String, dynamic> patch = {};
  @override
  Future<Object?> call(String id, Map<String, dynamic> params) async {
    calls.add(id);
    if (id == 'K260929001923') {
      return {'result': {
        'state': 'intent_observed', 'requestId': params['requestId'],
        'intent': {
          for (final key in ['storeRef', 'orderRef', 'requestId', 'channel', 'currency'])
            key: params[key],
          'totalCents': 100, 'intentRef': intent, 'intentStatus': 'confirmed',
        },
      }};
    }
    expect(id, 'K260930001928');
    return {'result': {
      'state': 'closed_or_refunded', 'intentRef': intent, 'refundRef': refund,
      ...patch,
    }};
  }
}

void main() {
  for (final account in ['platform_cash', 'store_balance']) {
    for (final retry in [false, true]) {
      for (final invalid in [false, true]) {
        test('$account refunded recovery retry=$retry invalid=$invalid', () async {
          final storage = staff.TestStorage();
          storage.data[SessionVault.deviceKey] = staff.device;
          final api = RefundApi();
          if (invalid) api.patch = {'intentRef': refund};
          final login = staff.TestAuth()..result = {
            ...staff.response(), 'permissions': ['workbench.read', 'payment.balance'],
          };
          final journal = ProviderPaymentJournal(storage: storage);
          final auth = StaffAuthController(
            vault: SessionVault(storage: storage), providerJournal: journal,
            authFactory: (_) => login, sessionFactory: (_) => api,
            now: () => staff.now,
          );
          addTearDown(auth.dispose);
          await staff.login(auth);
          final command = ProviderPayment.create(auth.session!, 'D00000000001',
            'member_balance', 100, accountType: account);
          await journal.save(auth.session!, command);
          final result = retry ? auth.retryOriginalProvider(command,
            authCode: 'KCPAY1:${base64Url.encode(List.filled(32, 1)).replaceAll('=', '')}',
            stillCurrent: () => true) : auth.queryProvider(command);
          if (invalid) {
            await expectLater(result, throwsA(anything));
            expect((await journal.load(auth.session!)).single.requestId, command.requestId);
          } else {
            final value = await result;
            expect(value.refunded, isTrue);
            expect(value.confirmed, isFalse);
            expect(value.resolved, isTrue);
            expect(await journal.load(auth.session!), isEmpty);
          }
          expect(api.calls, ['K260929001923', 'K260930001928']);
        });
      }
    }
  }
  test('ambiguous provider closure is not a resolved balance refund', () {
    final command = ProviderPayment.create(staff.session(), 'D00000000001', 'alipay', 100);
    final result = ProviderPaymentResult.parse({'result': {
      'state': 'closed_or_refunded', 'requestId': command.requestId,
    }}, command);
    expect(result.resolved, isFalse);
    expect(result.confirmed, isFalse);
  });
  test('balance closure requires exact refund evidence, not only a status', () {
    final command = ProviderPayment.create(staff.session(), 'D00000000001',
      'member_balance', 100, accountType: 'store_balance');
    final value = <String, dynamic>{
      'state': 'closed_or_refunded', 'requestId': command.requestId,
      'intentRef': intent, 'refundRef': refund,
    };
    for (final patch in [
      {'refundRef': null}, {'refundRef': 'bad'}, {'intentRef': 'bad'},
      {'requestId': refund}, {'receipt': <String, dynamic>{}},
    ]) {
      expect(() => ProviderPaymentResult.parse({'result': {...value, ...patch}}, command),
        throwsA(anything));
    }
  });
}
