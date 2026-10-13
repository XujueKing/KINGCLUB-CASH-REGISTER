import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/live/inventory_panel.dart';
import 'package:kingclub_cash_register/src/strings.dart';

import 'inventory_panel_test.dart' show InventoryAuth;

class CandidateAuth extends InventoryAuth {
  CandidateAuth({this.administrator = false})
    : super(
        permissions: [
          'workbench.read',
          'report.read',
          'shift.manage',
          'price.adjust',
        ],
      );
  final bool administrator;
  bool adopted = false;
  int price = 0;
  @override
  Future<Map<String, dynamic>> inventory(Map<String, dynamic> p) async {
    final v = await super.inventory(p);
    if (p['action'] == 'retail_price' && p['candidateKey'] != null) {
      adopted = true;
      price = p['priceCents'] as int;
    }
    final result = <String, dynamic>{
      ...v,
      'listingPermissions': {'direct': administrator, 'submit': true},
      if (adopted)
        'products': [
          ...v['products'] as List,
          {
            'productRef': 'adopted-product',
            'sharedProductKey': '0' * 64,
            'names': {'zh-CN': '备选酒0'},
            'specifications': {'zh-CN': '700ml'},
            'categoryRef': 'wine',
            'onHand': 0,
            'reserved': 0,
            'available': 0,
            'revision': 2,
            'priceCents': price,
            'listed': false,
          },
        ],
      'catalogProducts': [
        for (var i = 0; i < 110; i++)
          if (i != 0 || !adopted)
            {
              'productRef': i.toRadixString(16).padLeft(64, '0'),
              'sharedProductKey': i.toRadixString(16).padLeft(64, '0'),
              'revision': 0,
              'priceCents': null,
              'names': {'zh-CN': '备选酒$i'},
              'specifications': {'zh-CN': '700ml'},
              'categoryRef': 'wine',
              'candidate': true,
              'listed': false,
              'onHand': 0,
              'reserved': 0,
              'available': 0,
            },
      ],
    };
    if (p['action'] == 'context' && p['pageSize'] != null) {
      final all =
          [
            ...result['products'] as List,
            ...result['catalogProducts'] as List,
          ].where((v) {
            final row = v as Map;
            final text =
                '${(row['names'] as Map)['zh-CN']} ${(row['specifications'] as Map)['zh-CN']}';
            return text.contains('${p['search'] ?? ''}') &&
                (p['stockFilter'] == 'listed'
                    ? row['listed'] == true
                    : p['stockFilter'] == 'unlisted'
                    ? row['listed'] != true
                    : true);
          }).toList();
      final selected = all.skip(p['offset'] as int? ?? 0).take(50).toList();
      return {
        ...result,
        'paged': true,
        'offset': p['offset'] ?? 0,
        'pageSize': 50,
        'total': all.length,
        'category': p['category'] ?? '',
        'stockFilter': p['stockFilter'] ?? 'all',
        'search': p['search'] ?? '',
        'products': selected
            .where((v) => (v as Map)['candidate'] != true)
            .toList(),
        'catalogProducts': selected
            .where((v) => (v as Map)['candidate'] == true)
            .toList(),
      };
    }
    return result;
  }
}

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  testWidgets(
    'supplier candidates are paged and searched by the server with shared editing controls',
    (tester) async {
      tester.view.physicalSize = const Size(1274, 710);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final auth = CandidateAuth();
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
      expect(find.text('备选酒0 700ml'), findsOneWidget);
      expect(find.text('备选酒60 700ml'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('inventory-stock-next')));
      await tester.pumpAndSettle();
      expect(auth.calls.where((p) => p['action'] == 'context'), hasLength(2));
      expect(
        auth.calls.where((p) => p['action'] == 'context').last['offset'],
        50,
      );
      await tester.enterText(find.byType(TextField).first, '备选酒100');
      await tester.pumpAndSettle();
      expect(find.text('备选酒100 700ml'), findsOneWidget);
      expect(find.text('缺图'), findsOneWidget);
      await tester.tap(find.text('备选酒100 700ml'));
      await tester.pumpAndSettle();
      expect(find.text('采购'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('inventory-listing-switch')),
        findsOneWidget,
      );
      expect(find.text('修改零售价'), findsOneWidget);
      expect(find.text('修改库存'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('inventory-stock-listed')));
      await tester.pumpAndSettle();
      expect(find.text('备选酒100 700ml'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'unlisted candidate price save adopts only on save and keeps the selected editor',
    (tester) async {
      tester.view.physicalSize = const Size(1274, 710);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final auth = CandidateAuth(administrator: true);
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
      await tester.tap(find.byKey(const ValueKey('inventory-stock-unlisted')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('备选酒0 700ml'));
      await tester.pumpAndSettle();
      expect(find.text('修改库存'), findsOneWidget);
      await tester.tap(find.text('修改零售价'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('retail-price-close')));
      await tester.pumpAndSettle();
      expect(auth.calls.where((v) => v['action'] == 'retail_price'), isEmpty);
      await tester.tap(find.text('修改零售价'));
      await tester.pumpAndSettle();
      for (final digit in ['1', '6', '8']) {
        await tester.tap(find.byKey(ValueKey('retail-key-$digit')));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.text('保存零售价'));
      await tester.pumpAndSettle();
      final saved = auth.calls
          .where((v) => v['action'] == 'retail_price')
          .single;
      expect(saved['candidateKey'], '0' * 64);
      expect(saved['revision'], 0);
      expect(saved['priceCents'], 16800);
      expect(find.text('本店零售价  ¥ 168.00'), findsOneWidget);
      expect(find.text('修改库存'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      auth.dispose();
    },
  );
}
