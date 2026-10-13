import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/live/purchase_batch_dialog.dart';
import 'package:kingclub_cash_register/src/strings.dart';

void main() {
  testWidgets(
    'pages on demand, preserves selected lines and discards stale searches',
    (tester) async {
      tester.view.physicalSize = const Size(1274, 710);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final queries = <Map<String, dynamic>>[];
      final delayed = <String, Completer<Map<String, dynamic>>>{};
      Map<String, dynamic> product(String id) => {
        'productRef': id,
        'names': {'en': id},
        'specifications': {'en': '700ml'},
        'categoryKey': 'Spirits',
        'quotes': [
          {'supplierRef': 'supplier', 'unitCostCents': 3500},
        ],
      };
      Map<String, dynamic> page(
        List<String> ids, {
        int total = 1,
        bool more = false,
      }) => {
        'products': ids.map(product).toList(),
        'total': total,
        'hasMore': more,
        'categories': [
          {
            'categoryKey': 'Spirits',
            'names': {'en': 'Spirits'},
          },
        ],
        'orderedRefs': ids,
      };
      var writes = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PurchaseBatchDialog(
              batch: const {
                'status': 'draft',
                'title': 'Purchase',
                'revision': 0,
                'items': [],
              },
              products: const [],
              suppliers: const [
                {'supplierRef': 'supplier', 'name': 'Supplier', 'active': 1},
              ],
              locations: const ['A1-1'],
              l: (zh, en, tw, th) => en,
              language: UiLanguage.en,
              canWrite: true,
              command: (_) async {
                writes++;
                return {};
              },
              number: (_, _, {bool cents = false}) async => null,
              attach: (_) async => null,
              loadProducts: (q) async {
                queries.add(q);
                if (q['search'] == 'old' || q['search'] == 'new')
                  return (delayed[q['search'] as String] =
                          Completer<Map<String, dynamic>>())
                      .future;
                return q['offset'] == 50
                    ? page(['last'], total: 51)
                    : page(
                        List.generate(50, (i) => 'wine$i'),
                        total: 51,
                        more: true,
                      );
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(queries, hasLength(1));
      expect(queries.single['pageSize'], 50);
      expect(find.text('1-50 / 51'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('purchase-product-wine0')));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.chevron_right));
      await tester.pumpAndSettle();
      expect(queries.last['offset'], 50);
      expect(find.text('51-51 / 51'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('purchase-product-last')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('purchase-line-wine0-supplier')),
        findsOneWidget,
      );
      await tester.enterText(
        find.widgetWithIcon(TextField, Icons.search),
        'old',
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.enterText(
        find.widgetWithIcon(TextField, Icons.search),
        'new',
      );
      await tester.pump(const Duration(milliseconds: 300));
      delayed['new']!.complete(page(['new-match']));
      await tester.pumpAndSettle();
      delayed['old']!.complete(page(['old-match']));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('purchase-product-new-match')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('purchase-product-old-match')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('purchase-line-wine0-supplier')),
        findsOneWidget,
      );
      expect(queries.last['offset'], 0);
      expect(writes, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
