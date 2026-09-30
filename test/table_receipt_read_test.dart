import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/network/ccsop_client.dart';

import 'staff_session_test.dart' as staff;
import 'table_receipt_document_test.dart' as receipt;

class TableReceiptApi extends staff.TestApi {
  final calls = <String>[];
  @override
  Future<Object?> call(String id, Map<String, dynamic> params) {
    calls.add(id);
    return super.call(id, params);
  }
}

Map<String, dynamic> originalReceipt() {
  final raw = receipt.tableReceiptFixture();
  (raw['result'] as Map<String, dynamic>)['storeRef'] = 'test-store';
  return raw;
}

void main() {
  test(
    'reads only original table reference with current authorized store',
    () async {
      final api = TableReceiptApi()..pendingRead = Completer<Object?>();
      final auth = staff.TestAuth()
        ..result = {
          ...staff.response(),
          'permissions': ['workbench.read', 'orders.read'],
        };
      final controller = staff.controller(staff.TestStorage(), auth, api);
      addTearDown(controller.dispose);
      await staff.login(controller);
      final reading = controller.readTableReceiptDocument(receipt.checkout);
      api.pendingRead!.complete(originalReceipt());
      final result = await reading;
      expect(api.calls, ['K260930001936']);
      expect(api.params, {
        'storeRef': 'test-store',
        'checkoutRef': receipt.checkout,
      });
      expect(result.tender.accountType, 'store_balance');
      expect(result.tender.principalCents, 240);
      expect(result.tender.giftCents, 60);
    },
  );

  test(
    'missing permission and invalid reference never reach the service',
    () async {
      for (final allowed in [false, true]) {
        final api = TableReceiptApi();
        final auth = staff.TestAuth()
          ..result = {
            ...staff.response(),
            'permissions': ['workbench.read', if (allowed) 'orders.read'],
          };
        final controller = staff.controller(staff.TestStorage(), auth, api);
        addTearDown(controller.dispose);
        await staff.login(controller);
        await expectLater(
          controller.readTableReceiptDocument(
            allowed ? 'invalid' : receipt.checkout,
          ),
          throwsA(isA<CcsopFailure>()),
        );
        expect(api.calls, isEmpty);
      }
    },
  );

  test(
    'logout discards a delayed receipt rather than exposing old account data',
    () async {
      final api = TableReceiptApi()..pendingRead = Completer<Object?>();
      final auth = staff.TestAuth()
        ..result = {
          ...staff.response(),
          'permissions': ['workbench.read', 'orders.read'],
        };
      final controller = staff.controller(staff.TestStorage(), auth, api);
      addTearDown(controller.dispose);
      await staff.login(controller);
      final reading = controller.readTableReceiptDocument(receipt.checkout);
      final rejected = expectLater(reading, throwsA(isA<CcsopFailure>()));
      await controller.logout();
      api.pendingRead!.complete(originalReceipt());
      await rejected;
      expect(api.calls.where((id) => id == 'K260930001936'), hasLength(1));
    },
  );
}
