import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/live/item_price_dialog.dart';
import 'package:kingclub_cash_register/src/strings.dart';

void main() {
  testWidgets(
    'waiver requires applying and returns zero rather than cancellation',
    (tester) async {
      int? result = 1234;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await showItemPriceDialog(
                  context,
                  language: UiLanguage.zh,
                  name: 'Test product',
                  quantity: 3,
                  originalCents: 101,
                  currentCents: 101,
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('item-price-waive')));
      await tester.pumpAndSettle();
      expect(result, 1234);
      expect(find.text('¥ 0.00 × 3 = ¥ 0.00'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('item-price-save')));
      await tester.pumpAndSettle();
      expect(result, 0);
    },
  );
  testWidgets('touch discounts and keypad work without a system keyboard', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1366, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showItemPriceDialog(
              context,
              language: UiLanguage.zh,
              name: 'Product',
              quantity: 2,
              originalCents: 10000,
              currentCents: 10000,
            ),
            child: const Text('Open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    await tester.tap(find.byKey(const ValueKey('discount-8.5')));
    await tester.pump();
    expect(find.text('¥ 85.00 × 2 = ¥ 170.00'), findsOneWidget);
    await tester.tap(find.text('改单价'));
    await tester.pumpAndSettle();
    for (final key in ['1', '2', '.', '3', '4']) {
      await tester.tap(find.byKey(ValueKey('price-key-$key')));
      await tester.pump();
    }
    expect(find.text('¥ 12.34 × 2 = ¥ 24.68'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    await tester.tap(find.byKey(const ValueKey('item-price-reset')));
    await tester.pump();
    expect(find.text('¥ 100.00 × 2 = ¥ 200.00'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  test('unit prices use exact cents, including an explicit zero waiver', () {
    expect(parseUnitPrice('0'), 0);
    expect(parseUnitPrice('12.3'), 1230);
    expect(parseUnitPrice('1000000.00'), 100000000);
    for (final value in ['-1', '1.001', '1e2', '1000000.01', '', 'NaN']) {
      expect(parseUnitPrice(value), isNull);
    }
  });
  test('discount rounds the unit price before multiplying quantity', () {
    expect(discountedUnitPrice(101, '8.5'), 86);
    expect(discountedUnitPrice(101, '8.5')! * 3, 258);
    expect(discountedUnitPrice(100, '10'), 100);
    for (final value in ['0', '-1', '10.01', '85', '8.555']) {
      expect(discountedUnitPrice(100, value), isNull);
    }
  });
}
