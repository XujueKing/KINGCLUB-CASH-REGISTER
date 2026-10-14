import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/strings.dart';
import 'package:kingclub_cash_register/src/updates/app_updates.dart';
import 'package:kingclub_cash_register/src/updates/update_button.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/app-update');
  const endpoint = 'https://example.test/kingclub-updates/cashier/stable.json';
  late AppUpdates updates;
  late List<String> calls;
  setUp(() {
    calls = [];
    updates = AppUpdates(channel: channel, manifestUrl: endpoint);
  });
  tearDown(() {
    updates.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });
  void respond(Future<Object?> Function(MethodCall) response) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          return response(call);
        });
  }

  test('check downloads but never opens installer automatically', () async {
    respond(
      (_) async => {
        'status': 'ready',
        'versionName': '0.1.3',
        'notes': 'Update',
      },
    );
    await updates.check();
    expect(updates.stage, UpdateStage.ready);
    expect(calls, ['check']);
    await updates.check(force: true);
    expect(calls, ['check']); // manual tapping also respects the retry throttle
  });
  test('only one download is in flight', () async {
    final pending = Completer<Object?>();
    respond((_) => pending.future);
    final first = updates.check();
    await updates.check(force: true);
    expect(calls, ['check']);
    pending.complete({'status': 'current'});
    await first;
    expect(updates.stage, UpdateStage.current);
  });
  test(
    'failed check does not trigger installation or throw into sales',
    () async {
      respond((_) async => throw PlatformException(code: 'UPDATE_FAILED'));
      await updates.check();
      expect(updates.stage, UpdateStage.failed);
      expect(await updates.install(), 'failed');
      expect(calls, ['check']);
    },
  );
  testWidgets(
    'ready package requires operator confirmation before installation',
    (tester) async {
      respond(
        (call) async => call.method == 'install'
            ? {'status': 'permission'}
            : {'status': 'ready', 'versionName': '0.1.3', 'notes': 'Update'},
      );
      await updates.check();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: UpdateButton(language: UiLanguage.zh, updates: updates),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('app-update-open')));
      await tester.pumpAndSettle();
      final button = find.widgetWithText(FilledButton, '安装新版');
      expect(tester.widget<FilledButton>(button).onPressed, isNull);
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pump();
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(calls, ['check', 'install']);
      expect(find.textContaining('请允许 KINGCLUB'), findsOneWidget);
      expect(tester.widget<FilledButton>(button).onPressed, isNull);
    },
  );
  testWidgets('all languages render update states without overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final language in UiLanguage.values) {
      for (final stage in UpdateStage.values) {
        updates.stage = stage;
        await tester.pumpWidget(
          MaterialApp(
            home: UpdateDialog(
              key: ValueKey('$language-$stage'),
              language: language,
              updates: updates,
            ),
          ),
        );
        await tester.pump();
        expect(tester.takeException(), isNull);
      }
    }
  });
}
