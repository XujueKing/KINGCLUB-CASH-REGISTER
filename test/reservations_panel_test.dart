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

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
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
