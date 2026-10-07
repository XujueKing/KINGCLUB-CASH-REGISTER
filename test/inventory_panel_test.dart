import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:kingclub_cash_register/src/live/inventory_panel.dart';
import 'package:kingclub_cash_register/src/strings.dart';

import 'live_tables_panel_test.dart' show TableAuth;

class InventoryAuth extends TableAuth {
  InventoryAuth()
    : super(permissions: ['workbench.read', 'report.read', 'shift.manage']);
  final calls = <Map<String, dynamic>>[];
  Map<String, dynamic>? batch;
  @override
  Future<Map<String, dynamic>> inventory(Map<String, dynamic> command) async {
    calls.add(command);
    if (command['action'] == 'purchase_batch') return batch!;
    if (command['action'] == 'purchase_batch_save') {
      batch = {
        ...command,
        'status': command['submit'] == true ? 'pending' : 'draft',
        'revision': (command['revision'] as int) + 1,
        'items': [
          for (final i in command['items'] as List)
            {
              ...i as Map,
              'names': {'zh-CN': '测试酒品', 'en': 'Test wine'},
              'specifications': {'zh-CN': '500ML'},
              'supplierName': i['supplierRef'] == 'test-supplier'
                  ? 'Test supplier'
                  : 'Other supplier',
            },
        ],
      };
    }
    return {
      'storeRef': 'test-store',
      'categories': [
        {
          'categoryRef': 'wine',
          'names': {'zh-CN': '洋酒', 'en': 'Spirits'},
          'sortOrder': 1,
        },
      ],
      'locations': ['A1-1', 'A1-2'],
      'products': [
        {
          'productRef': 'wine',
          'categoryRef': 'wine',
          'lowStock': 0,
          'names': {'zh-CN': '测试酒品', 'en': 'Test wine'},
          'specifications': {'zh-CN': '500ML'},
          'onHand': 10,
          'reserved': 2,
          'available': 8,
          'policy': null,
          'quotes': [
            {
              'supplierRef': 'test-supplier',
              'supplierName': 'Test supplier',
              'key': 'a' * 64,
              'quoteCents': 3500,
              'quoteUnit': '瓶',
              'unitCostCents': 3500,
              'specification': '12*500ml',
            },
            {
              'supplierRef': 'other-supplier',
              'supplierName': 'Other supplier',
              'key': 'b' * 64,
              'quoteCents': 4000,
              'quoteUnit': '瓶',
              'unitCostCents': 4000,
              'specification': '12*500ml',
            },
          ],
          'onOrder': 0,
          'suggested': 0,
        },
      ],
      'batches': [
        {
          'productRef': 'wine',
          'location': 'A1-1',
          'quantity': 10,
          'unitCostCents': 1000,
          'createdAt': '2026-10-01T00:00:00Z',
        },
      ],
      'suppliers': [
        {
          'supplierRef': 'other-supplier',
          'name': 'Other supplier',
          'active': 1,
          'revision': 1,
          'contact': '',
          'phone': '',
          'notes': '',
        },
        {
          'supplierRef': 'test-supplier',
          'name': 'Test supplier',
          'active': 1,
          'revision': 1,
          'contact': '',
          'phone': '',
          'notes': '',
        },
      ],
      'purchaseBatches': batch == null
          ? []
          : [
              {
                ...batch!,
                'itemCount': (batch!['items'] as List).length,
                'totalCostCents': 0,
                'createdAt': '2026-10-07T00:00:00Z',
              },
            ],
      'receipt': batch == null ? null : {'batch': batch},
      'purchases': [
        {
          'purchaseRef': 'test-purchase',
          'productRef': 'wine',
          'supplierRef': 'test-supplier',
          'quantity': 10,
          'received': 0,
          'unitCostCents': 1000,
          'createdAt': '2026-10-01T00:00:00Z',
        },
      ],
      'loans': [
        {
          'operationRef': 'test-loan',
          'member': 'Test member',
          'userAccount': 'KM00000000001',
          'items': {'productRef': 'wine', 'quantity': 2},
          'returns': [],
          'createdAt': '2026-10-01T00:00:00Z',
        },
      ],
      'history': [],
      'movements': [],
      'lastCountAt': null,
    };
  }
}

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  testWidgets(
    'creates a batch, adds locally and submits quoted goods together',
    (tester) async {
      tester.view.physicalSize = const Size(1274, 710);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final auth = InventoryAuth();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: InventoryPanel(
              auth: auth,
              language: UiLanguage.zh,
              enableRealtime: false,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('采购').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('新增采购申请'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('purchase-product-wine')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('purchase-product-wine')));
      await tester.pumpAndSettle();
      expect(
        auth.calls.length,
        2,
        reason: 'Adding products edits the batch locally',
      );
      expect(find.textContaining('¥ 35.00 × 2'), findsOneWidget);
      await tester.tap(find.text('提交申请'));
      await tester.pumpAndSettle();
      final command = auth.calls.singleWhere(
        (c) => c['action'] == 'purchase_batch_save' && c['submit'] == true,
      );
      expect(command['items'], [
        {
          'productRef': 'wine',
          'supplierRef': 'test-supplier',
          'quantity': 2,
          'unitCostCents': 3500,
          'manualCost': false,
          'quoteKey': 'a' * 64,
        },
      ]);
      expect(auth.calls.where((c) => c['action'] == 'purchase'), isEmpty);
      expect(find.text('待批准'), findsWidgets);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets('category and stock filtering require no additional requests', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1274, 710);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final auth = InventoryAuth();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InventoryPanel(
            auth: auth,
            language: UiLanguage.zh,
            enableRealtime: false,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('inventory-category-wine')));
    await tester.pumpAndSettle();
    expect(find.textContaining('测试酒品'), findsWidgets);
    await tester.tap(find.byKey(const ValueKey('inventory-stock-empty')));
    await tester.pumpAndSettle();
    expect(find.text('没有符合条件的商品'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('inventory-stock-low')));
    await tester.pumpAndSettle();
    expect(find.text('没有符合条件的商品'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('inventory-stock-all')));
    await tester.pumpAndSettle();
    expect(find.textContaining('测试酒品'), findsWidgets);
    expect(auth.calls.length, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets(
    'switching supplier uses its quotation and closes by saving the batch draft',
    (tester) async {
      tester.view.physicalSize = const Size(1274, 710);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final auth = InventoryAuth();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: InventoryPanel(
              auth: auth,
              language: UiLanguage.zh,
              enableRealtime: false,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('采购').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('新增采购申请'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('purchase-product-wine')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('purchase-line-wine-test-supplier')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Other supplier').last);
      await tester.pumpAndSettle();
      expect(find.textContaining('¥ 40.00'), findsWidgets);
      await tester.tap(find.text('确定').last);
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Other supplier · ¥ 40.00 × 1'),
        findsOneWidget,
      );
      expect(
        auth.calls.length,
        2,
        reason: 'Price changes and supplier selection remain local',
      );
      await tester.tap(find.byIcon(Icons.close).last);
      await tester.pumpAndSettle();
      final saved = auth.calls.last;
      expect(saved['action'], 'purchase_batch_save');
      expect(saved['submit'], false);
      expect(saved['items'], [
        {
          'productRef': 'wine',
          'supplierRef': 'other-supplier',
          'quantity': 1,
          'unitCostCents': 4000,
          'manualCost': false,
          'quoteKey': 'b' * 64,
        },
      ]);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  for (final lang in UiLanguage.values) {
    testWidgets('inventory touch layout and tabs ${lang.name}', (tester) async {
      tester.view.physicalSize = const Size(1274, 710);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final auth = InventoryAuth();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: InventoryPanel(
              auth: auth,
              language: lang,
              enableRealtime: false,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(auth.calls.length, 1);
      for (var i = 0; i < 6; i++) {
        await tester.tap(find.byKey(ValueKey('inventory-tab-$i')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
      expect(
        auth.calls.length,
        1,
        reason: 'Changing tabs must not reload the page',
      );
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
  testWidgets('count keypad changes only local draft until final submit', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1274, 710);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final auth = InventoryAuth();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InventoryPanel(
            auth: auth,
            language: UiLanguage.values.first,
            enableRealtime: false,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('盘点').first);
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('测试酒品').first);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(auth.calls.where((c) => c['action'] != 'context'), isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
