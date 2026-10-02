import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/auth/staff_auth_controller.dart';
import 'package:kingclub_cash_register/src/live/item_return_command.dart';
import 'package:kingclub_cash_register/src/live/bill_item_return_dialog.dart';
import 'package:kingclub_cash_register/src/live/item_return_recovery.dart';
import 'package:kingclub_cash_register/src/live/order_snapshot.dart';
import 'package:kingclub_cash_register/src/network/ccsop_client.dart';
import 'package:kingclub_cash_register/src/strings.dart';

import 'item_return_test.dart' as r;
import 'cash_command_test.dart' show Storage;
import 'staff_session_test.dart' as account;

// Widget layer uses an in-memory controller; durable storage and real controller
// transport/restart behavior are covered separately by item_return_test.dart.
class UiAuth extends StaffAuthController {
  final calls = <String>[];
  List<PendingItemReturn> pending = [];
  bool lose = false;
  @override
  Future<List<PendingItemReturn>> pendingItemReturns() async =>
      List.unmodifiable(pending);
  @override
  Future<ItemReturnResult> confirmItemReturn({
    required Map<String, dynamic> fields,
    required int unitPriceCents,
  }) async {
    final c = PendingItemReturn.prepare(
      identity: r.identity,
      fields: fields,
      unitPriceCents: unitPriceCents,
      now: account.now,
    );
    calls.add('K261002001969');
    if (lose) {
      pending = [c];
      throw const CcsopFailure('TRANSPORT_FAILED', deliveryUncertain: true);
    }
    return ItemReturnResult.parse(r.result(c), c);
  }

  @override
  Future<ItemReturnResult> recoverItemReturn(
    String requestId, {
    bool retryOriginal = false,
  }) async {
    calls.add('K261002001970');
    expect(retryOriginal, false);
    final c = pending.single;
    pending = [];
    return ItemReturnResult.parse(r.result(c), c);
  }
}

LiveOrder order() => LiveOrder({
  'orderRef': 'D00000000001',
  'status': 'pending',
  'currency': 'CNY',
  'totalCents': 300,
  'createdAt': '2026-10-02T00:00:00Z',
  'items': [
    {
      'productRef': 'TEST_PRODUCT',
      'quantity': 3,
      'priceCents': 100,
      'subtotalCents': 300,
      'servedQuantity': 2,
      'remainingQuantity': 1,
      'servingEpoch': 1,
      'snapshot': {
        'revision': 1,
        'names': {
          for (final k in ['zh-CN', 'en', 'zh-TW', 'th']) k: 'TEST_PRODUCT',
        },
        'specifications': {
          for (final k in ['zh-CN', 'en', 'zh-TW', 'th']) k: 'TEST_SIZE',
        },
      },
    },
  ],
});
void main() {
  for (final language in UiLanguage.values) {
    testWidgets(
      'return quantity and one physical confirmation ${language.name}',
      (tester) async {
        final auth = UiAuth(), value = order();
        addTearDown(auth.dispose);
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) => BillItemReturnDialog(
                      auth: auth,
                      language: language,
                      tableRef: 'TEST_TABLE',
                      sessionRef: 'H00000000001',
                      order: value,
                      item: value.items.single,
                      isCurrent: () => true,
                    ),
                  ),
                  child: const Text('OPEN'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('OPEN'));
        await tester.pumpAndSettle();
        expect(find.byType(Checkbox), findsNothing);
        await tester.enterText(
          find.byKey(const ValueKey('item-return-quantity')),
          '3',
        );
        await tester.pump();
        expect(
          tester
              .widget<FilledButton>(
                find.byKey(const ValueKey('item-return-submit')),
              )
              .onPressed,
          isNull,
        );
        await tester.enterText(
          find.byKey(const ValueKey('item-return-quantity')),
          '1',
        );
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('item-return-submit')));
        await tester.pumpAndSettle();
        expect(auth.calls, ['K261002001969']);
        expect(find.byType(BillItemReturnDialog), findsNothing);
        expect(await auth.pendingItemReturns(), isEmpty);
        await tester.pump();
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'global recovery works after bill item disappears without resending',
    (tester) async {
      final auth = UiAuth()..lose = true;
      addTearDown(auth.dispose);
      await expectLater(
        auth.confirmItemReturn(fields: r.fields(), unitPriceCents: 100),
        throwsA(isA<CcsopFailure>()),
      );
      final id = (await auth.pendingItemReturns()).single.requestId;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ItemReturnRecovery(auth: auth, language: UiLanguage.en),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('item-return-lookup-$id')));
      await tester.pumpAndSettle();
      expect(auth.calls, ['K261002001969', 'K261002001970']);
      expect(await auth.pendingItemReturns(), isEmpty);
      await tester.pump();
      expect(find.byKey(ValueKey('item-return-lookup-$id')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  test(
    'unresolved return blocks serving and minus on the same product',
    () async {
      final storage = Storage(),
          api = r.Api(storage)..lose = true,
          auth = await r.controller(storage, api);
      addTearDown(auth.dispose);
      await expectLater(
        auth.confirmItemReturn(fields: r.fields(), unitPriceCents: 100),
        throwsA(isA<CcsopFailure>()),
      );
      await expectLater(
        auth.confirmServing(
          tableRef: 'TEST_TABLE',
          sessionRef: 'H00000000001',
          orderRef: 'D00000000001',
          productRef: 'TEST_PRODUCT',
          quantity: 3,
          expectedServedQuantity: 2,
          targetServedQuantity: 3,
          expectedServingEpoch: 1,
          confirmed: true,
        ),
        throwsA(isA<CcsopFailure>()),
      );
      await expectLater(
        auth.reduceUnpaidItem(
          tableRef: 'TEST_TABLE',
          sessionRef: 'H00000000001',
          orderRef: 'D00000000001',
          productRef: 'TEST_PRODUCT',
          expectedQuantity: 3,
          expectedServedQuantity: 2,
          expectedServingEpoch: 1,
          expectedTotalCents: 300,
        ),
        throwsA(isA<CcsopFailure>()),
      );
      expect(api.calls, hasLength(1));
    },
  );
}
