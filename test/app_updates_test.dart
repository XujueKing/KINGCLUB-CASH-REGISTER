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
  late DateTime now;
  setUp(() {
    calls = [];
    now = DateTime.utc(2026, 10, 14);
    updates = AppUpdates(
      channel: channel,
      manifestUrl: endpoint,
      now: () => now,
    );
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
    'failure retries after fifteen minutes and success waits one hour',
    () async {
      var unavailable = true;
      respond((_) async {
        if (unavailable) throw PlatformException(code: 'UPDATE_FAILED');
        return {'status': 'current'};
      });
      await updates.check();
      now = now.add(const Duration(minutes: 14));
      await updates.check();
      expect(calls.length, 1);
      now = now.add(const Duration(minutes: 1));
      unavailable = false;
      await updates.check();
      expect(updates.stage, UpdateStage.current);
      now = now.add(const Duration(minutes: 59));
      await updates.check();
      expect(calls.length, 2);
      now = now.add(const Duration(minutes: 1));
      await updates.check();
      expect(calls.length, 3);
    },
  );
  test(
    'system installer holds the downloaded file until return to cashier',
    () async {
      respond(
        (call) async => call.method == 'install'
            ? {'status': 'installer'}
            : {'status': 'ready', 'versionName': '0.1.3'},
      );
      await updates.check();
      expect(await updates.install(), 'installer');
      now = now.add(const Duration(hours: 2));
      await updates.check(force: true);
      expect(calls, ['check', 'install']);
      updates.setForeground(false);
      await updates.check(force: true);
      expect(await updates.install(), 'failed');
      expect(calls, ['check', 'install']);
      updates.setForeground(
        true,
      ); // System installer was cancelled or permission screen closed.
      await updates.check();
      expect(calls, ['check', 'install', 'check']);
      expect(updates.stage, UpdateStage.ready);
      expect(await updates.install(), 'installer');
    },
  );
  test('failed installer releases the guard and can be retried', () async {
    respond((call) async {
      if (call.method == 'install')
        throw PlatformException(code: 'INSTALL_UNAVAILABLE');
      return {'status': 'ready', 'versionName': '0.1.3'};
    });
    await updates.check();
    expect(await updates.install(), 'failed');
    expect(updates.busy, false);
    expect(await updates.install(), 'failed');
    expect(calls, ['check', 'install', 'install']);
  });
  test(
    'background timer checks are deferred without touching the package',
    () async {
      respond((_) async => {'status': 'current'});
      updates.setForeground(false);
      await updates.check(force: true);
      expect(calls, isEmpty);
      updates.setForeground(true);
      await updates.check();
      expect(calls, ['check']);
    },
  );
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
