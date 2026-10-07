import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/live/supplier_catalog_dialog.dart';

void main() {
  testWidgets('shared presentation keeps each supplier quotation and packaging', (tester) async {
    tester.view.physicalSize = const Size(1274, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final price in [12500, 14000]) {
      await tester.pumpWidget(MaterialApp(home: SupplierCatalogDialog(
        name: 'Supplier $price',
        l: (zh, en, tw, th) => zh,
        load: () async => {
          'sharedProducts': {'shared': {'names': {'zh-CN': '共同商品名称'}, 'materialFileId': 'existing-material'}},
          'catalog': {'complete': true, 'items': [
            {'key': 'quote-$price', 'sharedProductKey': 'shared', 'name': '供应商原始名称', 'category': '洋酒', 'specification': '12×700ml', 'quoteCents': price, 'quoteUnit': '瓶'}
          ]},
        },
      )));
      await tester.pumpAndSettle();
      expect(find.text('共同商品名称'), findsOneWidget);
      expect(find.text('供应商原始名称 · 12×700ml'), findsOneWidget);
      expect(find.text('¥${(price / 100).toStringAsFixed(2)} / 瓶'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });
}
