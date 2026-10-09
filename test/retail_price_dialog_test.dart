import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/live/retail_price_dialog.dart';
import 'package:kingclub_cash_register/src/strings.dart';

void main() {
  final product = <String, dynamic>{
    'productRef': 'test-wine',
    'revision': 2,
    'priceCents': 35800,
    'names': {'zh-CN': '测试酒', 'en': 'Test wine'},
    'specifications': {'zh-CN': '700ml'},
    'quotes': [
      {
        'supplierName': '测试供应商',
        'specification': '12×700ml',
        'quoteCents': 120000,
        'quoteUnit': '箱',
        'unitCostCents': 10000,
        'suggestedRetailCents': 39800,
      },
    ],
  };
  Future<void> show(
    WidgetTester tester,
    Future<bool> Function(int) save,
  ) async {
    tester.view.physicalSize = const Size(1024, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => RetailPriceDialog(
                  product: product,
                  language: UiLanguage.zh,
                  save: save,
                ),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
  }

  testWidgets('quotes remain visible while touch editing exact decimal cents', (
    tester,
  ) async {
    int? saved;
    await show(tester, (v) async {
      saved = v;
      return true;
    });
    expect(find.text('测试供应商'), findsOneWidget);
    expect(find.textContaining('¥ 100.00'), findsOneWidget);
    for (final key in ['2', '0', '.', '5']) {
      await tester.tap(find.byKey(ValueKey('retail-key-$key')));
      await tester.pump();
    }
    expect(saved, isNull);
    expect(find.text('¥ 20.5'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('retail-price-save')));
    await tester.pumpAndSettle();
    expect(saved, 2050);
    expect(find.byType(RetailPriceDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'using recommended price still requires saving; closing cancels',
    (tester) async {
      int saves = 0;
      await show(tester, (v) async {
        saves++;
        return true;
      });
      await tester.tap(find.text('采用'));
      await tester.pump();
      expect(find.text('¥ 398.00'), findsOneWidget);
      expect(saves, 0);
      await tester.tap(find.byKey(const ValueKey('retail-price-close')));
      await tester.pumpAndSettle();
      expect(saves, 0);
    },
  );
}
