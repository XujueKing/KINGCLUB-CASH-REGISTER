import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/live/catalog_snapshot.dart';
import 'package:kingclub_cash_register/src/live/live_catalog_panel.dart';
import 'package:kingclub_cash_register/src/strings.dart';

import 'catalog_snapshot_test.dart' as c;

Map<String, dynamic> variant(
  String ref,
  int price,
  int stock, {
  String? group,
}) => {
  ...c.product(ref),
  if (group != null) 'productGroupRef': group,
  'specifications': c.words('$price ML'),
  'priceCents': price,
  'inventoryKnown': true,
  'available': stock,
  'soldOut': stock == 0,
};

class PagesAuth extends c.ViewAuth {
  final cursors = <String?>[];
  @override
  Future<CatalogSnapshot> readCatalog({
    String? categoryRef,
    String? afterProduct,
  }) async {
    cursors.add(afterProduct);
    return c.parse({
      ...c.catalog(),
      'products': afterProduct == null
          ? List.generate(
              50,
              (i) => variant(
                'p${i.toString().padLeft(3, '0')}',
                100,
                3,
                group: 'wine',
              ),
            )
          : [variant('p050', 200, 2, group: 'wine')],
      'nextAfterProduct': afterProduct == null ? 'p049' : null,
    }, afterProduct: afterProduct);
  }
}

void main() {
  testWidgets(
    'grouped card selects exact SKU and disables unavailable variants',
    (tester) async {
      final auth = c.ViewAuth()
        ..reply = {
          ...c.catalog(),
          'products': [
            variant('p001', 100, 3, group: 'wine'),
            variant('p002', 200, 0, group: 'wine'),
            variant('p003', 300, 2, group: 'wine'),
            variant('p004', 100, 3),
          ],
        };
      addTearDown(auth.dispose);
      final selected = <CatalogProduct>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LiveCatalogPanel(
              auth: auth,
              language: UiLanguage.zh,
              onBack: () {},
              onSelect: selected.add,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('catalog-product-p002')), findsNothing);
      expect(
        find.byKey(const ValueKey('catalog-product-p004')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('catalog-select-p001')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<OutlinedButton>(
              find.byKey(const ValueKey('catalog-variant-p002')),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(find.byKey(const ValueKey('catalog-variant-p003')));
      await tester.pumpAndSettle();
      expect(selected.single.reference, 'p003');
      expect(selected.single.priceCents, 300);
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('loads remaining SKU pages before grouping', (tester) async {
    final auth = PagesAuth();
    addTearDown(auth.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LiveCatalogPanel(
            auth: auth,
            language: UiLanguage.en,
            onBack: () {},
            onSelect: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(auth.cursors, [null, 'p049']);
    expect(find.byKey(const ValueKey('catalog-product-p000')), findsOneWidget);
    expect(find.byKey(const ValueKey('catalog-product-p050')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('catalog-select-p000')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('catalog-variant-p050')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
