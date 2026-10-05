import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:kingclub_cash_register/src/workbench_page.dart';
import 'package:kingclub_cash_register/src/live/live_tables_panel.dart';
import 'package:kingclub_cash_register/src/live/table_calendar_panel.dart';
import 'package:kingclub_cash_register/src/live/table_history_data.dart';
import 'package:kingclub_cash_register/src/live/table_snapshot.dart';
import 'package:kingclub_cash_register/src/live/table_bill_panel.dart';
import 'package:kingclub_cash_register/src/live/bill_product_card.dart';
import 'package:kingclub_cash_register/src/strings.dart';

import 'table_bill_panel_test.dart' show BillAuth;
import 'support/table_fixture.dart';

class HistoryAuth extends BillAuth {
  @override
  Future<Map<String, dynamic>> wineStorage(Map<String, dynamic> params) async =>
      {
        'items': params['sessionRef'] == 'old-0'
            ? [
                {
                  'itemRef': 'stored-test',
                  'name': 'Stored bottle',
                  'remainingPercent': 50,
                  'specification': '750ML',
                  'served': false,
                },
              ]
            : [],
      };
  bool wrongStore = false;
  @override
  Future<Object?> readTableCalendar({
    required String selectedDate,
    String? afterSession,
  }) async => {
    'result': {
      'store': {'storeRef': wrongStore ? 'another-store' : session.storeRef},
      'operator': {'employeeRef': session.employeeRef},
      'selectedDate': selectedDate,
      'availableTables': [
        {'tableRef': 'test-000', 'tableName': 'V1', 'maximumSeats': 6},
        {'tableRef': 'test-001', 'tableName': 'V2', 'maximumSeats': 6},
      ],
      'reservations': [],
      'nextAfterSession': null,
      'historySessions': [
        for (var n = 0; n < 2; n++)
          {
            'tableRef': 'test-000',
            'tableName': 'V1',
            'sessionRef': 'old-$n',
            'status': 'closed',
            'partySize': n + 2,
            'openedAt': '${selectedDate}T${n == 0 ? '08' : '12'}:00:00.000Z',
            'closedAt': '${selectedDate}T${n == 0 ? '10' : '14'}:00:00.000Z',
          },
      ],
    },
  };

  @override
  Future<Object?> readOrders({
    required String tableRef,
    required String sessionRef,
    String? afterOrder,
  }) async {
    final result = await super.readOrders(
      tableRef: tableRef,
      sessionRef: sessionRef,
      afterOrder: afterOrder,
    );
    final data = (result as Map)['result'] as Map;
    data.remove('sessionSummary');
    if (sessionRef.startsWith('old-')) data['session']['status'] = 'closed';
    final order = data['orders'][0];
    order['orderRef'] = 'D-${sessionRef}';
    order['status'] = sessionRef == 'old-0' ? 'paid' : 'pending';
    return result;
  }
}

