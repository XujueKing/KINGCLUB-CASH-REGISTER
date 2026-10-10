import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/live/inventory_panel.dart';
import 'package:kingclub_cash_register/src/strings.dart';

import 'inventory_panel_test.dart' show InventoryAuth;

class ListingAuth extends InventoryAuth {
  ListingAuth({this.direct = false});
  final bool direct;
  bool listed = true, awaiting = false;
  @override
  Future<Map<String, dynamic>> inventory(Map<String, dynamic> command) async {
    final v = await super.inventory(command);
    if (command['action'] == 'set_listing') {
      if (direct) {
        listed = command['listed'] as bool;
      } else {
        awaiting = true;
      }
    }
    return {
      ...v,
      'listingPermissions': {'submit': true, 'direct': direct},
      'products': [
        for (final p in v['products'] as List)
          {
            ...p as Map,
            'priceCents': 9900,
            'revision': 1,
            'listed': listed,
            if (awaiting)
              'listingRequest': {
                'listed': false,
                'status': 'pending',
                'applicationRef': '00000000-0000-4000-8000-000000000002',
              },
          },
        {
          'productRef': 'unlisted',
          'names': {'zh-CN': '未上架测试商品'},
          'specifications': {'zh-CN': '500ml'},
          'priceCents': 5500,
          'onHand': 0,
          'reserved': 0,
          'available': 0,
          'listed': false,
          'revision': 1,
        },
      ],
      if (command['action'] == 'set_listing')
        'receipt': {'status': direct ? 'confirmed' : 'pending'},
    };
  }
}

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  for (final direct in [false, true]) {
    testWidgets(
      'listed stock filter and ${direct ? 'direct application' : 'pending mobile approval'} keep the effective state correct',
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
        expect(find.text('零售价'), findsWidgets);
        expect(find.text('上架'), findsOneWidget);
        expect(find.text('未上架测试商品 500ml'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('inventory-stock-listed')));
        await tester.pumpAndSettle();
        expect(find.text('未上架测试商品 500ml'), findsNothing);
        await tester.tap(find.textContaining('测试酒品').first);
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('inventory-listing-switch')),
        );
        await tester.pumpAndSettle();
        expect(
          auth.calls.where((c) => c['action'] == 'set_listing'),
          hasLength(1),
        );
        if (direct) {
          expect(find.textContaining('测试酒品'), findsNothing);
        } else {
          expect(find.text('申请下架 · 待审批'), findsOneWidget);
          final tile = tester.widget<SwitchListTile>(
            find.byKey(const ValueKey('inventory-listing-switch')),
          );
          expect(tile.value, true);
          expect(tile.onChanged, isNull);
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        auth.dispose();
      },
    );
  }
}
