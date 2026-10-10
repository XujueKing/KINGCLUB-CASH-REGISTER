import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/live/supplier_catalog_dialog.dart';

void main() {
  testWidgets(
    'supplier pages use a persisted snapshot and server version rather than a repeated full download',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      tester.view.physicalSize = const Size(1274, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final calls = <List<Object?>>[];
      Completer<void>? gate;
      Future<Map<String, dynamic>> load(
        int offset,
        String category,
        String search,
        String? version,
      ) async {
        calls.add([offset, category, search, version]);
        if (gate != null) await gate!.future;
        if (version == 'v1') return {'version': 'v1', 'notModified': true};
        return {
          'version': 'v1',
          'offset': offset,
          'total': 120,
          'hasMore': offset < 100,
          'categories': [
            {'name': '啤酒', 'count': 120},
          ],
          'catalog': {
            'complete': true,
            'items': [
              {
                'key': 'q-$offset',
                'name': '酒水$offset',
                'category': '啤酒',
                'specification': '6瓶',
                'quoteCents': 1200,
                'quoteUnit': '组',
              },
            ],
          },
        };
      }

      Widget dialog() => MaterialApp(
        home: SupplierCatalogDialog(
          name: 'Supplier',
          l: (a, b, c, d) => a,
          cacheScope: 'supplier-cache-test',
          load: () async => throw StateError('full catalog should not be read'),
          loadPage: load,
        ),
      );
      await tester.pumpWidget(dialog());
      await tester.pumpAndSettle();
      expect(find.text('酒水0'), findsOneWidget);
      await tester.tap(find.text('下一页'));
      await tester.pumpAndSettle();
      expect(calls.last.first, 50);
      expect(find.text('酒水50'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      gate = Completer<void>();
      await tester.pumpWidget(dialog());
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('酒水0'), findsOneWidget);
      expect(calls.last.last, 'v1');
      gate!.complete();
      await tester.pumpAndSettle();
      expect(find.text('酒水0'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'shared presentation keeps each supplier quotation and packaging',
    (tester) async {
      tester.view.physicalSize = const Size(1274, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      for (final price in [12500, 14000]) {
        await tester.pumpWidget(
          MaterialApp(
            home: SupplierCatalogDialog(
              name: 'Supplier $price',
              l: (zh, en, tw, th) => zh,
              load: () async => {
                'sharedProducts': {
                  'shared': {
                    'names': {'zh-CN': '共同商品名称'},
                    'materialFileId': 'existing-material',
                  },
                },
                'catalog': {
                  'complete': true,
                  'items': [
                    {
                      'key': 'quote-$price',
                      'sharedProductKey': 'shared',
                      'name': '供应商原始名称',
                      'category': '洋酒',
                      'specification': '12×700ml',
                      'quoteCents': price,
                      'quoteUnit': '瓶',
                    },
                  ],
                },
              },
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('共同商品名称'), findsOneWidget);
        expect(find.text('供应商原始名称 · 12×700ml'), findsOneWidget);
        expect(
          find.text('¥${(price / 100).toStringAsFixed(2)} / 瓶'),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      }
    },
  );
}
