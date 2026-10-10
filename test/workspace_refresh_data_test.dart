import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:kingclub_cash_register/src/auth/staff_session.dart';
import 'package:kingclub_cash_register/src/live/inventory_panel.dart';
import 'package:kingclub_cash_register/src/live/live_catalog_panel.dart';
import 'package:kingclub_cash_register/src/strings.dart';

import 'catalog_snapshot_test.dart' as catalog;
import 'inventory_panel_test.dart' as inventory;
import 'live_tables_panel_test.dart' show TableAuth;
import 'staff_session_test.dart' as staff;

class RenewalCatalogAuth extends catalog.ViewAuth {
  StaffSession? value = TableAuth().session;
  bool renewing = false;
  @override
  StaffSession? get session => value;
  @override
  bool get busy => renewing;
  void begin() {
    renewing = true;
    notifyListeners();
  }

  void finish() {
    value = TableAuth().session;
    renewing = false;
    notifyListeners();
  }

  void revoke() {
    value = null;
    notifyListeners();
  }
}

class DelayedInventoryAuth extends inventory.InventoryAuth {
  Completer<void>? delay;
  @override
  Future<Map<String, dynamic>> inventory(Map<String, dynamic> command) async {
    if (delay != null) await delay!.future;
    return super.inventory(command);
  }
}

void main() {
  test('renewal retains display identity and avatar; failure removes authentication', () async {
    final storage = staff.TestStorage(),
        channel = staff.TestAuth(),
        api = staff.TestApi();
    final auth = staff.controller(storage, channel, api);
    await staff.login(auth);
    api.pendingRead = Completer<Object?>()
      ..complete({
        'result': {
          'operator': {
            'avatarBase64': base64Encode([1, 2, 3]),
          },
        },
      });
    await auth.readWorkbench();
    final previous = auth.session, display = auth.workspaceIdentity;
    channel.gate = Completer<void>();
    final renewal = auth.restore();
    await Future<void>.delayed(Duration.zero);
    expect(auth.busy, true);
    expect(auth.session, same(previous));
    expect(auth.workspaceIdentity, same(display));
    expect(auth.operatorAvatar.value, [1, 2, 3]);
    channel.gate!.complete();
    await renewal;
    expect(auth.session, isNot(same(previous)));
    expect(auth.workspaceIdentity, same(display));
    expect(auth.operatorAvatar.value, [1, 2, 3]);
    channel.gate = null;
    channel.fail = true;
    await expectLater(auth.restore(), throwsException);
    expect(auth.session, isNull);
    expect(auth.workspaceIdentity, isNull);
    expect(auth.operatorAvatar.value, isNull);
    auth.dispose();
  });
  testWidgets(
    'renewal and backgrounding preserve product cards; revocation clears them',
    (tester) async {
      final auth = RenewalCatalogAuth();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LiveCatalogPanel(
              auth: auth,
              language: UiLanguage.zh,
              onBack: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final product = find.byKey(const ValueKey('catalog-product-p001'));
      expect(product, findsOneWidget);
      auth.begin();
      await tester.pump();
      expect(product, findsOneWidget);
      auth.gate = Completer();
      auth.finish();
      await tester.pump();
      expect(product, findsOneWidget);
      auth.gate!.complete(catalog.parse(catalog.catalog()));
      await tester.pumpAndSettle();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(product, findsOneWidget);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(product, findsOneWidget);
      auth.revoke();
      await tester.pump();
      expect(product, findsNothing);
      await tester.pumpWidget(const SizedBox());
      auth.dispose();
    },
  );
  testWidgets(
    'returning to inventory shows previous stock while read is pending',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      tester.view.physicalSize = const Size(1274, 710);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final auth = DelayedInventoryAuth();
      Widget page() => MaterialApp(
        home: Scaffold(
          body: InventoryPanel(
            auth: auth,
            language: UiLanguage.zh,
            enableRealtime: false,
          ),
        ),
      );
      await tester.pumpWidget(page());
      await tester.pumpAndSettle();
      expect(find.textContaining('测试酒品'), findsWidgets);
      await tester.pumpWidget(const SizedBox());
      auth.delay = Completer();
      await tester.pumpWidget(page());
      await tester.pump();
      expect(find.textContaining('测试酒品'), findsWidgets);
      auth.delay!.complete();
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      auth.dispose();
    },
  );
}
