import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/live/live_orders_panel.dart';
import 'package:kingclub_cash_register/src/live/table_snapshot.dart';
import 'package:kingclub_cash_register/src/strings.dart';

import 'order_snapshot_test.dart' show parse;
import 'live_orders_panel_test.dart' show OrdersAuth;
import 'support/order_fixture.dart';
import 'support/table_fixture.dart';

Map<String, dynamic> summary() => {
  'currency': 'CNY',
  'paid': {'orderCount': 2, 'totalCents': 3600},
  'pending': {'orderCount': 3, 'totalCents': 4800},
  'expired': {'orderCount': 1, 'totalCents': 600},
};
Map<String, dynamic> fixture() {
  final raw = orderFixture();
  (raw['result'] as Map)['sessionSummary'] = summary();
  return raw;
}

void main() {
  test('whole-session totals are not the visible page total', () {
    final value = parse(fixture());
    expect(value.orders.single.totalCents, 1200);
    expect(value.sessionSummary!.buckets['pending']!.totalCents, 4800);
    expect(() => value.sessionSummary!.buckets.clear(), throwsUnsupportedError);
    expect(parse(orderFixture()).sessionSummary, isNull);
  });
  for (final invalid in [
    null,
    {},
    {...summary(), 'currency': 'USD'},
    {...summary(), 'extra': true},
    {
      ...summary(),
      'pending': {'orderCount': 0, 'totalCents': 0},
    },
    {
      ...summary(),
      'pending': {'orderCount': 3, 'totalCents': 1199},
    },
    {
      ...summary(),
      'paid': {'orderCount': 0, 'totalCents': 1},
    },
    {
      ...summary(),
      'paid': {'orderCount': 2.0, 'totalCents': 3600},
    },
    {
      ...summary(),
      'paid': {'orderCount': 1, 'totalCents': 9007199254740991},
    },
  ]) {
    test('rejects malformed or conflicting session summary $invalid', () {
      final raw = orderFixture();
      (raw['result'] as Map)['sessionSummary'] = invalid;
      expect(() => parse(raw), throwsFormatException);
    });
  }
  for (final language in UiLanguage.values) {
    testWidgets(
      'summary and old-server unknown presentation ${language.name}',
      (tester) async {
        tester.view.physicalSize = const Size(1024, 600);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final auth = OrdersAuth()
          ..ordersGate = (Completer<Object?>()..complete(fixture()));
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: LiveOrdersPanel(
                auth: auth,
                language: language,
                revision: 0,
                onBack: () {},
                table: LiveTable(
                  ((tableFixture()['result'] as Map)['tables'] as List).first
                      as Map<String, dynamic>,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.text('${tr(language, 'order_pending')}: 3 · CNY 48.00'),
          findsOneWidget,
        );
        expect(find.text(tr(language, 'sessionSummaryTitle')), findsOneWidget);
        expect(tester.takeException(), isNull);
        auth.ordersGate = Completer<Object?>()..complete(orderFixture());
        await tester.tap(find.byKey(const ValueKey('orders-refresh')));
        await tester.pumpAndSettle();
        expect(
          find.text(tr(language, 'sessionSummaryUnknown')),
          findsOneWidget,
        );
        expect(
          find.text('${tr(language, 'order_pending')}: 3 · CNY 48.00'),
          findsNothing,
        );
        await tester.pumpWidget(const SizedBox());
        auth.dispose();
      },
    );
  }
}
