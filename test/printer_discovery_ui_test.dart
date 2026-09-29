import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/auth/staff_access_page.dart';
import 'package:kingclub_cash_register/src/hardware/printer_discovery_dialog.dart';
import 'package:kingclub_cash_register/src/strings.dart';

import 'printer_discovery_test.dart' as p;
import 'staff_access_page_test.dart' as a;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('cn.kingclub.cashier/printer-discovery');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  setUp(() => WidgetController.hitTestWarningShouldBeFatal = true);
  tearDown(() {
    WidgetController.hitTestWarningShouldBeFatal = false;
    messenger.setMockMethodCallHandler(channel, null);
  });

  void size(WidgetTester tester) {
    tester.view.physicalSize = const Size(1024, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Future<void> show(
    WidgetTester tester, {
    UiLanguage language = UiLanguage.zh,
  }) async {
    size(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (ctx) => Scaffold(
            body: TextButton(
              onPressed: () => showDialog<void>(
                context: ctx,
                builder: (_) => PrinterDiscoveryDialog(language: language),
              ),
              child: const Text('TEST OPEN'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('TEST OPEN'));
    await tester.pumpAndSettle();
  }

  testWidgets('login entry invokes read-only channel without authentication', (
    tester,
  ) async {
    size(tester);
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return p.observation();
    });
    final auth = a.UiAuth();
    await tester.pumpWidget(
      MaterialApp(home: StaffAccessPage(controller: auth)),
    );
    await tester.pumpAndSettle();
    expect(calls, isEmpty);
    await tester.tap(find.byKey(const ValueKey('printer-inspect-open')));
    await tester.pumpAndSettle();
    expect(calls.single.method, 'inspect');
    expect(calls.single.arguments, null);
    expect(auth.logins, 0);
    expect(find.textContaining('TEST_ONLY_1.0'), findsOneWidget);
    expect(
      find.text(tr(UiLanguage.zh, 'printerReadinessUnknown')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('printer-inspect-close')));
    await tester.pumpAndSettle();
    expect(find.byType(PrinterDiscoveryDialog), findsNothing);
    expect(auth.logins, 0);
    await tester.pumpWidget(const SizedBox());
    auth.dispose();
  });

  testWidgets(
    'failure has no fake absence or private error details and supports manual retry',
    (tester) async {
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => throw PlatformException(
          code: 'PRIVATE',
          message: 'TEST_PRIVATE_ERROR',
        ),
      );
      await show(tester);
      expect(
        find.text(tr(UiLanguage.zh, 'printerInspectFailed')),
        findsOneWidget,
      );
      expect(find.textContaining('TEST_PRIVATE_ERROR'), findsNothing);
      expect(
        find.textContaining(tr(UiLanguage.zh, 'printerServiceInstalled')),
        findsNothing,
      );
      messenger.setMockMethodCallHandler(channel, (_) async => p.observation());
      await tester.tap(find.byKey(const ValueKey('printer-inspect-refresh')));
      await tester.pumpAndSettle();
      expect(find.textContaining('TEST_ONLY_1.0'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('printer-inspect-failed')),
        findsNothing,
      );
    },
  );

  testWidgets(
    'background clears old metadata; resume does not silently reuse it',
    (tester) async {
      var calls = 0;
      messenger.setMockMethodCallHandler(channel, (_) async {
        calls++;
        return p.observation();
      });
      await show(tester);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pumpAndSettle();
      expect(find.textContaining('TEST_ONLY_1.0'), findsNothing);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(calls, 1);
      await tester.tap(find.byKey(const ValueKey('printer-inspect-refresh')));
      await tester.pumpAndSettle();
      expect(calls, 2);
      expect(find.textContaining('TEST_ONLY_1.0'), findsOneWidget);
    },
  );

  testWidgets('closing while check is pending ignores late native reply', (
    tester,
  ) async {
    size(tester);
    final gate = Completer<Object?>();
    messenger.setMockMethodCallHandler(channel, (_) => gate.future);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (ctx) => Scaffold(
            body: TextButton(
              onPressed: () => showDialog<void>(
                context: ctx,
                builder: (_) =>
                    const PrinterDiscoveryDialog(language: UiLanguage.zh),
              ),
              child: const Text('TEST OPEN'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('TEST OPEN'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const ValueKey('printer-inspect-close')));
    await tester.pump(const Duration(milliseconds: 300));
    gate.complete(p.observation());
    await tester.pumpAndSettle();
    expect(find.byType(PrinterDiscoveryDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final language in UiLanguage.values) {
    testWidgets('printer discovery fits compact ${language.name}', (
      tester,
    ) async {
      messenger.setMockMethodCallHandler(channel, (_) async => p.observation());
      await show(tester, language: language);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const ValueKey('printer-inspect-refresh')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const ValueKey('printer-inspect-close')));
      await tester.pumpAndSettle();
      expect(find.byType(PrinterDiscoveryDialog), findsNothing);
    });
  }

  testWidgets(
    'late reply after background is discarded and requires a fresh manual check',
    (tester) async {
      size(tester);
      final gate = Completer<Object?>();
      var calls = 0;
      messenger.setMockMethodCallHandler(channel, (_) {
        calls++;
        return gate.future;
      });
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: PrinterDiscoveryDialog(language: UiLanguage.zh)),
        ),
      );
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      gate.complete(p.observation());
      await tester.pumpAndSettle();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.textContaining('TEST_ONLY_1.0'), findsNothing);
      expect(calls, 1);
      messenger.setMockMethodCallHandler(channel, (_) async {
        calls++;
        return p.observation();
      });
      await tester.tap(find.byKey(const ValueKey('printer-inspect-refresh')));
      await tester.pumpAndSettle();
      expect(calls, 2);
      expect(find.textContaining('TEST_ONLY_1.0'), findsOneWidget);
    },
  );

  testWidgets(
    'unresponsive native channel times out without claiming no printer',
    (tester) async {
      size(tester);
      final gate = Completer<Object?>();
      messenger.setMockMethodCallHandler(channel, (_) => gate.future);
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: PrinterDiscoveryDialog(language: UiLanguage.zh)),
        ),
      );
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(
        find.text(tr(UiLanguage.zh, 'printerInspectFailed')),
        findsOneWidget,
      );
      expect(
        find.textContaining(tr(UiLanguage.zh, 'printerServiceInstalled')),
        findsNothing,
      );
      gate.complete(p.observation());
      await tester.pumpAndSettle();
      expect(find.textContaining('TEST_ONLY_1.0'), findsNothing);
    },
  );
}
