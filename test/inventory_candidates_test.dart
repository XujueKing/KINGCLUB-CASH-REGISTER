import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/live/inventory_panel.dart';
import 'package:kingclub_cash_register/src/strings.dart';

import 'inventory_panel_test.dart' show InventoryAuth;

class CandidateAuth extends InventoryAuth {
  @override
  Future<Map<String, dynamic>> inventory(Map<String, dynamic> p) async {
    final v = await super.inventory(p);
    return {
      ...v,
      'catalogProducts': [
        for (var i = 0; i < 110; i++)
          {
            'productRef': 'candidate-$i',
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
  }
}

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  testWidgets(
    'supplier candidates are paged and searched locally; absent images and sale controls are clear',
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
      expect(auth.calls.where((p) => p['action'] == 'context'), hasLength(1));
      await tester.enterText(find.byType(TextField).first, '备选酒100');
      await tester.pumpAndSettle();
      expect(find.text('备选酒100 700ml'), findsOneWidget);
      expect(find.text('缺图'), findsOneWidget);
      await tester.tap(find.text('备选酒100 700ml'));
      await tester.pumpAndSettle();
      expect(find.text('采购'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('inventory-listing-switch')),
        findsNothing,
      );
      expect(find.text('修改零售价'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('inventory-stock-listed')));
      await tester.pumpAndSettle();
      expect(find.text('备选酒100 700ml'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
