import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/live/live_orders_panel.dart';
import 'package:kingclub_cash_register/src/live/table_snapshot.dart';
import 'package:kingclub_cash_register/src/strings.dart';
import 'package:kingclub_cash_register/src/auth/staff_session.dart';
import 'package:kingclub_cash_register/src/live/cash_command.dart';
import 'package:kingclub_cash_register/src/live/live_cash_recovery_panel.dart';

import 'cash_command_test.dart' as c;

import 'live_tables_panel_test.dart' show TableAuth;
import 'support/order_fixture.dart';
import 'support/table_fixture.dart';

class OrdersAuth extends TableAuth {
  Completer<Object?>? ordersGate;
  int reads = 0;
  @override
  Future<Object?> readOrders({
    required String tableRef,
    required String sessionRef,
    String? afterOrder,
  }) async {
    expect(tableRef, 'test-000');
    expect(sessionRef, 'session-0');
    reads++;
    return ordersGate == null ? orderFixture() : ordersGate!.future;
  }
}

class CashOrdersAuth extends OrdersAuth {
  @override
  StaffSession get session => c.identity;
  bool origin = true, failPreparation = false;
  String status = 'pending';
  int preparations = 0;
  List<PendingCash> pending = [];
  @override
  Future<Object?> readOrders({
    required String tableRef,
    required String sessionRef,
    String? afterOrder,
  }) async {
    final raw = orderFixture(), data = raw['result'] as Map;
    data['storeRef'] = session.storeRef;
    final order = (data['orders'] as List).first as Map;
    order['cashierOrder'] = origin;
    order['status'] = status;
    return raw;
  }

  @override
  Future<List<PendingCash>> pendingCash() async => pending;
  @override
  Future<CashResult> prepareCash({
    required String orderRef,
    required int totalCents,
    required bool confirmed,
  }) async {
    preparations++;
    expect(orderRef, 'D00000000001');
    expect(totalCents, 1200);
    expect(confirmed, true);
    if (failPreparation) throw StateError('NETWORK');
    final command = c.command();
    return CashResult.parse(
      {'result': c.prepared(command)},
      command,
      response: CashResponse.prepare,
    );
  }
}

