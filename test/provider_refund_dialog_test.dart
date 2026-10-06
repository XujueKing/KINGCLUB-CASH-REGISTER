import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:kingclub_cash_register/src/live/provider_refund_dialog.dart';
import 'package:kingclub_cash_register/src/live/order_snapshot.dart';
import 'package:kingclub_cash_register/src/strings.dart';

import 'live_tables_panel_test.dart' show TableAuth;
import 'support/order_fixture.dart';

class RefundAuth extends TableAuth {
  RefundAuth()
    : super(
        permissions: const ['workbench.read', 'orders.read', 'payment.refund'],
      );
  final calls = <Map<String, dynamic>>[];
  bool uncertain = true, notObserved = false;
  @override
  Future<Map<String, dynamic>> providerItemRefund(
    Map<String, dynamic> command,
  ) async {
    calls.add(Map.from(command));
    if (command['action'] == 'context')
      return {
        'unitPriceCents': 600,
        'availableQuantity': 2,
        'servedQuantity': 0,
        'storedQuantity': 0,
        'refundedQuantity': 0,
        'servingEpoch': 0,
        'enabled': true,
      };
    if (notObserved && command['action'] == 'query')
      return {'state': 'not_observed', 'refundRef': command['requestId']};
    if (uncertain) throw StateError('TEST_NETWORK');
    return {
      'refundRef': command['requestId'],
      'state': 'refunded',
      'quantity': 2,
      'totalCents': 1200,
      'stockReturnQuantity': 0,
    };
  }
}

void main() {
  for (final recheck in [false, true])
    testWidgets(
      'touch refund retains original request across recheck=$recheck',
      (tester) async {
        FlutterSecureStorage.setMockInitialValues({});
        final auth = RefundAuth();
        addTearDown(auth.dispose);
        final raw =
            orderFixture()['result']['orders'][0] as Map<String, dynamic>;
        final order = LiveOrder({...raw, 'status': 'paid'});
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => TextButton(
                onPressed: () => showDialog<bool>(
                  context: context,
                  builder: (_) => ProviderRefundDialog(
                    auth: auth,
                    order: order,
                    item: order.items.single,
                    served: false,
                    language: UiLanguage.en,
                    isCurrent: () => true,
                  ),
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        expect(find.byType(TextField), findsNothing);
        await tester.tap(find.text('Confirm refund'));
        await tester.pumpAndSettle();
        expect(auth.calls.last['quantity'], 2);
        expect(auth.calls.last['stockReturnQuantity'], 0);
        final id = auth.calls.last['requestId'];
        if (recheck) {
          auth.notObserved = true;
          await tester.tap(find.text('Check refund'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Recheck details'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Confirm refund'));
          await tester.pumpAndSettle();
          expect(auth.calls.last['requestId'], id);
          auth.notObserved = false;
        }
        auth.uncertain = false;
        await tester.tap(find.text('Check refund'));
        await tester.pumpAndSettle();
        expect(auth.calls.last, {
          'action': 'query',
          'orderRef': order.reference,
          'productRef': order.items.single.productRef,
          'requestId': id,
        });
        expect(
          auth.calls.where((c) => c['action'] == 'refund'),
          hasLength(recheck ? 2 : 1),
        );
        expect(find.byType(ProviderRefundDialog), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
}
