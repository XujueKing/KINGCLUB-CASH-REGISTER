import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/live/catalog_snapshot.dart';
import 'package:kingclub_cash_register/src/live/live_cart_panel.dart';
import 'package:kingclub_cash_register/src/live/live_order_members_panel.dart';
import 'package:kingclub_cash_register/src/live/order_command.dart';
import 'package:kingclub_cash_register/src/live/order_context_snapshot.dart';
import 'package:kingclub_cash_register/src/strings.dart';

import 'order_context_test.dart' as m;
import 'catalog_snapshot_test.dart' as c;
import 'order_command_test.dart' as o;
import 'staff_session_test.dart' as a;

class CartAuth extends m.MemberAuth {
  int submits = 0;
  bool failSubmit = false, failJournal = false, unknown = false;
  int available = 3;
  List<PendingOrder> pending = [];
  Completer<OrderRequestResult>? submitGate;
  List<OrderSelection>? sent;
  @override
  Future<List<PendingOrder>> pendingOrders() async {
    if (failJournal) throw StateError('PRIVATE_JOURNAL');
    return pending;
  }

  @override
  Future<CatalogSnapshot> readCatalog({
    String? categoryRef,
    String? afterProduct,
  }) async => c.parse(
    {
      ...c.catalog(),
      'products': [
        {
          ...c.product(),
          'inventoryKnown': !unknown,
          'available': unknown ? 0 : available,
          'soldOut': unknown || available == 0,
        },
      ],
    },
    categoryRef: categoryRef,
    afterProduct: afterProduct,
  );
  @override
  Future<OrderRequestResult> submitOrder({
    required OrderContextSnapshot context,
    required String memberRef,
    required List<OrderSelection> items,
    required bool confirmed,
  }) async {
    expect(confirmed, isTrue);
    expect(memberRef, 'member-000');
    expect(context.sessionRef, m.sessionRef);
    submits++;
    sent = items;
    final command = PendingOrder.prepare(
      identity: session,
      context: context,
      memberRef: memberRef,
      items: items,
      now: a.now,
    );
    if (failSubmit) {
      pending = [command];
      throw StateError('PRIVATE_TRANSPORT');
    }
    if (submitGate != null) return submitGate!.future;
    return OrderRequestResult.parse(
      {'result': o.receipt(command.params)},
      command,
      submission: true,
    );
  }
}

