import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/live/table_bill_panel.dart';
import 'package:kingclub_cash_register/src/live/bill_product_card.dart';
import 'package:kingclub_cash_register/src/strings.dart';

import 'live_tables_panel_test.dart' show TableAuth;
import 'support/order_fixture.dart';

class BillAuth extends TableAuth {
  BillAuth()
    : super(
        permissions: const ['workbench.read', 'orders.read', 'payment.cash'],
      );
  Completer<Object?>? ordersGate;
  bool cancelled = false;
  bool failRead = false;
  bool postpay = false, progressKnown = true, paid = false;
  int served = 0;
  @override
  Future<Object?> readOrders({
    required String tableRef,
    required String sessionRef,
    String? afterOrder,
  }) async {
    if (failRead) throw StateError('read failed');
    if (ordersGate != null) return ordersGate!.future;
    final raw = orderFixture(), data = raw['result'] as Map;
    data['tableRef'] = tableRef;
    data['session']['sessionRef'] = sessionRef;
    data['session']['paymentTiming'] = postpay ? 'postpay' : 'prepay';
    (data['orders'] as List).first['cashierOrder'] = postpay;
    final progress = (data['orders'] as List).first['items'][0];
    progress['servedQuantity'] = served;
    progress['remainingQuantity'] = 2 - served;
    if (!progressKnown) {
      final item = (data['orders'] as List).first['items'][0] as Map;
      item.remove('servedQuantity');
      item.remove('remainingQuantity');
    }
    (data['orders'] as List).first['status'] = cancelled
        ? 'expired'
        : paid
        ? 'paid'
        : 'pending';
    data['sessionSummary'] = {
      'currency': 'CNY',
      'paid': {
        'orderCount': paid && !cancelled ? 1 : 0,
        'totalCents': paid && !cancelled ? 1200 : 0,
      },
      'pending': {
        'orderCount': cancelled || paid ? 0 : 1,
        'totalCents': cancelled || paid ? 0 : 1200,
      },
      'expired': {
        'orderCount': cancelled ? 1 : 0,
        'totalCents': cancelled ? 1200 : 0,
      },
    };
    return raw;
  }
}

