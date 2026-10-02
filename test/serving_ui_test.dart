import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/auth/staff_session.dart';
import 'package:kingclub_cash_register/src/live/live_orders_panel.dart';
import 'package:kingclub_cash_register/src/live/live_serving_recovery_panel.dart';
import 'package:kingclub_cash_register/src/live/serving_command.dart';
import 'package:kingclub_cash_register/src/live/table_snapshot.dart';
import 'package:kingclub_cash_register/src/strings.dart';
import 'package:kingclub_cash_register/src/network/ccsop_client.dart';

import 'live_tables_panel_test.dart' show TableAuth;
import 'support/order_fixture.dart';
import 'support/table_fixture.dart';
import 'serving_command_test.dart' as s;
import 'staff_session_test.dart' as a;

class ServingAuth extends TableAuth {
  @override
  StaffSession get session => s.identity;
  String timing = 'postpay', status = 'pending';
  bool unknown = false, failServing = false;
  int writes = 0, lookups = 0, retries = 0;
  List<PendingServing> pending = [];
  Completer<void>? sendGate;
  @override
  Future<Object?> readOrders({
    required String tableRef,
    required String sessionRef,
    String? afterOrder,
  }) async {
    final raw = orderFixture(), data = raw['result'] as Map;
    (data['session'] as Map)['sessionRef'] = sessionRef;
    (data['session'] as Map)['paymentTiming'] = timing;
    final order = (data['orders'] as List).first as Map;
    order['cashierOrder'] = true;
    order['status'] = status;
    final item = (order['items'] as List).first as Map;
    if (unknown) {
      item.remove('servedQuantity');
      item.remove('remainingQuantity');
    }
    return raw;
  }

  @override
  Future<List<PendingServing>> pendingServing() async => pending;
  @override
  Future<ServingResult> confirmServing({
    required String tableRef,
    required String sessionRef,
    required String orderRef,
    required String productRef,
    required int quantity,
    required int expectedServedQuantity,
    required int targetServedQuantity,
    int? expectedServingEpoch,
    required bool confirmed,
  }) async {
    writes++;
    expect(confirmed, true);
    expect(expectedServedQuantity, 0);
    expect(targetServedQuantity, 1);
    final c = PendingServing.prepare(
      identity: session,
      tableRef: tableRef,
      sessionRef: sessionRef,
      orderRef: orderRef,
      productRef: productRef,
      quantity: quantity,
      expectedServedQuantity: expectedServedQuantity,
      targetServedQuantity: targetServedQuantity,
      now: a.now,
      confirmed: confirmed,
    );
    pending = [c];
    if (sendGate != null) await sendGate!.future;
    if (failServing) throw const CcsopFailure('TRANSPORT_FAILED');
    pending = [];
    return ServingResult.parse(s.result(c), c);
  }

  @override
  Future<ServingResult> recoverServing(
    String requestId, {
    bool retryOriginal = false,
  }) async {
    lookups++;
    final c = pending.single;
    expect(requestId, c.requestId);
    if (retryOriginal) {
      retries++;
      pending = [];
      return ServingResult.parse(s.result(c), c);
    }
    return ServingResult.parse({
      'result': {'state': 'not_observed', 'requestId': c.requestId},
    }, c);
  }
}

LiveTable table() {
  final row =
      ((tableFixture()['result'] as Map)['tables'] as List).first
          as Map<String, dynamic>;
  (row['session'] as Map)['sessionRef'] = 'H00000000001';
  return LiveTable(row);
}

