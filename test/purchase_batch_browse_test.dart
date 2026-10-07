import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/live/purchase_batch_dialog.dart';
import 'package:kingclub_cash_register/src/strings.dart';

void main() {
  for (final language in UiLanguage.values) {
    testWidgets('browse, search and cancel locally in ${language.name}', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1274, 710);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var requests = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              return Scaffold(
                body: TextButton(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) => PurchaseBatchDialog(
                      batch: const {
                        'status': 'draft',
                        'title': 'Purchase',
                        'revision': 0,
                        'items': [],
                      },
                      products: [
                        for (final p in [
                          ('wine', 'Spirits', 3500),
                          ('juice', 'Soft drinks', 500),
                          ('unknown', 'Spirits', 0),
                        ])
                          {
                            'productRef': p.$1,
                            'names': {'zh-CN': p.$1, 'en': p.$1},
                            'specifications': {'zh-CN': '700ml', 'en': '700ml'},
                            'categoryKey': p.$2,
                            'categoryNames': {'zh-CN': p.$2, 'en': p.$2},
                            'quotes': [
                              if (p.$3 > 0)
                                {
                                  'supplierRef': 'supplier',
                                  'unitCostCents': p.$3,
                                },
                            ],
                          },
                      ],
                      suppliers: const [
                        {
                          'supplierRef': 'supplier',
                          'name': 'Supplier',
                          'active': 1,
                        },
                      ],
                      locations: const ['A1-1'],
                      l: (zh, en, tw, th) => switch (language) {
                        UiLanguage.zh => zh,
                        UiLanguage.en => en,
                        UiLanguage.tw => tw,
                        UiLanguage.th => th,
                      },
                      language: language,
                      canWrite: true,
                      command: (_) async {
                        requests++;
                        return {};
                      },
                        number: (_, _, {bool cents = false}) async => null,
                      attach: (_) async => null,
                    ),
                  ),
                  child: const Text('Open'),
                ),
              );
            },
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('purchase-category-rail')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey('purchase-category-Soft drinks')),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('purchase-product-wine')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('purchase-product-juice')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('purchase-line-juice-supplier')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('purchase-category-')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithIcon(TextField, Icons.search),
        'wine',
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('purchase-product-wine')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('purchase-product-juice')),
        findsNothing,
      );
      await tester.enterText(find.widgetWithIcon(TextField, Icons.search), '');
      await tester.tap(
        find.byKey(const ValueKey('purchase-category-_unpriced')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('purchase-product-unknown')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('purchase-product-wine')), findsNothing);
      expect(
        find.byKey(const ValueKey('purchase-line-juice-supplier')),
        findsOneWidget,
      );
      await tester.tap(find.byIcon(Icons.close).last);
      await tester.pumpAndSettle();
      expect(requests, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
