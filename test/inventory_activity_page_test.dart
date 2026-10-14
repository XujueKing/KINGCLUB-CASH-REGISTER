import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:kingclub_cash_register/src/live/inventory_panel.dart';
import 'package:kingclub_cash_register/src/strings.dart';

import 'live_tables_panel_test.dart' show TableAuth;

class ActivityAuth extends TableAuth {
  final calls = <Map<String, dynamic>>[];
  ActivityAuth()
    : super(permissions: ['workbench.read', 'report.read', 'shift.manage']);
  @override
  Future<Map<String, dynamic>> inventory(Map<String, dynamic> q) async {
    calls.add(q);
    const product = {
      'productRef': 'wine',
      'names': {'en': 'Test bottle'},
      'specifications': {'en': '700ml'},
    };
    final history = {
      'rowId': 1,
      'operationRef': '00000000-0000-4000-8000-000000000001',
      'type': 'count',
      'createdAt': '2026-01-01T00:00:00Z',
      'employee': 'Employee',
      'details': {'note': 'Count note'},
      'detailLoaded': false,
    };
    if (q['action'] == 'operation_detail') {
      return {
        'storeRef': 'test-store',
        'products': [product],
        'operation': {
          ...history,
          'details': {
            'items': [
              {
                'productRef': 'wine',
                'expectedOnHand': 2,
                'quantity': 3,
                'location': 'A1-1',
              },
            ],
          },
        },
      };
    }
    if (q['view'] == 'activity') {
      return {
        'storeRef': 'test-store',
        'view': 'activity',
        'section': q['section'],
        'products': [product],
        'locations': ['A1-1'],
        'offset': q['offset'],
        'secondaryOffset': q['secondaryOffset'],
        'total': q['section'] == 'loans' ? 51 : 1,
        'secondaryTotal': 1,
        if (q['section'] == 'loans')
          'loans': [
            {
              'rowId': 1,
              'operationRef': 'loan',
              'member': q['offset'] == 50 ? 'Next borrower' : 'First borrower',
              'items': {'productRef': 'wine', 'quantity': 10},
              'returnedQuantity': 4,
            },
          ],
        if (q['section'] == 'history') ...{
          'history': [history],
          'movements': [
            {'rowId': 1, 'productRef': 'wine', 'quantity': -1, 'type': 'sale'},
          ],
        },
        if (q['section'] == 'receiving') ...{
          'purchaseBatches': [],
          'purchases': [],
        },
      };
    }
    return {
      'storeRef': 'test-store',
      'view': 'stock',
      'paged': true,
      'total': 0,
      'products': [],
      'categories': [],
      'locations': ['A1-1'],
    };
  }
}

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  testWidgets(
    'operational tabs page independently, use returned totals and load full documents only on tap',
    (tester) async {
      tester.view.physicalSize = const Size(1274, 710);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final auth = ActivityAuth();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: InventoryPanel(
              auth: auth,
              language: UiLanguage.en,
              enableRealtime: false,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Loans'));
      await tester.pumpAndSettle();
      expect(auth.calls.last, containsPair('section', 'loans'));
      expect(find.text('Outstanding 6'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('activity-next-false')));
      await tester.pumpAndSettle();
      expect(auth.calls.last['offset'], 50);
      expect(find.textContaining('Next borrower'), findsOneWidget);
      await tester.tap(find.text('History'));
      await tester.pumpAndSettle();
      expect(auth.calls.last, containsPair('section', 'history'));
      expect(auth.calls.last['offset'], 0);
      expect(
        auth.calls.where((q) => q['action'] == 'operation_detail'),
        isEmpty,
      );
      await tester.tap(find.textContaining('Employee · Count note'));
      await tester.pumpAndSettle();
      expect(auth.calls.last['action'], 'operation_detail');
      expect(find.textContaining('2 → 3 · A1-1'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.textContaining('Test bottle 700ml'),
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Outgoing'));
      await tester.tap(find.text('Outgoing'));
      await tester.pumpAndSettle();
      expect(auth.calls.last['movementFilter'], 'out');
      expect(auth.calls.last['secondaryOffset'], 0);
      await tester.tap(find.text('Receive stock').first);
      await tester.pumpAndSettle();
      expect(auth.calls.last['section'], 'receiving');
      expect(auth.calls.last['offset'], 0);
      await tester.tap(find.text('Stock').first);
      await tester.pumpAndSettle();
      expect(auth.calls.last['view'], 'stock');
      expect(
        auth.calls.every(
          (q) => [
            'context',
            'operation_detail',
            'product_images',
          ].contains(q['action']),
        ),
        isTrue,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
