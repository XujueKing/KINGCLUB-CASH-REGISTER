import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/live/live_catalog_panel.dart';
import 'package:kingclub_cash_register/src/strings.dart';
import 'catalog_snapshot_test.dart' as c;

void main() {
  testWidgets('cashier viewport fits four rows and animates between pages', (tester) async {
    tester.view.physicalSize = const Size(849, 728);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final auth = c.ViewAuth()..reply = {...c.catalog(), 'products': List.generate(18,
      (i) => c.product('p${i.toString().padLeft(3, '0')}'))};
    addTearDown(auth.dispose);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: LiveCatalogPanel(
      auth: auth, language: UiLanguage.zh, header: const SizedBox(height:48), onBack: () {}, onSelect: (_) {},
    ))));
    await tester.pumpAndSettle();
    final last = find.byKey(const ValueKey('catalog-product-p015'));
    expect(last, findsOneWidget);
    expect(tester.getRect(last).bottom, lessThanOrEqualTo(728));
    expect(find.byKey(const ValueKey('catalog-product-p016')), findsNothing);
    await tester.drag(find.byKey(const ValueKey('swipe-pages')), const Offset(-160, 0));
    await tester.pump();
    await tester.pump(const Duration(milliseconds:80));
    expect(find.byKey(const ValueKey('catalog-product-p000')), findsOneWidget);
    expect(find.byKey(const ValueKey('catalog-product-p016')), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('catalog-product-p000')), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