void main() {
  testWidgets(
    'sidebar ordering asks before leaving history and switches date with data',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      tester.view.physicalSize = const Size(1366, 768);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final auth = HistoryAuth();
      await tester.pumpWidget(
        MaterialApp(
          home: WorkbenchPage(
            auth: auth,
            language: UiLanguage.en,
            onLanguage: (_) {},
            onLogout: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      final day = tableBusinessDay(DateTime.now())
          .subtract(const Duration(days: 1));
      await tester.tap(find.byKey(const ValueKey('table-calendar')));
      await tester.pumpAndSettle();
      Navigator.of(tester.element(find.byType(DatePickerDialog))).pop(day);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('live-table-test-000')));
      await tester.pumpAndSettle();
      final historical = tester.state<LiveTablesPanelState>(
        find.byType(LiveTablesPanel),
      );
      await tester.tap(find.byKey(const ValueKey('nav-1')));
      await tester.pumpAndSettle();
      expect(find.text('Return to today first'), findsOneWidget);
      expect(historical.selectedDate, day);
      expect(
        tester
            .widget<LiveTablesPanel>(find.byType(LiveTablesPanel))
            .menuVisible,
        isFalse,
      );
      await tester.tap(find.text('Keep viewing'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('nav-0')));
      await tester.pumpAndSettle();
      expect(find.text('Yesterday'), findsOneWidget);
      expect(
        tester.widget<TableBillPanel>(find.byType(TableBillPanel)).readOnly,
        isTrue,
      );
      final reads = auth.requested.length;
      await tester.tap(find.byKey(const ValueKey('nav-1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('history-return-today')));
      await tester.pumpAndSettle();
      expect(historical.selectedDate, isNull);
      expect(historical.history, isNull);
      expect(historical.focusedTableRef, isNull);
      expect(auth.requested.length, greaterThan(reads));
      expect(
        tester
            .widget<LiveTablesPanel>(find.byType(LiveTablesPanel))
            .menuVisible,
        isTrue,
      );
      await tester.tap(find.byKey(const ValueKey('nav-0')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Today'), findsOneWidget);
      expect(historical.snapshot!.tables.first.session!.pendingCents, 7800);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      auth.dispose();
    },
  );

  test(
    'history aggregates both sessions and never borrows current-day totals',
    () async {
      final auth = HistoryAuth();
      final currentRaw = tableFixture(count: 2);
      currentRaw['result']['tables'] = (currentRaw['result']['tables'] as List)
          .reversed
          .toList();
      final current = TableSnapshot.parse(
        currentRaw,
        storeRef: auth.session.storeRef,
        employeeRef: auth.session.employeeRef,
      );
      final history = await TableHistoryData.read(auth, current, '2026-09-28');
      expect(history.snapshot.tables.map((t) => t.reference), [
        'test-001',
        'test-000',
      ]);
      final table = history.snapshot.tables.last;
      expect(table.session!.paidCents, 1200);
      expect(table.session!.pendingCents, 1200);
      expect(history.scopes(table.reference).length, 2);
      expect(history.snapshot.tables.first.session, isNull);
      expect(current.tables.first.session!.pendingCents, 7800);
      auth.wrongStore = true;
      await expectLater(
        TableHistoryData.read(auth, current, '2026-09-28'),
        throwsFormatException,
      );
      auth.dispose();
    },
  );

  testWidgets(
    'calendar preserves table grid and freezes bill except print and filter',
    (tester) async {
      tester.view.physicalSize = const Size(1366, 768);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final auth = HistoryAuth();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LiveTablesPanel(
              auth: auth,
              language: UiLanguage.en,
              enableRealtime: false,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('table-calendar')));
      await tester.pumpAndSettle();
      Navigator.of(
        tester.element(find.byType(DatePickerDialog)),
      ).pop(tableBusinessDay(DateTime.now()).subtract(const Duration(days: 1)));
      await tester.pumpAndSettle();
      expect(find.byType(TableCalendarPanel), findsNothing);
      expect(find.byKey(const ValueKey('live-table-test-000')), findsOneWidget);
      expect(find.byKey(const ValueKey('live-table-test-001')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('live-table-test-000')));
      await tester.pumpAndSettle();
      final bill = tester.widget<TableBillPanel>(find.byType(TableBillPanel));
      expect(bill.readOnly, isTrue);
      expect(bill.seatSessions.length, 2);
      final product = tester
          .widgetList<BillProductCard>(find.byType(BillProductCard))
          .singleWhere((card) => card.name == 'Test product');
      expect(
        tester
            .widget<BillProductCard>(
              find.byKey(const ValueKey('stored-wine-stored-test')),
            )
            .onTap,
        isNull,
      );
      expect(product.quantity, 4);
      expect(product.onTap, isNull);
      expect(product.onMinus, isNull);
      expect(product.onPlus, isNull);
      final pay = tester.widget<FilledButton>(
        find.byKey(const ValueKey('table-bill-checkout')),
      );
      expect(pay.onPressed, isNull);
      expect(
        pay.style!.backgroundColor!.resolve({WidgetState.disabled}),
        isNull,
      );
      expect(
        tester
            .widget<OutlinedButton>(
              find.byKey(const ValueKey('table-bill-print')),
            )
            .onPressed,
        isNotNull,
      );
      expect(
        tester
            .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, 'Menu'))
            .onPressed,
        isNull,
      );
      await tester.tap(find.byKey(const ValueKey('live-table-test-001')));
      await tester.pumpAndSettle();
      expect(auth.openingReads, 0);
      expect(
        tester.widget<TableBillPanel>(find.byType(TableBillPanel)).emptySeat,
        isTrue,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      auth.dispose();
    },
  );
}
