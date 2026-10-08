import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:kingclub_cash_register/src/live/reservations_panel.dart';
import 'package:kingclub_cash_register/src/strings.dart';

import 'live_tables_panel_test.dart' show TableAuth;

class BookingAuth extends TableAuth {
  BookingAuth() : super(permissions: ['workbench.read', 'table.open']);
  final calls = <Map<String, dynamic>>[];
  @override
  Future<Map<String, dynamic>> reservations(
    Map<String, dynamic> command,
  ) async {
    calls.add(command);
    return {
      'storeRef': 'test-store',
      'tables': [
        {'tableRef': 'v1', 'tableName': 'V1', 'capacity': 10},
      ],
      'reservations': [
        {
          'ref': 'phone',
          'guestName': 'Test guest',
          'source': 'cashier',
          'partySize': 2,
          'mode': 'aa',
          'status': 'waiting',
          'startsAt': '2026-10-06T11:00:00Z',
          'endsAt': '2026-10-06T14:00:00Z',
          'phone': '00000000000',
          'paidCount': 0,
        },
        {
          'ref': 'app',
          'guestName': 'APP booking',
          'source': 'app',
          'partySize': 10,
          'mode': 'aa',
          'status': 'reserved',
          'tableName': 'V1',
          'tableRef': 'v1',
          'startsAt': '2026-10-06T11:00:00Z',
          'endsAt': '2026-10-06T14:00:00Z',
          'paidCount': 2,
          'members': [],
        },
      ],
    };
  }
}

class DepositBookingAuth extends BookingAuth {
  DepositBookingAuth({this.canArrive = true, this.paid = true});
  final bool canArrive;
  final bool paid;
  bool arrived = false;
  bool cancelled = false;
  @override
  Future<Map<String, dynamic>> reservations(
    Map<String, dynamic> command,
  ) async {
    calls.add(command);
    if (command['action'] == 'cancel') cancelled = true;
    if (command['action'] == 'arrived') {
      if (command['sessionRef'] != 'H00000000001') {
        throw StateError('Original session required');
      }
      arrived = true;
    }
    return {
      'storeRef': 'test-store',
      'tables': [
        {'tableRef': 'v1', 'tableName': 'V1', 'capacity': 10},
      ],
      'reservations': [
        {
          'ref': 'original-deposit',
          'kind': 'reservation',
          'source': 'app',
          'guestName': 'Deposit guest',
          'partySize': 3,
          'mode': 'table',
          'status': cancelled
              ? 'cancelled'
              : arrived
              ? 'arrived'
              : 'reserved',
          'tableName': 'V1',
          'tableRef': 'v1',
          'payment': paid ? 'deposit_paid' : 'free',
          'depositCents': '120000',
          'canArrange': 0,
          'canArrive': canArrive ? 1 : 0,
          'activeSessionRef': canArrive ? 'H00000000001' : null,
          'startsAt': '2026-10-06T11:00:00Z',
          'endsAt': '2026-10-06T14:00:00Z',
        },
      ],
    };
  }
}

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  testWidgets(
    'APP free reservation can cancel without a fake payment or another fetch',
    (tester) async {
      tester.view.physicalSize = const Size(1274, 710);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final auth = DepositBookingAuth(paid: false);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReservationsPanel(
              auth: auth,
              language: UiLanguage.zh,
              enableRealtime: false,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Deposit guest').first);
      await tester.pumpAndSettle();
      expect(find.text('免费预约'), findsOneWidget);
      expect(find.text('已电话通知付款加入'), findsNothing);
      await tester.tap(find.widgetWithText(OutlinedButton, '取消预约'));
      await tester.pumpAndSettle();
      expect(
        tester.getSize(find.widgetWithText(FilledButton, '取消预约')).height,
        52,
      );
      await tester.tap(find.widgetWithText(FilledButton, '取消预约'));
      await tester.pumpAndSettle();
      expect(auth.cancelled, isTrue);
      expect(auth.calls.length, 2);
      expect(auth.calls.last['action'], 'cancel');
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'APP deposit arrival uses the original session and full returned page',
    (tester) async {
      tester.view.physicalSize = const Size(1274, 710);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final auth = DepositBookingAuth();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReservationsPanel(
              auth: auth,
              language: UiLanguage.zh,
              enableRealtime: false,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Deposit guest').first);
      await tester.pumpAndSettle();
      expect(find.text('已付定金 CNY 1,200.00'), findsOneWidget);
      final assign = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, '安排位置'),
      );
      expect(assign.onPressed, isNull);
      await tester.tap(find.widgetWithText(OutlinedButton, '已到店'));
      await tester.pumpAndSettle();
      expect(auth.calls.length, 2);
      expect(auth.calls.last, containsPair('sessionRef', 'H00000000001'));
      expect(auth.arrived, isTrue);
      expect(find.widgetWithText(OutlinedButton, '已到店'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('paid reservation requires opening and linking before arrival', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1274, 710);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final auth = DepositBookingAuth(canArrive: false);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ReservationsPanel(
            auth: auth,
            language: UiLanguage.zh,
            enableRealtime: false,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Deposit guest').first);
    await tester.pumpAndSettle();
    expect(find.text('先开台并关联原付款会员，再确认到店。'), findsOneWidget);
    expect(
      tester
          .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '已到店'))
          .onPressed,
      isNull,
    );
    expect(auth.calls.length, 1);
    expect(tester.takeException(), isNull);
  });
  for (final lang in UiLanguage.values) {
    testWidgets('booking layout ${lang.name}', (tester) async {
      tester.view.physicalSize = const Size(1274, 710);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final auth = BookingAuth();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReservationsPanel(
              auth: auth,
              language: lang,
              enableRealtime: false,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Test guest').first);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(auth.calls.length, 1);
      await tester.tap(find.textContaining('APP booking').first);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(auth.calls.length, 1);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