void main() {
  Future<void> show(
    WidgetTester tester,
    OrdersAuth auth, {
    int revision = 0,
    UiLanguage language = UiLanguage.en,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LiveOrdersPanel(
            auth: auth,
            language: language,
            revision: revision,
            onBack: () {},
            table: LiveTable(
              ((tableFixture()['result'] as Map)['tables'] as List).first
                  as Map<String, dynamic>,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('mounting while backgrounded does not read orders until resume', (
    tester,
  ) async {
    final auth = OrdersAuth();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await show(tester, auth);
    await tester.pump(const Duration(seconds: 1));
    expect(auth.reads, 0);
    expect(
      find.byKey(const ValueKey('order-preview-D00000000001')),
      findsNothing,
    );
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(auth.reads, 1);
    await tester.pumpWidget(const SizedBox());
    auth.dispose();
  });

  testWidgets(
    'identity invalidation before preview first frame cannot reveal order',
    (tester) async {
      final auth = OrdersAuth();
      await show(tester, auth);
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('order-preview-D00000000001')),
      );
      auth.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('order-preview-content')), findsNothing);
      expect(
        find.text(tr(UiLanguage.en, 'orderPreviewExpired')),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
      auth.dispose();
    },
  );

  for (final language in UiLanguage.values) {
    testWidgets(
      'order preview opens without writes and closes on revision ${language.name}',
      (tester) async {
        final auth = OrdersAuth();
        await show(tester, auth, language: language);
        await tester.pumpAndSettle();
        final readsBefore = auth.reads;
        await tester.tap(
          find.byKey(const ValueKey('order-preview-D00000000001')),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('order-preview-content')),
          findsOneWidget,
        );
        expect(auth.reads, readsBefore);
        await show(tester, auth, language: language, revision: 1);
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('order-preview-content')),
          findsNothing,
        );
        await tester.pumpWidget(const SizedBox());
        auth.dispose();
      },
    );

    testWidgets(
      'shows partial serving record in $language without paid inference',
      (tester) async {
        final raw = orderFixture();
        final line =
            ((((raw['result'] as Map)['orders'] as List).first as Map)['items']
                        as List)
                    .first
                as Map;
        line['servedQuantity'] = 1;
        line['remainingQuantity'] = 1;
        final auth = OrdersAuth()
          ..ordersGate = (Completer<Object?>()..complete(raw));
        await show(tester, auth, language: language);
        await tester.pumpAndSettle();
        expect(
          find.text(
            '${tr(language, 'servingDelivered')}: 1 · ${tr(language, 'servingRemaining')}: 1',
          ),
          findsOneWidget,
        );
        expect(
          find.textContaining(tr(language, 'order_pending')),
          findsOneWidget,
        );
        expect(
          find.text(tr(language, 'servingProgressNotice')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        auth.dispose();
      },
    );
  }
  testWidgets(
    'unknown progress is explicit and malformed progress hides the snapshot',
    (tester) async {
      final raw = orderFixture();
      final line =
          ((((raw['result'] as Map)['orders'] as List).first as Map)['items']
                      as List)
                  .first
              as Map;
      line.remove('servedQuantity');
      line.remove('remainingQuantity');
      final auth = OrdersAuth()
        ..ordersGate = (Completer<Object?>()..complete(raw));
      await show(tester, auth);
      await tester.pumpAndSettle();
      expect(find.text(tr(UiLanguage.en, 'servingUnknown')), findsOneWidget);
      line['servedQuantity'] = 3;
      line['remainingQuantity'] = 0;
      auth.ordersGate = Completer<Object?>()..complete(raw);
      await tester.tap(find.byKey(const ValueKey('orders-refresh')));
      await tester.pumpAndSettle();
      expect(find.text(tr(UiLanguage.en, 'liveReadFailed')), findsOneWidget);
      expect(find.text(tr(UiLanguage.en, 'servingUnknown')), findsNothing);
      await tester.pumpWidget(const SizedBox());
      auth.dispose();
    },
  );
  testWidgets('cash requires staff origin and pending status', (tester) async {
    final auth = CashOrdersAuth()..origin = false;
    await show(tester, auth);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('cash-prepare-D00000000001')),
      findsNothing,
    );
    auth.origin = true;
    auth.status = 'paid';
    await tester.tap(find.byKey(const ValueKey('orders-refresh')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('cash-prepare-D00000000001')),
      findsNothing,
    );
  });
  for (final fail in [false, true]) {
    testWidgets('explicit preparation routes to recovery, failure=$fail', (
      tester,
    ) async {
      final auth = CashOrdersAuth()..failPreparation = fail;
      await show(tester, auth);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('cash-prepare-D00000000001')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(auth.preparations, 0);
      expect(find.textContaining('CNY 12.00'), findsWidgets);
      await tester.tap(find.byKey(const ValueKey('cash-prepare-confirm')));
      await tester.pumpAndSettle();
      expect(auth.preparations, 1);
      expect(find.byType(LiveCashRecoveryPanel), findsOneWidget);
    });
  }
  testWidgets(
    'existing original request opens recovery without a new preparation',
    (tester) async {
      final auth = CashOrdersAuth()..pending = [c.command()];
      await show(tester, auth);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('cash-prepare-D00000000001')));
      await tester.pumpAndSettle();
      expect(auth.preparations, 0);
      expect(find.byType(LiveCashRecoveryPanel), findsOneWidget);
    },
  );
  for (final change in ['identity', 'revision', 'background']) {
    testWidgets('$change invalidates preparation confirmation', (tester) async {
      final auth = CashOrdersAuth();
      await show(tester, auth);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('cash-prepare-D00000000001')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(AlertDialog), findsOneWidget);
      if (change == 'identity') {
        auth.notifyListeners();
      } else if (change == 'revision') {
        await show(tester, auth, revision: 1);
      } else {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        await tester.pump();
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
      }
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(auth.preparations, 0);
    });
  }
  for (final language in UiLanguage.values) {
    testWidgets(
      'cash preparation dialog fits ${language.name} landscape and cancels without writes',
      (tester) async {
        tester.view.physicalSize = const Size(1024, 600);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final auth = CashOrdersAuth();
        await show(tester, auth, language: language);
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('cash-prepare-D00000000001')),
        );
        await tester.pump(const Duration(milliseconds: 300));
        expect(tester.takeException(), isNull);
        await tester.tap(find.text(tr(language, 'cashPrepareCancel')));
        await tester.pumpAndSettle();
        expect(auth.preparations, 0);
        expect(find.byType(LiveCashRecoveryPanel), findsNothing);
      },
    );
  }

  testWidgets(
    'shows server order and clears details when employee identity changes',
    (tester) async {
      final auth = OrdersAuth();
      await show(tester, auth);
      await tester.pumpAndSettle();
      expect(find.textContaining('Test product'), findsOneWidget);
      expect(find.textContaining('Pending payment'), findsOneWidget);
      auth.notifyListeners();
      await tester.pump();
      expect(find.textContaining('Test product'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      auth.dispose();
    },
  );
  testWidgets(
    'discards background late replies and reloads on resume and realtime change',
    (tester) async {
      final auth = OrdersAuth()..ordersGate = Completer<Object?>();
      await show(tester, auth);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      auth.ordersGate!.complete(orderFixture());
      await tester.pump();
      expect(find.textContaining('Test product'), findsNothing);
      auth.ordersGate = null;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.textContaining('Test product'), findsOneWidget);
      final reads = auth.reads;
      await show(tester, auth, revision: 1);
      await tester.pump(const Duration(milliseconds: 450));
      await tester.pumpAndSettle();
      expect(auth.reads, reads + 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      auth.dispose();
    },
  );
}
