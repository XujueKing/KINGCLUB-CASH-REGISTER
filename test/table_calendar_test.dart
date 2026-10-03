import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/live/table_calendar_panel.dart';
import 'package:kingclub_cash_register/src/strings.dart';

import 'live_tables_panel_test.dart' show TableAuth;

class CalendarAuth extends TableAuth {
  CalendarAuth()
    : super(permissions: ['workbench.read', 'orders.read', 'table.open']);
  final dates = <String>[];
  final mutations = <Map<String, Object>>[];
  bool appReady = false;
  @override
  Future<Object?> readTableCalendar({
    required String selectedDate,
    String? afterSession,
  }) async {
    dates.add(selectedDate);
    return {
      'result': {
        'store': {'storeRef': 'test-store'},
        'operator': {'employeeRef': session.employeeRef},
        'selectedDate': selectedDate,
        'reservationsAvailable': true,
        'appReservationsAvailable': appReady,
        'historySessions': [],
        'nextAfterSession': null,
        'availableTables': [
          {'tableRef': 'table-test', 'tableName': 'T1', 'maximumSeats': 6},
        ],
        'reservations': mutations.isEmpty
            ? [
                {
                  'reservationRef': '00000000-0000-4000-8000-000000000001',
                  'tableRef': 'table-test',
                  'tableName': 'T1',
                  'guestName': 'Test guest',
                  'partySize': 2,
                  'startsAt': '2030-01-02T10:00:00.000Z',
                  'endsAt': '2030-01-02T14:00:00.000Z',
                  'source': 'cashier',
                },
              ]
            : [],
      },
    };
  }

  @override
  Future<Object?> saveTableReservation(Map<String, Object> params) async {
    mutations.add(params);
    return {
      'result': {
        'reservationRef': params['reservationRef'],
        'status': 'cancelled',
      },
    };
  }
}

void main() {
  test('business day changes at six including month boundary', () {
    expect(tableBusinessDay(DateTime(2030, 1, 1, 5, 59)), DateTime(2029, 12, 31));
    expect(tableBusinessDay(DateTime(2030, 1, 1, 6)), DateTime(2030, 1, 1));
  });

  test('calendar short labels cross year boundaries', () {
    final now = DateTime(2030, 1, 1, 8, 5);
    expect(tableCalendarLabel(now, now, UiLanguage.zh), '今日 08:05');
    expect(
      tableCalendarLabel(DateTime(2029, 12, 31), now, UiLanguage.zh),
      '昨日',
    );
    expect(tableCalendarLabel(DateTime(2030, 1, 2), now, UiLanguage.zh), '明日');
  });
  testWidgets(
    'reads selected date, shows manual booking yellow and cancels original reference',
    (tester) async {
      final auth = CalendarAuth();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TableCalendarPanel(
              auth: auth,
              language: UiLanguage.zh,
              date: DateTime(2030, 1, 2),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(auth.dates, ['2030-01-02']);
      expect(find.textContaining('Test guest'), findsOneWidget);
      expect(
        tester.widget<Card>(find.byType(Card).first).color,
        const Color(0xFFFACC15),
      );
      expect(find.text('APP组局同步尚未在此服务器启用'), findsOneWidget);
      await tester.tap(find.text('取消预留'));
      await tester.pumpAndSettle();
      expect(
        auth.mutations.single['reservationRef'],
        '00000000-0000-4000-8000-000000000001',
      );
      expect(find.textContaining('Test guest'), findsNothing);
      // Unconnected APP is not reported as a wholly empty reservation book.
      expect(find.text('该营业日暂无预订'), findsNothing);
    },
  );
}
