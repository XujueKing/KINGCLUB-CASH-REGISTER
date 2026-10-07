import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:kingclub_cash_register/src/live/inventory_panel.dart';
import 'package:kingclub_cash_register/src/strings.dart';

import 'live_tables_panel_test.dart' show TableAuth;

class InventoryAuth extends TableAuth {
  InventoryAuth({
    this.preferUnquotedSupplier = false,
    this.preferExpensiveSupplier = false,
    this.fullSupplierCatalog = false,
    this.unknownSupplierUnitCost = false,
  }) : super(permissions: ['workbench.read', 'report.read', 'shift.manage']);
  final bool preferUnquotedSupplier;
  final bool preferExpensiveSupplier;
  final bool fullSupplierCatalog;
  final bool unknownSupplierUnitCost;
  final calls = <Map<String, dynamic>>[];
  Map<String, dynamic>? batch;
  @override
  Future<Map<String, dynamic>> inventory(Map<String, dynamic> command) async {
    calls.add(command);
    if (command['action'] == 'purchase_batch') return batch!;
    if (command['action'] == 'purchase_batch_delete') {
      batch = {
        ...batch!,
        'status': 'cancelled',
        'revision': (batch!['revision'] as int) + 1,
      };
    }
    if (command['action'] == 'purchase_batch_save') {
      batch = {
        ...command,
        'status': command['submit'] == true ? 'pending' : 'draft',
        'revision': (command['revision'] as int) + 1,
        'items': [
          for (final i in command['items'] as List)
            {
              ...i as Map,
              if (fullSupplierCatalog && i['productRef'] == 'c' * 64) ...{
                'productRef': 'new-store-product',
                'sharedProductKey': 'c' * 64,
              },
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
          'policy': preferUnquotedSupplier
              ? {'supplierRef': 'unquoted-supplier'}
              : preferExpensiveSupplier
              ? {'supplierRef': 'other-supplier'}
              : null,
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
          ].reversed.toList(),
          'onOrder': 0,
          'suggested': 0,
        },
      ],
      if (fullSupplierCatalog)
        'procurementProducts': [
          {
            'productRef': 'c' * 64,
            'sharedProductKey': 'c' * 64,
            'names': {'zh-CN': '供应商专供酒'},
            'specifications': {'zh-CN': '700ML'},
            'quotes': [
              {
                'supplierRef': 'test-supplier',
                'supplierName': 'Test supplier',
                'key': 'd' * 64,
                'unitCostCents': unknownSupplierUnitCost ? null : 2600,
                'quoteCents': 2600,
                'quoteUnit': '瓶',
                'specification': '700ml',
              },
            ],
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
        if (preferUnquotedSupplier)
          {
            'supplierRef': 'unquoted-supplier',
            'name': 'Unquoted supplier',
            'active': 1,
            'revision': 1,
          },
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
  for (final expensive in [false, true]) {
    testWidgets(
      'uses the cheapest valid quotation despite ${expensive ? 'a priced expensive' : 'an unquoted'} preferred supplier',
      (tester) async {
        tester.view.physicalSize = const Size(1274, 710);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final auth = InventoryAuth(
          preferUnquotedSupplier: !expensive,
          preferExpensiveSupplier: expensive,
        );
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
        await tester.tap(find.text('采购申请').first);
        await tester.pumpAndSettle();
        await tester.tap(find.text('新增采购申请'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('purchase-product-wine')));
        await tester.pumpAndSettle();
        expect(find.text('Test supplier'), findsOneWidget);
        await tester.tap(
          find.byKey(const ValueKey('purchase-line-wine-test-supplier')),
        );
        await tester.pumpAndSettle();
        expect(find.text('已按供应商报价自动带入'), findsOneWidget);
        expect(find.text('调整实际进货价'), findsOneWidget);
        expect(find.text('录入实际进货价'), findsNothing);
        expect(auth.calls, hasLength(1));
        await tester.tap(find.text('取消').last);
        await tester.pumpAndSettle();
        await tester.tap(find.text('保存草稿'));
        await tester.pumpAndSettle();
        await tester.tap(find.byIcon(Icons.close).last);
        await tester.pumpAndSettle();
        expect(
          (auth.calls.last['items'] as List).single,
          containsPair('unitCostCents', 3500),
        );
        expect(
          (auth.calls.last['items'] as List).single,
          containsPair('manualCost', false),
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
  testWidgets(
    'closing empty, emptied or filled new applications never saves drafts',
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
      await tester.tap(find.text('采购申请').first);
      await tester.pumpAndSettle();
      for (var i = 0; i < 4; i++) {
        await tester.tap(find.text('新增采购申请'));
        await tester.pumpAndSettle();
        if (i >= 2) {
          await tester.tap(find.byKey(const ValueKey('purchase-product-wine')));
          await tester.pumpAndSettle();
          if (i == 2) {
            await tester.tap(
              find.byKey(
                const ValueKey('cart-minus-purchase-wine-test-supplier'),
              ),
            );
            await tester.pumpAndSettle();
          }
        }
        await tester.tap(find.byIcon(Icons.close).last);
        await tester.pumpAndSettle();
      }
      expect(auth.calls, hasLength(1));
      expect(auth.batch, isNull);
      expect(find.byIcon(Icons.delete_outline), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'deletes an existing empty draft with one action and removes it from the list',
    (tester) async {
      tester.view.physicalSize = const Size(1274, 710);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const batchRef = '00000000-0000-4000-8000-000000000020';
      final auth = InventoryAuth()
        ..batch = {
          'batchRef': batchRef,
          'title': 'Empty draft',
          'revision': 1,
          'status': 'draft',
          'items': <Map<String, dynamic>>[],
        };
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
      await tester.tap(find.text('采购申请').first);
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('delete-purchase-draft-$batchRef')),
      );
      await tester.pumpAndSettle();
      expect(auth.calls, hasLength(2));
      expect(auth.calls.last, containsPair('action', 'purchase_batch_delete'));
      expect(auth.calls.last, containsPair('revision', 1));
      expect(
        find.byKey(const ValueKey('purchase-batch-$batchRef')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'supplier-only goods can be ordered and edited after explicit save',
    (tester) async {
      tester.view.physicalSize = const Size(1274, 710);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final auth = InventoryAuth(fullSupplierCatalog: true);
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
      await tester.tap(find.text('采购申请').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('新增采购申请'));
      await tester.pumpAndSettle();
      final choice = find.byKey(ValueKey('purchase-product-${'c' * 64}'));
      expect(choice, findsOneWidget);
      await tester.tap(choice);
      await tester.pumpAndSettle();
      expect(auth.calls, hasLength(1));
      expect(find.text('采购单价 ¥ 26.00'), findsOneWidget);
      await tester.tap(find.text('保存草稿'));
      await tester.pumpAndSettle();
      expect(auth.calls, hasLength(2));
      final saved = find.byKey(
        const ValueKey('purchase-line-new-store-product-test-supplier'),
      );
      await tester.tap(saved);
      await tester.pumpAndSettle();
      expect(find.text('已按供应商报价自动带入'), findsOneWidget);
      await tester.tap(find.text('取消').last);
      await tester.pumpAndSettle();
      await tester.tap(choice);
      await tester.pumpAndSettle();
      expect(find.text('2'), findsOneWidget);
      expect(saved, findsOneWidget);
      await tester.tap(find.byIcon(Icons.close).last);
      await tester.pumpAndSettle();
      expect(auth.calls, hasLength(2));
      expect((auth.batch!['items'] as List).single['quantity'], 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'unknown unit cost keeps the actual supplier and quote for a draft',
    (tester) async {
      tester.view.physicalSize = const Size(1274, 710);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final auth = InventoryAuth(
        fullSupplierCatalog: true,
        unknownSupplierUnitCost: true,
      );
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
      await tester.tap(find.text('采购申请').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('新增采购申请'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('purchase-product-${'c' * 64}')));
      await tester.pumpAndSettle();
      expect(find.text('Test supplier'), findsOneWidget);
      await tester.tap(find.text('保存草稿'));
      await tester.pumpAndSettle();
      expect(
        (auth.calls.last['items'] as List).single,
        containsPair('supplierRef', 'test-supplier'),
      );
      expect(
        (auth.calls.last['items'] as List).single,
        containsPair('quoteKey', 'd' * 64),
      );
      expect(
        (auth.calls.last['items'] as List).single,
        containsPair('unitCostCents', null),
      );
      await tester.tap(find.byIcon(Icons.close).last);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  for (final back in [false, true]) {
    testWidgets(
      'editing saved draft then ${back ? 'Android back' : 'close'} cancels unsaved changes',
      (tester) async {
        tester.view.physicalSize = const Size(1274, 710);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        const ref = '00000000-0000-4000-8000-000000000021';
        final auth = InventoryAuth()
          ..batch = {
            'batchRef': ref,
            'title': 'Saved draft',
            'status': 'draft',
            'revision': 1,
            'items': [
              {
                'productRef': 'wine',
                'supplierRef': 'test-supplier',
                'quantity': 2,
                'unitCostCents': 3500,
                'quoteKey': 'a' * 64,
                'names': {'zh-CN': '测试酒品'},
                'specifications': {'zh-CN': '500ML'},
                'supplierName': 'Test supplier',
              },
            ],
          };
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
        await tester.tap(find.text('采购申请').first);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('purchase-batch-$ref')));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('cart-plus-purchase-wine-test-supplier')),
        );
        await tester.pumpAndSettle();
        expect(find.text('3'), findsOneWidget);
        if (back) {
          await tester.binding.handlePopRoute();
        } else {
          await tester.tap(find.byIcon(Icons.close).last);
        }
        await tester.pumpAndSettle();
        expect(find.byIcon(Icons.close), findsNothing);
        expect(auth.calls, hasLength(1));
        expect(auth.batch!['revision'], 1);
        expect((auth.batch!['items'] as List).single['quantity'], 2);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
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
      await tester.tap(find.text('采购申请').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('新增采购申请'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('purchase-product-wine')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('cart-plus-purchase-wine-test-supplier')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('cart-minus-purchase-wine-test-supplier')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('cart-plus-purchase-wine-test-supplier')),
      );
      await tester.pumpAndSettle();
      expect(
        auth.calls.length,
        1,
        reason: 'Adding products edits the batch locally',
      );
      expect(find.text('采购单价 ¥ 35.00'), findsOneWidget);
      expect(find.text('小计 ¥ 70.00'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
      expect(find.text('500ML'), findsOneWidget);
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
    'switching supplier uses its quotation and saves only on explicit save',
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
      await tester.tap(find.text('采购申请').first);
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
      expect(find.text('Other supplier'), findsOneWidget);
      expect(
        auth.calls.length,
        1,
        reason: 'Price changes and supplier selection remain local',
      );
      await tester.tap(find.text('保存草稿'));
      await tester.pumpAndSettle();
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
      for (var i = 0; i < 7; i++) {
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
