import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/network/ccsop_client.dart';
import 'package:kingclub_cash_register/src/auth/staff_auth_controller.dart';
import 'package:kingclub_cash_register/src/auth/session_vault.dart';
import 'package:kingclub_cash_register/src/live/item_return_journal.dart';

import 'order_command_test.dart' as o;
import 'staff_session_test.dart' as a;

class PriceApi extends o.Api {
  bool corrupt = false;
  int adjustments = 0;
  @override
  Future<Object?> call(String id, Map<String, dynamic> params) async {
    if (id != 'K261002001964') return super.call(id, params);
    adjustments++;
    final scope = {
      for (final k in [
        'storeRef',
        'tableRef',
        'sessionRef',
        'productRef',
        'unitPriceCents',
      ])
        k: params[k],
    };
    final key = List.filled(64, 'a').join();
    final lines = params['items'] as List;
    return {
      'result': {
        ...scope,
        'requestId': params['requestId'],
        'selectionRef': key,
        'items': [
          for (var i = 0; i < lines.length; i++)
            {
              ...scope,
              ...lines[i] as Map,
              'requestId':
                  '00000000-0000-4000-8000-${(i + 1).toString().padLeft(12, '0')}',
              'operatedBy': o.identity.employeeRef,
              'priceBatchFingerprint': key,
              'quantity': lines[i]['expectedQuantity'],
              'remainingQuantity': lines[i]['expectedQuantity'],
              'remainingTotalCents':
                  (lines[i]['expectedTotalCents'] as int) +
                  (lines[i]['expectedQuantity'] as int) *
                      ((params['unitPriceCents'] as int) -
                          (lines[i]['expectedUnitPriceCents'] as int)) +
                  (corrupt ? 1 : 0),
              'orderStatus': 'pending',
            },
        ],
      },
    };
  }
}

Future<StaffAuthController> controller(PriceApi api) async {
  final storage = o.Storage()..data[SessionVault.deviceKey] = a.device;
  final login = a.TestAuth()
    ..result = {
      ...a.response(),
      'permissions': ['workbench.read', 'orders.read', 'orders.create'],
    };
  final auth = StaffAuthController(
    vault: SessionVault(storage: storage),
    itemReturnJournal: ItemReturnJournal(storage: storage),
    authFactory: (_) => login,
    sessionFactory: (_) => api,
    now: () => a.now,
  );
  await auth.login(
    base: 'https://service.invalid/prefix',
    storeRef: 'test-store',
    loginName: 'TEST_ONLY',
    password: 'TEST_ONLY',
  );
  return auth;
}

void main() {
  final items = <Map<String, Object>>[
    {
      'orderRef': 'D00000000001',
      'expectedQuantity': 2,
      'expectedServedQuantity': 1,
      'expectedServingEpoch': 0,
      'expectedTotalCents': 200,
      'expectedUnitPriceCents': 100,
    },
    {
      'orderRef': 'D00000000002',
      'expectedQuantity': 3,
      'expectedServedQuantity': 0,
      'expectedServingEpoch': 0,
      'expectedTotalCents': 300,
      'expectedUnitPriceCents': 100,
    },
  ];
  test('one request verifies every original unpaid batch receipt', () async {
    final api = PriceApi(), auth = await controller(api);
    expect(
      await auth.repriceUnpaidItems(
        tableRef: 'test-table',
        sessionRef: 'H00000000001',
        productRef: 'p001',
        unitPriceCents: 60,
        items: items,
      ),
      List.filled(64, 'a').join(),
    );
    expect(api.adjustments, 1);
    auth.dispose();
  });
  test(
    'a mismatched returned amount is never treated as a confirmed edit',
    () async {
      final api = PriceApi()..corrupt = true;
      final auth = await controller(api);
      await expectLater(
        auth.repriceUnpaidItems(
          tableRef: 'test-table',
          sessionRef: 'H00000000001',
          productRef: 'p001',
          unitPriceCents: 60,
          items: items,
        ),
        throwsA(
          isA<CcsopFailure>().having(
            (e) => e.code,
            'code',
            'ITEM_PRICE_RECEIPT_INVALID',
          ),
        ),
      );
      expect(api.adjustments, 1);
      auth.dispose();
    },
  );
}
