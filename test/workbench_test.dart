import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:kingclub_cash_register/main.dart';

Future<void> launch(
  WidgetTester tester, {
  bool preview = true,
  Size size = const Size(1366, 768),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(CashierApp(preview: preview));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  testWidgets('Workbench loads the supplied KINGCLUB brand asset', (
    tester,
  ) async {
    await launch(tester);
    final logo = tester.widget<Image>(
      find.byKey(const ValueKey('kingclub-logo')),
    );
    expect(logo.semanticLabel, 'KINGCLUB');
    expect(logo.width, 64);
    expect(logo.height, 64);
    expect(find.byIcon(Icons.workspace_premium_outlined), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets('Default live mode does not expose any sample table', (
    tester,
  ) async {
    await launch(tester, preview: false);
    expect(find.text('独立员工登录'), findsOneWidget);
    expect(find.text('T01'), findsNothing);
    expect(find.byKey(const ValueKey('staff-login')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('Draft flow supports variants but never permits a payment', (
    tester,
  ) async {
    await launch(tester);
    await tester.tap(find.byKey(const ValueKey('desk-T01')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('open-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('product-p1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('variant-six')));
    await tester.tap(find.text('加入草稿'));
    await tester.pumpAndSettle();
    expect(find.text('六瓶装  ·  ¥118.00'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('checkout')));
    await tester.pumpAndSettle();
    final pay = tester.widget<FilledButton>(
      find.byKey(const ValueKey('real-payment')),
    );
    expect(pay.onPressed, isNull);
    expect(find.textContaining('草稿估算'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('Compact landscape and languages have no layout errors', (
    tester,
  ) async {
    await launch(tester, size: const Size(1024, 600));
    for (final label in ['English', '繁體中文', 'ไทย', '简体中文']) {
      await tester.tap(find.byKey(const ValueKey('language')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: label);
    }
    await tester.tap(find.byKey(const ValueKey('desk-T01')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('open-menu')));
    await tester.tap(find.byKey(const ValueKey('open-menu')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    for (final i in [2, 3, 4, 5]) {
      await tester.tap(find.byKey(ValueKey('nav-$i')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }
  });
  testWidgets('Search and explicit preview exit clear visible samples', (
    tester,
  ) async {
    await launch(tester);
    await tester.enterText(find.byKey(const ValueKey('table-search')), 'XYZ');
    await tester.pumpAndSettle();
    expect(find.text('没有匹配内容'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('nav-5')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('检查连接'));
    await tester.pumpAndSettle();
    expect(find.text('演示不访问网络，请先退出演示'), findsOneWidget);
    await tester.ensureVisible(find.text('退出演示'));
    await tester.tap(find.text('退出演示'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();
    expect(find.text('T01'), findsNothing);
    expect(find.text('独立员工登录'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
