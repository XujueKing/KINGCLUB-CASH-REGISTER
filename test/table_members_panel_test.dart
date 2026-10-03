import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/live/member_identity.dart';
import 'package:kingclub_cash_register/src/live/table_members_panel.dart';
import 'package:kingclub_cash_register/src/strings.dart';

import 'live_tables_panel_test.dart' show TableAuth;

class MemberAuth extends TableAuth {
  final linked = <String>{};
  int writes = 0;
  bool fail = false;
  @override
  Future<MemberIdentity> readMemberIdentity(String code) async =>
      MemberIdentity.parse({
        'result': {
          'storeRef': 'test-store',
          'purpose': 'member_identity',
          'member': {
            'memberRef': code.endsWith('A') ? 'test-a' : 'test-b',
            'nickname': 'Test member',
          },
          'observedAt': '2026-10-03T00:00:00.000Z',
          'expiresAt': '2026-10-03T00:01:00.000Z',
        },
      }, storeRef: 'test-store');
  @override
  Future<List<Map<String, String?>>> tableMembers({
    required String tableRef,
    required String sessionRef,
    String? identityCode,
  }) async {
    if (identityCode != null) {
      writes++;
      if (fail) throw StateError('TEST network');
      linked.add(identityCode.endsWith('A') ? 'test-a' : 'test-b');
    }
    return [
      for (final account in linked)
        {
          'userAccount': account,
          'nickname': account,
          'linkedBy': 'test-employee',
          'linkedAt': '2026-10-03T00:00:00.000Z',
        },
    ];
  }
}

void main() {
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('kingclub/scanner'),
          (_) async => null,
        );
  });
  testWidgets('member popup stays on failure and closes on confirmed scan', (
    tester,
  ) async {
    final auth = MemberAuth();
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TableMembersButton(
            auth: auth,
            language: UiLanguage.zh,
            tableRef: 'test-table',
            sessionRef: 'H00000000001',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('table-members-open')));
    await tester.pumpAndSettle();
    Future<void> scan() async {
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        'kingclub/scanner',
        const StandardMethodCodec().encodeSuccessEnvelope('KC:M:' + 'A' * 32),
        (_) {},
      );
      await tester.pumpAndSettle();
    }

    auth.fail = true;
    await scan();
    expect(find.byType(AlertDialog), findsOneWidget);
    auth.fail = false;
    await scan();
    expect(find.byType(AlertDialog), findsNothing);
    expect(auth.linked, {'test-a'});
    expect(find.text('t'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    auth.dispose();
    debugDefaultTargetPlatformOverride = null;
  });
  for (final language in UiLanguage.values) {
    testWidgets('focusless member linking and retry ${language.name}', (
      tester,
    ) async {
      final auth = MemberAuth(), key = GlobalKey<TableMembersPanelState>();
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TableMembersPanel(
              key: key,
              auth: auth,
              language: language,
              tableRef: 'test-table',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);
      Future<void> scan(String letter) async {
        await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
          'kingclub/scanner',
          const StandardMethodCodec().encodeSuccessEnvelope(
            'KC:M:' + letter * 32,
          ),
          (_) {},
        );
        await tester.pumpAndSettle();
      }

      await scan('A');
      await scan('A');
      await scan('B');
      expect(key.currentState!.pending.length, 2);
      expect(auth.writes, 0);
      auth.fail = true;
      expect(await key.currentState!.attachTo('H00000000001'), false);
      expect(key.currentState!.pending.length, 2);
      auth.fail = false;
      expect(await key.currentState!.attachTo('H00000000001'), true);
      expect(auth.linked.length, 2);
      expect(key.currentState!.pending, isEmpty);
      await scan('A');
      expect(key.currentState!.members.length, 2);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      auth.dispose();
      debugDefaultTargetPlatformOverride = null;
    });
  }
}