void main() {
  Future<void> show(
    WidgetTester tester,
    ServingAuth auth, {
    UiLanguage language = UiLanguage.en,
    int revision = 0,
    bool recovery = false,
  }) async {
    await tester.binding.setSurfaceSize(const Size(1366, 768));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: recovery
              ? LiveServingRecoveryPanel(
                  auth: auth,
                  language: language,
                  onBack: () {},
                )
              : LiveOrdersPanel(
                  auth: auth,
                  language: language,
                  table: table(),
                  revision: revision,
                  onBack: () {},
                ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  const open = ValueKey('serving-open-D00000000001-test-product');
  for (final language in UiLanguage.values) {
    testWidgets('delivery dialog validates counts and confirms in $language', (
      tester,
    ) async {
      final auth = ServingAuth();
      addTearDown(auth.dispose);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await show(tester, auth, language: language);
      await tester.tap(find.byKey(open));
      await tester.pumpAndSettle();
      final button = find.byKey(const ValueKey('serving-confirm-submit'));
      expect(tester.widget<FilledButton>(button).onPressed, isNull);
      expect(auth.writes, 0);
      for (final invalid in ['0', '3', '1.5', '-1']) {
        await tester.enterText(
          find.byKey(const ValueKey('serving-quantity')),
          invalid,
        );
        await tester.pump();
        expect(tester.widget<FilledButton>(button).onPressed, isNull);
      }
      await tester.enterText(
        find.byKey(const ValueKey('serving-quantity')),
        '1',
      );
      await tester.pump();
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(auth.writes, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
  for (final change in ['identity', 'revision', 'background']) {
    testWidgets('$change invalidates unsent serving confirmation', (
      tester,
    ) async {
      final auth = ServingAuth();
      addTearDown(auth.dispose);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await show(tester, auth);
      await tester.tap(find.byKey(open));
      await tester.pumpAndSettle();
      if (change == 'identity') {
        auth.notifyListeners();
      } else if (change == 'revision') {
        await show(tester, auth, revision: 1);
      } else {
        for (final state in [
          AppLifecycleState.inactive,
          AppLifecycleState.hidden,
          AppLifecycleState.paused,
          AppLifecycleState.hidden,
          AppLifecycleState.inactive,
          AppLifecycleState.resumed,
        ]) {
          tester.binding.handleAppLifecycleStateChanged(state);
          await tester.pump();
        }
      }
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(auth.writes, 0);
      if (change == 'background') {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpAndSettle();
      }
      await tester.pumpWidget(const SizedBox());
    });
  }
  testWidgets(
    'existing line request enters recovery without another confirmation',
    (tester) async {
      final auth = ServingAuth()
        ..pending = [s.command(product: 'test-product')];
      addTearDown(auth.dispose);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await show(tester, auth);
      await tester.tap(find.byKey(open));
      await tester.pumpAndSettle();
      expect(find.byType(LiveServingRecoveryPanel), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      expect(auth.writes, 0);
      expect(auth.lookups, 0);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'in-flight delivery blocks another tap and ignores stale failure after identity change',
    (tester) async {
      final auth = ServingAuth()
        ..sendGate = Completer<void>()
        ..failServing = true;
      addTearDown(auth.dispose);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await show(tester, auth);
      await tester.tap(find.byKey(open));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('serving-quantity')),
        '1',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('serving-confirm-submit')));
      await tester.pump(const Duration(milliseconds: 400));
      expect(auth.writes, 1);
      expect(tester.widget<OutlinedButton>(find.byKey(open)).onPressed, isNull);
      auth.notifyListeners();
      await tester.pump();
      auth.sendGate!.complete();
      await tester.pumpAndSettle();
      expect(auth.writes, 1);
      expect(find.byType(LiveServingRecoveryPanel), findsNothing);
      expect(auth.pending.length, 1);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('prepay pending and unknown progress offer no delivery action', (
    tester,
  ) async {
    final auth = ServingAuth()..timing = 'prepay';
    addTearDown(auth.dispose);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await show(tester, auth);
    expect(find.byKey(open), findsNothing);
    auth.timing = 'postpay';
    auth.unknown = true;
    await tester.tap(find.byKey(const ValueKey('orders-refresh')));
    await tester.pumpAndSettle();
    expect(find.byKey(open), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'uncertain submission opens original request recovery, not a second command',
    (tester) async {
      final auth = ServingAuth()..failServing = true;
      addTearDown(auth.dispose);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await show(tester, auth);
      await tester.tap(find.byKey(open));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('serving-quantity')),
        '1',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('serving-confirm-submit')));
      await tester.pumpAndSettle();
      expect(auth.writes, 1);
      expect(find.byType(LiveServingRecoveryPanel), findsOneWidget);
      expect(auth.lookups, 0);
      await tester.pumpWidget(const SizedBox());
    },
  );
  for (final language in UiLanguage.values) {
    testWidgets(
      'recovery is read-only until explicit original retry in $language',
      (tester) async {
        final auth = ServingAuth()..pending = [s.command()];
        addTearDown(auth.dispose);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final id = auth.pending.single.requestId;
        await show(tester, auth, recovery: true, language: language);
        expect(find.byKey(ValueKey('serving-retry-$id')), findsNothing);
        expect(auth.lookups, 0);
        await tester.tap(find.byKey(ValueKey('serving-lookup-$id')));
        await tester.pumpAndSettle();
        expect(auth.lookups, 1);
        expect(auth.retries, 0);
        await tester.tap(find.byKey(ValueKey('serving-retry-$id')));
        await tester.pumpAndSettle();
        expect(auth.retries, 0);
        expect(
          find.textContaining(tr(language, 'servingRetryNotice')),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const ValueKey('serving-retry-confirm')));
        await tester.pumpAndSettle();
        expect(auth.retries, 1);
        expect(auth.writes, 0);
        expect(auth.pending, isEmpty);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
  testWidgets('identity invalidation closes original retry without replay', (
    tester,
  ) async {
    final auth = ServingAuth()..pending = [s.command()];
    addTearDown(auth.dispose);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final id = auth.pending.single.requestId;
    await show(tester, auth, recovery: true);
    await tester.tap(find.byKey(ValueKey('serving-lookup-$id')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('serving-retry-$id')));
    await tester.pumpAndSettle();
    auth.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(auth.retries, 0);
    expect(find.byKey(ValueKey('serving-retry-$id')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}