void main() {
  for (final language in UiLanguage.values) {
    testWidgets(
      'receipt footer stays visible while long selection scrolls ${language.name}',
      (tester) async {
        final auth = BillAuth();
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 380,
                height: 500,
                child: TableBillPanel(
                  auth: auth,
                  language: language,
                  tableRef: 'test-000',
                  sessionRef: 'session-0',
                  revision: 0,
                  fillHeight: true,
                  leading: const SizedBox(
                    height: 1200,
                    child: Text('Long selection'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final button = find.byKey(const ValueKey('table-bill-checkout'));
        final before = tester.getRect(button);
        expect(button.hitTestable(), findsOneWidget);
        await tester.drag(
          find.byType(SingleChildScrollView),
          const Offset(0, -900),
        );
        await tester.pumpAndSettle();
        expect(tester.getRect(button), before);
        expect(button.hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        auth.dispose();
      },
    );
  }
  Widget page(
    BillAuth auth,
    int revision, {
    bool checkoutAllowed = true,
    int draftCents = 0,
    String tableRef = 'test-000',
    String sessionRef = 'session-0',
    Future<void> Function(String)? onAddProduct,
    Map<String, BillProductCard> draftCards = const {},
  }) => MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: TableBillPanel(
          auth: auth,
          language: UiLanguage.en,
          tableRef: tableRef,
          sessionRef: sessionRef,
          revision: revision,
          checkoutAllowed: checkoutAllowed,
          draftCents: draftCents,
          onAddProduct: onAddProduct,
          draftCards: draftCards,
        ),
      ),
    ),
  );
  testWidgets(
    'primary checkout shows server due in red then settled when paid',
    (tester) async {
      final auth = BillAuth();
      await tester.pumpWidget(page(auth, 0));
      await tester.pumpAndSettle();
      final finder = find.byKey(const ValueKey('table-bill-checkout'));
      var button = tester.widget<FilledButton>(finder);
      expect(button.onPressed, isNotNull);
      expect(
        button.style!.backgroundColor!.resolve({}),
        const Color(0xFFDC2626),
      );
      expect(
        find.descendant(of: finder, matching: find.textContaining('12.00')),
        findsOneWidget,
      );
      auth.paid = true;
      await tester.pumpWidget(page(auth, 1));
      await tester.pumpAndSettle();
      button = tester.widget<FilledButton>(finder);
      expect(button.onPressed, isNull);
      expect(
        find.descendant(of: finder, matching: find.text('Settled')),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
      auth.dispose();
    },
  );
  testWidgets(
    'same product draft and paid lines form one card with original totals',
    (tester) async {
      final auth = BillAuth()..paid = true;
      const draft = BillProductCard(
        key: ValueKey('draft-test'),
        language: UiLanguage.en,
        name: 'Test product',
        specification: 'Bottle',
        quantity: 1,
        priceCents: 900,
        totalCents: 900,
        base: null,
        footer: Text('Draft quantity 1'),
      );
      await tester.pumpWidget(
        page(auth, 0, draftCents: 900, draftCards: {'test-product': draft}),
      );
      await tester.pumpAndSettle();
      expect(find.byType(BillProductCard), findsOneWidget);
      var card = tester.widget<BillProductCard>(find.byType(BillProductCard));
      expect(card.quantity, 3);
      expect(card.totalCents, 2100);
      expect(card.priceLabel, isNotNull);
      expect(find.text('Draft quantity 1'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('bill-filter')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Unpaid').last);
      await tester.pumpAndSettle();
      expect(find.byType(BillProductCard), findsOneWidget);
      card = tester.widget<BillProductCard>(find.byType(BillProductCard));
      expect(card.quantity, 1);
      expect(card.totalCents, 900);
      await tester.tap(find.byKey(const ValueKey('bill-filter')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Paid').last);
      await tester.pumpAndSettle();
      card = tester.widget<BillProductCard>(find.byType(BillProductCard));
      expect(card.quantity, 2);
      expect(card.totalCents, 1200);
      expect(find.text('Draft quantity 1'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      auth.dispose();
    },
  );
  for (final switchTable in [false, true]) {
    testWidgets(
      'product details never duplicate quantity controls after ${switchTable ? 'switching tables' : 'a bill update'}',
      (tester) async {
        final auth = BillAuth();
        var additions = 0;
        Future<void> add(String productRef) async {
          additions++;
        }

        await tester.pumpWidget(page(auth, 0, onAddProduct: add));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('bill-group-CNY-test-product')),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('bill-add-product')), findsNothing);
        await tester.pumpWidget(
          page(
            auth,
            1,
            tableRef: switchTable ? 'test-001' : 'test-000',
            onAddProduct: add,
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('bill-details-close')));
        await tester.pumpAndSettle();
        expect(additions, 0);
        // A newly opened card uses the refreshed scope normally.
        await tester.tap(
          find.byKey(const ValueKey('bill-group-CNY-test-product')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('bill-details-close')));
        await tester.pumpAndSettle();
        expect(additions, 0);
        await tester.pumpWidget(const SizedBox());
        auth.dispose();
      },
    );
  }
  testWidgets('reused panel restores only matching table and session cache', (
    tester,
  ) async {
    final auth = BillAuth();
    await tester.pumpWidget(page(auth, 0));
    await tester.pumpAndSettle();
    await tester.pumpWidget(
      page(auth, 0, tableRef: 'test-001', sessionRef: 'session-1'),
    );
    await tester.pumpAndSettle();
    final gate = Completer<Object?>();
    auth.ordersGate = gate;
    await tester.pumpWidget(page(auth, 0));
    await tester.pump();
    expect(find.text('Test product'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('table-bill-checkout')),
          )
          .onPressed,
      isNull,
    );

    // A new sitting at the same table must not inherit the previous bill.
    await tester.pumpWidget(page(auth, 0, sessionRef: 'session-new'));
    await tester.pump();
    expect(find.text('Test product'), findsNothing);
    // The outstanding old-table reply must not put its products back on screen.
    gate.complete(orderFixture());
    await tester.pumpAndSettle();
    expect(find.text('Test product'), findsNothing);
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('table-bill-checkout')),
          )
          .onPressed,
      isNull,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    auth.dispose();
  });
  testWidgets(
    'returning table paints cached bill before read completes but cannot pay',
    (tester) async {
      final auth = BillAuth();
      await tester.pumpWidget(page(auth, 0));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      auth.ordersGate = Completer<Object?>();
      await tester.pumpWidget(page(auth, 0));
      await tester.pump();
      expect(find.text('Test product'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('table-bill-checkout')),
            )
            .onPressed,
        isNull,
      );
      auth.ordersGate!.complete(orderFixture());
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      auth.dispose();
    },
  );
  testWidgets(
    'new draft reveals unpaid tab and contributes to preview totals',
    (tester) async {
      final auth = BillAuth()..paid = true;
      await tester.pumpWidget(page(auth, 0));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('bill-filter')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Paid').last);
      await tester.pumpAndSettle();
      await tester.pumpWidget(
        page(auth, 0, checkoutAllowed: false, draftCents: 300),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<DropdownButton<String>>(
              find.byKey(const ValueKey('bill-filter')),
            )
            .value,
        'pending',
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('table-bill-total')),
          matching: find.text('15.00'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('table-bill-pending')),
          matching: find.text('3.00'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('table-bill-paid')),
          matching: find.text('12.00'),
        ),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
      auth.dispose();
    },
  );
  testWidgets('paid partial delivery and filters retain whole-table totals', (
    tester,
  ) async {
    final auth = BillAuth()
      ..paid = true
      ..served = 1;
    await tester.pumpWidget(page(auth, 0));
    await tester.pumpAndSettle();
    expect(find.text('Served 1 / Not served 1'), findsOneWidget);
    await tester.tap(find.text('Test product'));
    await tester.pumpAndSettle();
    expect(find.text('Served × 1'), findsOneWidget);
    expect(find.text('Not served × 1'), findsOneWidget);
    expect(find.text('Item refund'), findsNWidgets(2));
    expect(find.text('Recall'), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(
            find.byKey(const ValueKey('cart-minus-test-product')),
          )
          .onPressed,
      isNull,
    );
    Navigator.of(tester.element(find.byType(AlertDialog))).pop();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('bill-filter')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Unpaid').last);
    await tester.pumpAndSettle();
    expect(find.text('Test product'), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('table-bill-total')),
        matching: find.text('12.00'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('table-bill-paid')),
        matching: find.text('12.00'),
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('bill-filter')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Paid').last);
    await tester.pumpAndSettle();
    expect(find.text('Test product'), findsOneWidget);
    auth.progressKnown = false;
    await tester.pumpWidget(page(auth, 1));
    await tester.pumpAndSettle();
    expect(find.text('Delivery unconfirmed'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    auth.dispose();
  });
  testWidgets(
    'unsent cart prevents checkout; failed refresh keeps lines but disables payment',
    (tester) async {
      final auth = BillAuth();
      final checkout = find.byKey(const ValueKey('table-bill-checkout'));
      await tester.pumpWidget(page(auth, 0, checkoutAllowed: false));
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(checkout).onPressed, isNull);
      expect(
        tester.widget<FilledButton>(checkout).style!.backgroundColor!.resolve({
          WidgetState.disabled,
        }),
        const Color(0xFFDC2626),
      );

      await tester.pumpWidget(page(auth, 0));
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(checkout).onPressed, isNotNull);
      auth.failRead = true;
      await tester.pumpWidget(page(auth, 1));
      await tester.pumpAndSettle();
      expect(find.textContaining('Test product'), findsOneWidget);
      expect(tester.widget<FilledButton>(checkout).onPressed, isNull);
      await tester.pumpWidget(const SizedBox());
      auth.dispose();
    },
  );
  testWidgets(
    'revision updates the table bill and removes cancelled items from due total',
    (tester) async {
      final auth = BillAuth();
      await tester.pumpWidget(page(auth, 0));
      await tester.pumpAndSettle();
      expect(find.textContaining('Test product'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('table-bill-pending')),
          matching: find.text('12.00'),
        ),
        findsOneWidget,
      );
      auth.cancelled = true;
      await tester.pumpWidget(page(auth, 1));
      await tester.pumpAndSettle();
      expect(find.textContaining('Test product'), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('table-bill-pending')),
          matching: find.text('0.00'),
        ),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
      auth.dispose();
    },
  );
  testWidgets('late read cannot reveal bill after backgrounding', (
    tester,
  ) async {
    final auth = BillAuth()..ordersGate = Completer<Object?>();
    await tester.pumpWidget(page(auth, 0));
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    auth.ordersGate!.complete(orderFixture());
    await tester.pumpAndSettle();
    expect(find.textContaining('Test product'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    auth.dispose();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });
}
