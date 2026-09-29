import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/hardware/printer_discovery_dialog.dart';
import 'package:kingclub_cash_register/src/strings.dart';

import 'printer_discovery_test.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const discovery = MethodChannel('cn.kingclub.cashier/printer-discovery');
  const status = MethodChannel('cn.kingclub.cashier/printer-status');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final read = find.byKey(const ValueKey('printer-status-inspect'));
  final report = find.byKey(const ValueKey('printer-status-report'));
  setUp(() {
    WidgetController.hitTestWarningShouldBeFatal = true;
    messenger.setMockMethodCallHandler(discovery, (_) async => p.observation());
  });
  tearDown(() {
    WidgetController.hitTestWarningShouldBeFatal = false;
    messenger.setMockMethodCallHandler(discovery, null);
    messenger.setMockMethodCallHandler(status, null);
  });

  Future<void> show(
    WidgetTester tester, [
    UiLanguage language = UiLanguage.zh,
  ]) async {
    tester.view.physicalSize = const Size(1024, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (ctx) => Scaffold(
            body: TextButton(
              onPressed: () => showDialog<void>(
                context: ctx,
                builder: (_) => PrinterDiscoveryDialog(language: language),
              ),
              child: const Text('OPEN'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('OPEN'));
    await tester.pumpAndSettle();
  }

  for (final language in UiLanguage.values) {
    testWidgets('explicit status read, no auto bind; layout ${language.name}', (
      tester,
    ) async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(status, (call) async {
        calls.add(call);
        return {'statusCode': 4, 'paperCode': 999};
      });
      await show(tester, language);
      expect(calls, isEmpty);
      await tester.tap(read);
      await tester.pumpAndSettle();
      expect(calls.single.method, 'inspect');
      expect(calls.single.arguments, null);
      await tester.ensureVisible(report);
      expect(
        tester.widget<Text>(report).data,
        contains(tr(language, 'printerStateNoPaper')),
      );
      expect(find.textContaining('999'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const ValueKey('printer-inspect-close')));
      await tester.pumpAndSettle();
      expect(find.byType(PrinterDiscoveryDialog), findsNothing);
    });
  }

  testWidgets('non-resolvable discovery cannot initiate binding', (
    tester,
  ) async {
    messenger.setMockMethodCallHandler(
      discovery,
      (_) async => {...p.observation(), 'serviceResolvable': false},
    );
    var calls = 0;
    messenger.setMockMethodCallHandler(status, (_) async {
      calls++;
      return null;
    });
    await show(tester);
    expect(tester.widget<OutlinedButton>(read).onPressed, null);
    expect(calls, 0);
  });

  testWidgets(
    'failed retry clears old status, sanitizes errors; null is unknown',
    (tester) async {
      messenger.setMockMethodCallHandler(
        status,
        (_) async => {'statusCode': 1, 'paperCode': 1},
      );
      await show(tester);
      await tester.tap(read);
      await tester.pumpAndSettle();
      expect(report, findsOneWidget);
      messenger.setMockMethodCallHandler(
        status,
        (_) async =>
            throw PlatformException(code: 'PRIVATE', message: 'TEST_PRIVATE'),
      );
      await tester.tap(read);
      await tester.pumpAndSettle();
      expect(report, findsNothing);
      expect(
        find.byKey(const ValueKey('printer-status-failed')),
        findsOneWidget,
      );
      expect(find.textContaining('TEST_PRIVATE'), findsNothing);
      messenger.setMockMethodCallHandler(
        status,
        (_) async => {'statusCode': null, 'paperCode': null},
      );
      await tester.tap(read);
      await tester.pumpAndSettle();
      expect(
        tester.widget<Text>(report).data,
        contains(tr(UiLanguage.zh, 'printerUnknown')),
      );
    },
  );

  testWidgets(
    'background discards late status; resume requires discovery refresh',
    (tester) async {
      final gate = Completer<Object?>();
      var calls = 0;
      messenger.setMockMethodCallHandler(status, (_) {
        calls++;
        return gate.future;
      });
      await show(tester);
      await tester.tap(read);
      await tester.pump();
      expect(tester.widget<OutlinedButton>(read).onPressed, null);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      gate.complete({'statusCode': 1, 'paperCode': 0});
      await tester.pumpAndSettle();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(report, findsNothing);
      expect(calls, 1);
      expect(tester.widget<OutlinedButton>(read).onPressed, null);
      await tester.tap(find.byKey(const ValueKey('printer-inspect-refresh')));
      await tester.pumpAndSettle();
      expect(tester.widget<OutlinedButton>(read).onPressed, isNotNull);
      expect(calls, 1);
    },
  );

  testWidgets('status timeout and late reply never show stale normal', (
    tester,
  ) async {
    final gate = Completer<Object?>();
    messenger.setMockMethodCallHandler(status, (_) => gate.future);
    await show(tester);
    await tester.tap(read);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('printer-status-failed')), findsOneWidget);
    gate.complete({'statusCode': 1, 'paperCode': 0});
    await tester.pumpAndSettle();
    expect(report, findsNothing);
  });

  testWidgets('close remains enabled while status is pending', (tester) async {
    final gate = Completer<Object?>();
    messenger.setMockMethodCallHandler(status, (_) => gate.future);
    await show(tester);
    await tester.tap(read);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('printer-inspect-close')));
    await tester.pump(const Duration(milliseconds: 300));
    gate.complete({'statusCode': 1, 'paperCode': 0});
    await tester.pumpAndSettle();
    expect(find.byType(PrinterDiscoveryDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
