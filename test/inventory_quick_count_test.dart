import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/live/inventory_panel.dart';
import 'package:kingclub_cash_register/src/strings.dart';

import 'inventory_listing_test.dart' show ListingAuth;

class CountCostAuth extends ListingAuth {
  CountCostAuth() : super(direct: true);
  @override
  Future<Map<String, dynamic>> inventory(Map<String, dynamic> command) async {
    final value = await super.inventory(command);
    return {
      ...value,
      'products': [
        for (final p in value['products'] as List)
          {...p as Map, 'countCostCents': 3500},
      ],
    };
  }
}

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  testWidgets(
    'only count gains show the server supplier reference and save it as new batch valuation',
    (tester) async {
      tester.view.physicalSize = const Size(1274, 710);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final auth = CountCostAuth();
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
      await tester.tap(find.textContaining('测试酒品').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('修改库存'));
      await tester.pumpAndSettle();
      expect(find.text('盘盈成本'), findsNothing);
      expect(find.text('成本未知'), findsNothing);
      await tester.tap(find.text('实盘数量'));
      await tester.pumpAndSettle();
      for (final key in ['1', '4']) {
        await tester.tap(find.text(key).last);
        await tester.pumpAndSettle();
      }
      await tester.tap(find.text('确定').last);
      await tester.pumpAndSettle();
      expect(find.text('¥ 35.00'), findsOneWidget);
      await tester.tap(find.text('保存盘点'));
      await tester.pumpAndSettle();
      final saved = auth.calls.where((v) => v['action'] == 'count').single;
      expect((saved['items'] as List).single, containsPair('quantity', 14));
      expect(
        (saved['items'] as List).single,
        containsPair('unitCostCents', 3500),
      );
      await tester.pumpWidget(const SizedBox());
      auth.dispose();
    },
  );
  for (final direct in [false, true]) {
    testWidgets(
      'quick count requires administrator and saves a count, never on close ($direct)',
      (tester) async {
        tester.view.physicalSize = const Size(1274, 710);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final auth = ListingAuth(direct: direct);
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
        await tester.tap(find.textContaining('测试酒品').first);
        await tester.pumpAndSettle();
        expect(find.text('修改库存'), direct ? findsOneWidget : findsNothing);
        if (direct) {
          await tester.tap(find.text('盘点').first);
          await tester.pumpAndSettle();
          await tester.tap(find.textContaining('测试酒品').first);
          await tester.pumpAndSettle();
          await tester.tap(find.text('确定').last);
          await tester.pumpAndSettle();
          expect(find.text('实盘 10'), findsOneWidget);
          await tester.tap(find.text('库存').first);
          await tester.pumpAndSettle();
          await tester.tap(find.text('修改库存'));
          await tester.pumpAndSettle();
          await tester.tap(find.byIcon(Icons.close).last);
          await tester.pumpAndSettle();
          expect(auth.calls.where((v) => v['action'] == 'count'), isEmpty);
          await tester.tap(find.text('修改库存'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('实盘数量'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('1').last);
          await tester.pumpAndSettle();
          await tester.tap(find.text('确定').last);
          await tester.pumpAndSettle();
          await tester.tap(find.text('保存盘点'));
          await tester.pumpAndSettle();
          expect(auth.calls.where((v) => v['action'] == 'count'), isEmpty);
          await tester.tap(find.text('实盘数量'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('8').last);
          await tester.pumpAndSettle();
          await tester.tap(find.text('确定').last);
          await tester.pumpAndSettle();
          await tester.tap(find.text('保存盘点'));
          await tester.pumpAndSettle();
          final count = auth.calls.where((v) => v['action'] == 'count').single;
          expect(count['quickCount'], true);
          expect((count['items'] as List).single, containsPair('quantity', 8));
          expect(
            (count['items'] as List).single,
            containsPair('expectedOnHand', 10),
          );
          expect(
            (count['items'] as List).single,
            containsPair('expectedReserved', 2),
          );
          expect(
            (count['items'] as List).single,
            containsPair('location', 'A1-1'),
          );
          expect(find.text('保存盘点'), findsNothing);
          await tester.tap(find.text('盘点').first);
          await tester.pumpAndSettle();
          expect(find.text('实盘 10'), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        auth.dispose();
      },
    );
  }
}
