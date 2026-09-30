import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/live/member_identity.dart';
import 'package:kingclub_cash_register/src/live/member_identity_panel.dart';
import 'package:kingclub_cash_register/src/strings.dart';

import 'live_tables_panel_test.dart' show TableAuth;
import 'staff_session_test.dart' as a;
import 'catalog_snapshot_test.dart' show Api, loginChannel;

Map<String, dynamic> fixture() => {
  'result': {
    'storeRef': 'test-store',
    'purpose': 'member_identity',
    'member': {'memberRef': 'test-member', 'nickname': 'TEST guest'},
    'observedAt': '2026-10-01T00:00:00.000Z',
    'expiresAt': '2026-10-01T00:01:00.000Z',
  },
};
MemberIdentity identity() =>
    MemberIdentity.parse(fixture(), storeRef: 'test-store');

class IdentityAuth extends TableAuth {
  IdentityAuth() : super(permissions: ['workbench.read', 'orders.create']);
  Completer<MemberIdentity>? pending;
  final scans = <String>[];
  @override
  Future<MemberIdentity> readMemberIdentity(String code) async {
    scans.add(code);
    return pending == null ? identity() : await pending!.future;
  }

  void changed() => notifyListeners();
}

void main() {
  testWidgets('keyboard scanning stays ready after a delayed lookup', (
    tester,
  ) async {
    final auth = IdentityAuth()..pending = Completer<MemberIdentity>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MemberIdentityPanel(auth: auth, language: UiLanguage.zh),
        ),
      ),
    );
    final field = find.byKey(const ValueKey('member-identity-code'));
    await tester.enterText(field, 'KC:M:${'A' * 32}');
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump();
    auth.pending!.complete(identity());
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(field).focusNode!.hasFocus, isTrue);
    await tester.pumpWidget(const SizedBox());
    auth.dispose();
  });
  testWidgets(
    'scanner broadcasts identify without input focus and stop after leaving',
    (tester) async {
      final auth = IdentityAuth(),
          events = StreamController<String>.broadcast();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MemberIdentityPanel(
              auth: auth,
              language: UiLanguage.zh,
              scannerEvents: events.stream,
            ),
          ),
        ),
      );
      events.add('KC:M:${'A' * 32}');
      await tester.pumpAndSettle();
      expect(auth.scans, hasLength(1));
      expect(find.text('TEST guest'), findsOneWidget);
      await tester.testTextInput.receiveAction(TextInputAction.go);
      await tester.pump();
      expect(find.text('TEST guest'), findsOneWidget);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      events.add('KC:M:${'B' * 32}');
      await tester.pump();
      expect(auth.scans, hasLength(1));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(const SizedBox());
      expect(events.hasListener, isFalse);
      await events.close();
      auth.dispose();
    },
  );
  testWidgets('complete keyboard scan identifies without an enter suffix', (
    tester,
  ) async {
    final auth = IdentityAuth();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MemberIdentityPanel(auth: auth, language: UiLanguage.zh),
        ),
      ),
    );
    await tester.pump();
    final field = find.byKey(const ValueKey('member-identity-code'));
    expect(tester.widget<TextField>(field).focusNode!.hasFocus, isTrue);
    await tester.enterText(field, 'KC:M:${'A' * 32}');
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pumpAndSettle();
    expect(auth.scans, hasLength(1));
    expect(find.text('TEST guest'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    auth.dispose();
  });

  test(
    'controller binds the employee store and discards a reply after logout',
    () async {
      final api = Api()..pendingRead = Completer<Object?>();
      final controller = a.controller(a.TestStorage(), loginChannel(), api);
      await a.login(controller);
      await expectLater(
        controller.readMemberIdentity('KCPAY1:${'A' * 43}'),
        throwsA(anything),
      );
      expect(api.id, isNull);
      final pending = controller.readMemberIdentity('KC:M:${'A' * 32}');
      expect(api.id, 'K261001001951');
      expect(api.params, {
        'storeRef': 'test-store',
        'identityCode': 'KC:M:${'A' * 32}',
      });
      final rejected = expectLater(pending, throwsA(anything));
      await controller.logout();
      api.pendingRead!.complete(fixture());
      await rejected;
      controller.dispose();
    },
  );
  test(
    'strict store, purpose, minimal identity and monotonic remaining validity',
    () {
      expect(identity().validFor, const Duration(seconds: 58));
      expect(
        MemberIdentity.parse(
          fixture(),
          storeRef: 'test-store',
          elapsed: const Duration(seconds: 8),
        ).validFor,
        const Duration(seconds: 50),
      );
      for (final patch in [
        {'storeRef': 'other'},
        {'purpose': 'payment'},
        {
          'member': {'memberRef': 'bad/ref', 'nickname': 'TEST'},
        },
        {
          'member': {'memberRef': 'test-member', 'nickname': 'bad\nname'},
        },
        {'expiresAt': '2026-10-01T00:02:00.000Z'},
        {'expiresAt': '2026-10-01T00:00:00.000Z'},
      ]) {
        expect(
          () => MemberIdentity.parse({
            'result': {...fixture()['result'], ...patch},
          }, storeRef: 'test-store'),
          throwsFormatException,
        );
      }
      expect(
        () => MemberIdentity.parse(
          fixture(),
          storeRef: 'test-store',
          elapsed: const Duration(seconds: 60),
        ),
        throwsFormatException,
      );
    },
  );
  testWidgets(
    'four languages, scanner enter, next customer and expiry clear identity',
    (tester) async {
      tester.view.physicalSize = const Size(1024, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final auth = IdentityAuth();
      for (final language in UiLanguage.values) {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: MemberIdentityPanel(auth: auth, language: language),
            ),
          ),
        );
        await tester.enterText(
          find.byKey(const ValueKey('member-identity-code')),
          'KC:M:${'A' * 32}',
        );
        await tester.testTextInput.receiveAction(TextInputAction.go);
        await tester.pumpAndSettle();
        expect(find.text('TEST guest'), findsOneWidget);
        expect(
          tester
              .widget<TextField>(
                find.byKey(const ValueKey('member-identity-code')),
              )
              .controller!
              .text,
          isEmpty,
        );
        expect(tester.takeException(), isNull);
        await tester.pump(const Duration(seconds: 59));
        expect(find.text('TEST guest'), findsNothing);
      }
      await tester.pumpWidget(const SizedBox());
      auth.dispose();
    },
  );
  testWidgets(
    'wrong purpose is not sent and editing clears previous identity',
    (tester) async {
      final auth = IdentityAuth();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MemberIdentityPanel(auth: auth, language: UiLanguage.zh),
          ),
        ),
      );
      for (final value in [
        'KCPAY1:${'A' * 43}',
        'KC:S:${'A' * 32}',
        'member-ref',
      ]) {
        await tester.enterText(
          find.byKey(const ValueKey('member-identity-code')),
          value,
        );
        await tester.tap(find.byKey(const ValueKey('member-identity-scan')));
        await tester.pumpAndSettle();
        expect(auth.scans, isEmpty);
        expect(
          find.text(tr(UiLanguage.zh, 'memberIdentityFailed')),
          findsOneWidget,
        );
      }
      await tester.enterText(
        find.byKey(const ValueKey('member-identity-code')),
        'KC:M:${'A' * 32}',
      );
      await tester.tap(find.byKey(const ValueKey('member-identity-scan')));
      await tester.pumpAndSettle();
      expect(find.text('TEST guest'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('member-identity-code')),
        'next',
      );
      await tester.pump();
      expect(find.text('TEST guest'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      auth.dispose();
    },
  );
  for (final reason in ['background', 'identity', 'leave']) {
    testWidgets('late scan cannot survive $reason', (tester) async {
      final auth = IdentityAuth()..pending = Completer<MemberIdentity>();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MemberIdentityPanel(auth: auth, language: UiLanguage.zh),
          ),
        ),
      );
      await tester.enterText(
        find.byKey(const ValueKey('member-identity-code')),
        'KC:M:${'A' * 32}',
      );
      await tester.tap(find.byKey(const ValueKey('member-identity-scan')));
      await tester.pump();
      if (reason == 'identity') auth.changed();
      if (reason == 'background') {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
      }
      if (reason == 'leave') await tester.pumpWidget(const SizedBox());
      auth.pending!.complete(identity());
      await tester.pump();
      expect(find.text('TEST guest'), findsNothing);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(const SizedBox());
      auth.dispose();
      expect(tester.takeException(), isNull);
    });
  }
}