Future<void> show(
  WidgetTester tester,
  CartAuth auth, {
  UiLanguage language = UiLanguage.zh,
  bool memberPage = false,
}) async {
  tester.view.physicalSize = const Size(1024, 600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: memberPage
            ? LiveOrderMembersPanel(
                auth: auth,
                language: language,
                tableRef: m.tableRef,
                sessionRef: m.sessionRef,
                onBack: () {},
              )
            : LiveCartPanel(
                auth: auth,
                language: language,
                orderContext: m.parse(m.contextData()),
                memberRef: 'member-000',
                onBack: () {},
              ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> tap(WidgetTester tester, String key) async {
  final finder = find.byKey(ValueKey(key));
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

bool enabled(WidgetTester tester) =>
    tester
        .widget<FilledButton>(find.byKey(const ValueKey('cart-submit')))
        .onPressed !=
    null;

void main() {
  testWidgets(
    'in-flight submit disables actions and ignores late response after identity invalidation',
    (tester) async {
      final auth = CartAuth()..submitGate = Completer<OrderRequestResult>();
      await show(tester, auth);
      await tap(tester, 'catalog-add-p001');
      await tap(tester, 'cart-submit');
      await tester.tap(find.byKey(const ValueKey('cart-confirm')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(auth.submits, 1);
      expect(enabled(tester), false);
      expect(
        tester
            .widget<OutlinedButton>(find.byKey(const ValueKey('cart-recovery')))
            .onPressed,
        isNull,
      );
      auth.invalidate();
      final command = o.command();
      auth.submitGate!.complete(
        OrderRequestResult.parse(
          {'result': o.receipt(command.params)},
          command,
          submission: true,
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text(tr(UiLanguage.zh, 'orderRecoveryConfirmed')),
        findsNothing,
      );
      expect(find.text(tr(UiLanguage.zh, 'cartStale')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      auth.dispose();
    },
  );

  testWidgets(
    'catalog category refresh retains draft without creating a command',
    (tester) async {
      final auth = CartAuth();
      await show(tester, auth);
      await tap(tester, 'catalog-add-p001');
      await tap(tester, 'catalog-category-c1');
      expect(find.text('CNY 12.34'), findsNWidgets(2));
      expect(enabled(tester), true);
      expect(auth.submits, 0);
      await tester.pumpWidget(const SizedBox());
      auth.dispose();
    },
  );
  testWidgets(
    'seated eligible member leads to cart with bounded quantities and exact confirmed order',
    (tester) async {
      final auth = CartAuth();
      await show(tester, auth, memberPage: true);
      expect(find.byKey(const ValueKey('order-member-cart')), findsNothing);
      await tap(tester, 'order-member-member-000');
      await tap(tester, 'order-member-cart');
      expect(enabled(tester), false);
      await tap(tester, 'catalog-add-p001');
      await tap(tester, 'cart-plus-p001');
      expect(find.text('CNY 24.68'), findsOneWidget);
      await tap(tester, 'cart-plus-p001');
      await tap(tester, 'cart-plus-p001');
      expect(find.text(tr(UiLanguage.zh, 'cartLimit')), findsOneWidget);
      await tap(tester, 'cart-minus-p001');
      await tap(tester, 'cart-submit');
      expect(auth.submits, 0);
      expect(find.textContaining('TEST size'), findsWidgets);
      await tap(tester, 'cart-confirm');
      expect(auth.submits, 1);
      expect(auth.sent!.single.quantity, 2);
      expect(auth.sent!.single.product.priceCents, 1234);
      expect(
        find.text(tr(UiLanguage.zh, 'orderRecoveryConfirmed')),
        findsOneWidget,
      );
      expect(enabled(tester), false);
      await tester.pumpWidget(const SizedBox());
      auth.dispose();
    },
  );

  testWidgets(
    'cancel confirmation leaves editable draft, removal restores empty',
    (tester) async {
      final auth = CartAuth();
      await show(tester, auth);
      await tap(tester, 'catalog-add-p001');
      await tap(tester, 'cart-submit');
      await tester.tap(find.text(tr(UiLanguage.zh, 'cancel')));
      await tester.pumpAndSettle();
      expect(auth.submits, 0);
      expect(enabled(tester), true);
      await tap(tester, 'cart-delete-p001');
      expect(enabled(tester), false);
      expect(find.text('CNY 0.00'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      auth.dispose();
    },
  );

  testWidgets(
    'ambiguous delivery disables new command and exposes original recovery',
    (tester) async {
      final auth = CartAuth()..failSubmit = true;
      await show(tester, auth);
      await tap(tester, 'catalog-add-p001');
      await tap(tester, 'cart-submit');
      await tap(tester, 'cart-confirm');
      expect(auth.submits, 1);
      expect(enabled(tester), false);
      expect(find.textContaining('PRIVATE_'), findsNothing);
      await tap(tester, 'cart-recovery');
      expect(
        find.byKey(
          ValueKey('order-recovery-query-${auth.pending.single.requestId}'),
        ),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
      auth.dispose();
    },
  );

  testWidgets(
    'unresolved original request and unreadable journal block new order',
    (tester) async {
      final auth = CartAuth()..pending = [o.command()];
      await show(tester, auth);
      expect(find.text(tr(UiLanguage.zh, 'cartPending')), findsOneWidget);
      expect(enabled(tester), false);
      await tester.pumpWidget(const SizedBox());
      auth.dispose();
      final broken = CartAuth()..failJournal = true;
      await show(tester, broken);
      expect(
        find.text(tr(UiLanguage.zh, 'orderRecoveryFailed')),
        findsOneWidget,
      );
      expect(enabled(tester), false);
      await tester.pumpWidget(const SizedBox());
      broken.dispose();
    },
  );

  testWidgets('unknown inventory cannot be added', (tester) async {
    final auth = CartAuth()..unknown = true;
    await show(tester, auth);
    expect(
      tester
          .widget<OutlinedButton>(
            find.byKey(const ValueKey('catalog-add-p001')),
          )
          .onPressed,
      isNull,
    );
    expect(enabled(tester), false);
    await tester.pumpWidget(const SizedBox());
    auth.dispose();
  });

  testWidgets('backgrounding invalidates confirmation and clears the draft', (
    tester,
  ) async {
    final auth = CartAuth();
    await show(tester, auth);
    await tap(tester, 'catalog-add-p001');
    await tap(tester, 'cart-submit');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tap(tester, 'cart-confirm');
    expect(auth.submits, 0);
    expect(enabled(tester), false);
    expect(find.text(tr(UiLanguage.zh, 'cartStale')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    auth.dispose();
  });

  testWidgets('identity change invalidates confirmation', (tester) async {
    final auth = CartAuth();
    await show(tester, auth);
    await tap(tester, 'catalog-add-p001');
    await tap(tester, 'cart-submit');
    auth.invalidate();
    await tester.pump();
    await tap(tester, 'cart-confirm');
    expect(auth.submits, 0);
    expect(enabled(tester), false);
    await tester.pumpWidget(const SizedBox());
    auth.dispose();
  });

  for (final language in UiLanguage.values) {
    testWidgets('cart and confirmation fit ${language.name}', (tester) async {
      final auth = CartAuth();
      await show(tester, auth, language: language);
      await tap(tester, 'catalog-add-p001');
      await tap(tester, 'cart-submit');
      expect(tester.takeException(), isNull);
      await tester.tap(find.text(tr(language, 'cancel')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      auth.dispose();
    });
  }
}
