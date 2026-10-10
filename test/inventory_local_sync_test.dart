import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/auth/staff_session.dart';
import 'package:kingclub_cash_register/src/live/inventory_page_cache.dart';
import 'package:kingclub_cash_register/src/live/inventory_panel.dart';
import 'package:kingclub_cash_register/src/live/retail_price_dialog.dart';
import 'package:kingclub_cash_register/src/network/ccsop_client.dart';
import 'package:kingclub_cash_register/src/strings.dart';

import 'inventory_panel_test.dart' show InventoryAuth;
import 'live_tables_panel_test.dart' show TableAuth;

class SyncAuth extends InventoryAuth {
  final identity = TableAuth(
    permissions: [
      'workbench.read',
      'report.read',
      'shift.manage',
      'price.adjust',
    ],
  ).session;
  @override
  StaffSession get session => identity;
  final syncCalls = <Map<String, dynamic>>[];
  Completer<void>? gate;
  bool rejectPriceOnce = false;
  static const version =
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  @override
  Future<Map<String, dynamic>> inventory(Map<String, dynamic> command) async {
    syncCalls.add(command);
    if (command['action'] == 'retail_price' && rejectPriceOnce) {
      rejectPriceOnce = false;
      throw const CcsopFailure(
        'PARAM_SCHEMA_VALIDATION_FAILED',
        deliveryUncertain: true,
      );
    }
    if (gate != null) await gate!.future;
    final v = await super.inventory(command);
    if (command['action'] == 'resolve_pending')
      return {
        ...v,
        'view': 'stock',
        'version': version,
        'pendingStatus': {
          'requestId': command['requestId'],
          'state': 'cancelled',
        },
      };
    if (command['knownVersion'] == version)
      return {
        'storeRef': 'test-store',
        'view': 'stock',
        'version': version,
        'notModified': true,
      };
    return {
      ...v,
      'view': command['view'] ?? 'stock',
      'version': version,
      'products': (v['products'] as List)
          .map((p) => {...p as Map, 'priceCents': 100, 'revision': 1})
          .toList(),
      if (command['view'] == 'full') 'procurementProducts': v['products'],
      if (command['pendingRequestId'] != null)
        'pendingStatus': {
          'requestId': command['pendingRequestId'],
          'state': 'not_observed',
        },
    };
  }

  String get scope {
    final permissions = identity.permissions.toList()..sort();
    return '${identity.base}|${identity.storeRef}|${identity.employeeRef}|${permissions.join(',')}';
  }
}

Widget page(SyncAuth auth) => MaterialApp(
  home: Scaffold(
    body: InventoryPanel(
      auth: auth,
      language: UiLanguage.zh,
      enableRealtime: false,
    ),
  ),
);
void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  testWidgets(
    'a rejected price can be saved again in the same touch dialog without a false pending lock',
    (tester) async {
      tester.view.physicalSize = const Size(1274, 710);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final auth = SyncAuth()..rejectPriceOnce = true;
      await tester.pumpWidget(page(auth));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('测试酒品').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('修改零售价'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('retail-key-8')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('retail-price-save')));
      await tester.pumpAndSettle();
      expect(find.byType(RetailPriceDialog), findsOneWidget);
      expect(find.text('上次操作未完成'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('retail-price-save')));
      await tester.pumpAndSettle();
      expect(find.byType(RetailPriceDialog), findsNothing);
      final writes = auth.syncCalls
          .where((c) => c['action'] == 'retail_price')
          .toList();
      expect(writes, hasLength(2));
      expect(writes.last['priceCents'], 800);
      expect(writes.first['requestId'], isNot(writes.last['requestId']));
      await tester.pumpWidget(const SizedBox());
      auth.dispose();
    },
  );
  testWidgets(
    'cold controller displays encrypted stock snapshot before version-only refresh finishes',
    (tester) async {
      tester.view.physicalSize = const Size(1274, 710);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final first = SyncAuth();
      await tester.pumpWidget(page(first));
      await tester.pumpAndSettle();
      expect(first.syncCalls.single['view'], 'stock');
      expect(
        (await const InventoryPageCache().read(first.scope))?['version'],
        SyncAuth.version,
      );
      await tester.pumpWidget(const SizedBox());
      first.dispose();
      final second = SyncAuth()..gate = Completer<void>();
      await tester.pumpWidget(page(second));
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.textContaining('测试酒品'), findsWidgets);
      expect(second.syncCalls.single['knownVersion'], SyncAuth.version);
      second.gate!.complete();
      await tester.pumpAndSettle();
      expect(find.textContaining('测试酒品'), findsWidgets);
      await tester.pumpWidget(const SizedBox());
      second.dispose();
    },
  );
  testWidgets(
    'unresolved price can be edited after reconciliation without resending original mutation',
    (tester) async {
      tester.view.physicalSize = const Size(1274, 710);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final auth = SyncAuth();
      final identity =
          '${auth.session.base}|${auth.session.storeRef}|${auth.session.employeeRef}';
      const id = '00000000-0000-4000-8000-000000000041';
      FlutterSecureStorage.setMockInitialValues({
        'inventory-draft:$identity': jsonEncode({
          'items': [],
          'pending': {
            'action': 'retail_price',
            'requestId': id,
            'productRef': 'wine',
            'revision': 1,
            'priceCents': 9900,
          },
        }),
      });
      await tester.pumpWidget(page(auth));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('测试酒品').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('修改零售价'));
      await tester.pumpAndSettle();
      expect(find.byType(RetailPriceDialog), findsOneWidget);
      expect(
        auth.syncCalls.where((c) => c['action'] == 'retail_price'),
        isEmpty,
      );
      expect(
        auth.syncCalls.singleWhere((c) => c['action'] == 'resolve_pending'),
        containsPair('requestId', id),
      );
      expect(find.text('上次操作未完成'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('retail-price-close')));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      auth.dispose();
    },
  );
}
