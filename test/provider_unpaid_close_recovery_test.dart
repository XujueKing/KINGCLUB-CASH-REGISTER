import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/auth/session_vault.dart';
import 'package:kingclub_cash_register/src/auth/staff_auth_controller.dart';
import 'package:kingclub_cash_register/src/live/provider_payment.dart';

import 'staff_session_test.dart' as staff;

class CloseApi extends staff.TestApi {
  bool invalid = false;
  Map<String, dynamic> original = {};
  @override
  Future<Object?> call(String id, Map<String, dynamic> p) async {
    if (id == 'K260929001923') {
      return {
        'result': {
          'state': 'intent_observed',
          'requestId': p['requestId'],
          'intent': {
            for (final key in [
              'storeRef',
              'orderRef',
              'requestId',
              'channel',
              'currency',
            ])
              key: p[key],
            'intentRef': '00000000-0000-4000-8000-000000000001',
            'totalCents': 100,
            'intentStatus': 'closed',
          },
        },
      };
    }
    expect(['K260930001949', 'K260930001928'], contains(id));
    final balance = id == 'K260930001928';
    if (balance) p = {...p, ...original};
    return {
      'result': {
        'state': 'closed_unpaid',
        'requestId': p['requestId'],
        'receipt': {
          'storeRef': p['storeRef'],
          'orderRef': p['orderRef'],
          'requestId': p['requestId'],
          'intentRef': '00000000-0000-4000-8000-000000000001',
          'channel': p['channel'],
          if (balance) 'accountType': p['accountType'],
          'totalCents': invalid ? 101 : p['expectedTotalCents'],
          'currency': 'CNY',
          'closedBy': 'E00000000001',
          'closureStatus': 'closed_unpaid',
        },
      },
    };
  }
}

void main() {
  for (final account in [null, 'platform_cash', 'store_balance']) {
    for (final invalid in [false, true]) {
      test(
        'unpaid closure journal acknowledgement requires exact proof invalid=$invalid account=$account',
        () async {
          final storage = staff.TestStorage();
          storage.data[SessionVault.deviceKey] = staff.device;
          final api = CloseApi()..invalid = invalid;
          final login = staff.TestAuth()
            ..result = {
              ...staff.response(),
              'permissions': [
                'workbench.read',
                'payment.wechat',
                'payment.balance',
              ],
            };
          final journal = ProviderPaymentJournal(storage: storage);
          final auth = StaffAuthController(
            vault: SessionVault(storage: storage),
            providerJournal: journal,
            authFactory: (_) => login,
            sessionFactory: (_) => api,
            now: () => staff.now,
          );
          addTearDown(auth.dispose);
          await staff.login(auth);
          final command = ProviderPayment.create(
            auth.session!,
            'D00000000001',
            account == null ? 'wechat' : 'member_balance',
            100,
            accountType: account,
          );
          api.original = command.params;
          await journal.save(auth.session!, command);
          if (invalid) {
            await expectLater(auth.queryProvider(command), throwsA(anything));
            expect(
              (await journal.load(auth.session!)).single.requestId,
              command.requestId,
            );
          } else {
            final result = await auth.queryProvider(command);
            expect(result.closedUnpaid, isTrue);
            expect(result.confirmed, isFalse);
            expect(await journal.load(auth.session!), isEmpty);
          }
        },
      );
    }
  }
}
