import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/hardware/printer_discovery_dialog.dart';
import 'package:kingclub_cash_register/src/strings.dart';

import 'printer_discovery_test.dart' as p;
import 'usb_printer_descriptor_test.dart' as u;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const discovery = MethodChannel('cn.kingclub.cashier/printer-discovery');
  const permission = MethodChannel(
    'cn.kingclub.cashier/usb-printer-permission',
  );
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final select = find.byKey(const ValueKey('usb-permission-100-0-0-1'));
  final confirm = find.byKey(const ValueKey('usb-permission-confirm'));
  var granted = false;
  setUp(() {
    WidgetController.hitTestWarningShouldBeFatal = true;
    granted = false;
    messenger.setMockMethodCallHandler(
      discovery,
      (_) async => {
        ...p.observation(),
        'usbPrinterCandidates': 1,
        'usbPrinters': [
          {...u.descriptor(), 'hasPermission': granted},
        ],
      },
    );
  });
  tearDown(() {
    WidgetController.hitTestWarningShouldBeFatal = false;
    messenger.setMockMethodCallHandler(discovery, null);
    messenger.setMockMethodCallHandler(permission, null);
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
    await tester.ensureVisible(select);
    await tester.pumpAndSettle();
  }

  for (final language in UiLanguage.values) {
    testWidgets('explicit OS permission and reinspection ${language.name}', (
      tester,
    ) async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(permission, (call) async {
        calls.add(call);
        granted = true;
        return {
          'requestId': (call.arguments as Map)['requestId'],
          'granted': true,
        };
      });
      await show(tester, language);
      expect(calls, isEmpty);
      await tester.tap(select);
      await tester.pumpAndSettle();
      expect(calls, isEmpty);
      expect(find.textContaining('USB 1234:5678'), findsWidgets);
      await tester.tap(confirm);
      await tester.pumpAndSettle();
      expect(calls.single.method, 'request');
      expect(
        find.text(tr(language, 'printerUsbAuthorizeRefresh')),
        findsOneWidget,
      );
      expect(find.text('USB 1234:5678'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('printer-inspect-refresh')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(select);
      expect(tester.widget<TextButton>(select).onPressed, null);
      expect(calls.length, 1);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('cancel confirmation never calls native permission', (
    tester,
  ) async {
    var calls = 0;
    messenger.setMockMethodCallHandler(permission, (_) async {
      calls++;
      return null;
    });
    await show(tester);
    await tester.tap(select);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('usb-permission-cancel')));
    await tester.pumpAndSettle();
    expect(calls, 0);
    expect(find.text('USB 1234:5678'), findsOneWidget);
  });

  testWidgets('stale confirmation after background cannot request access', (
    tester,
  ) async {
    var calls = 0;
    messenger.setMockMethodCallHandler(permission, (_) async {
      calls++;
      return null;
    });
    await show(tester);
    await tester.tap(select);
    await tester.pumpAndSettle();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.tap(confirm);
    await tester.pumpAndSettle();
    expect(calls, 0);
    expect(find.text('USB 1234:5678'), findsNothing);
  });

  testWidgets(
    'system prompt lifecycle never creates a fresh granted snapshot',
    (tester) async {
      final pending = Completer<Object?>();
      String? id;
      messenger.setMockMethodCallHandler(permission, (call) {
        id = (call.arguments as Map)['requestId'] as String;
        return pending.future;
      });
      await show(tester);
      await tester.tap(select);
      await tester.pumpAndSettle();
      await tester.tap(confirm);
      await tester.pumpAndSettle();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      pending.complete({'requestId': id, 'granted': true});
      await tester.pumpAndSettle();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.text('USB 1234:5678'), findsNothing);
      expect(
        find.text(tr(UiLanguage.zh, 'printerUsbAuthorizeRefresh')),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'close pending request cancels observation, never claims revocation',
    (tester) async {
      final pending = Completer<Object?>();
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(permission, (call) {
        calls.add(call);
        return call.method == 'request' ? pending.future : Future.value(null);
      });
      await show(tester);
      await tester.tap(select);
      await tester.pumpAndSettle();
      await tester.tap(confirm);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('printer-inspect-close')));
      await tester.pumpAndSettle();
      expect(calls.map((c) => c.method), ['request', 'cancel']);
      pending.complete({
        'requestId': (calls.first.arguments as Map)['requestId'],
        'granted': true,
      });
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}
