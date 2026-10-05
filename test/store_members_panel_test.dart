import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/live/store_members_panel.dart';
import 'package:kingclub_cash_register/src/strings.dart';

import 'live_tables_panel_test.dart' show TableAuth, PanelRealtime;

class StoreMemberAuth extends TableAuth {
  final calls = <Map<String, dynamic>>[];
  bool linked = false;
  bool fail = false;
  bool second = false;
  final pending = <String, Completer<Map<String, dynamic>>>{};
  void announce() => notifyListeners();
  final member = <String, dynamic>{
    'userAccount': 'TEST_MEMBER',
    'memberId': 'KM_TEST_ONLY',
    'nickname': 'Test member',
    'phone': null,
    'avatarBase64': null,
  };
  @override
  Future<Map<String, dynamic>> storeMembers(Map<String, dynamic> params) async {
    calls.add({...params});
    if (params['action'] == 'link') {
      if (fail) throw StateError('TEST_ONLY_FAILURE');
      linked = true;
    }
    if (params['action'] == 'list')
      return {
        'members': [
          if (linked) member,
          if (second)
            {
              ...member,
              'userAccount': 'TEST_SECOND',
              'memberId': 'KM_SECOND',
              'nickname': 'Second member',
            },
        ],
        'nextAfter': null,
      };
    final result = <String, dynamic>{
      'storeName': 'Test store',
      'member': params['targetAccount'] == 'TEST_SECOND'
          ? {
              ...member,
              'userAccount': 'TEST_SECOND',
              'memberId': 'KM_SECOND',
              'nickname': 'Second member',
            }
          : member,
      'balance': {'principalCents': 700, 'giftCents': 200, 'status': 'active'},
      'history': [],
      'campaigns': [],
    };
    if (params['action'] == 'detail' &&
        pending.containsKey(params['targetAccount'])) {
      await pending[params['targetAccount']]!.future;
    }
    return result;
  }
}

void main() {
  testWidgets(
    'member selection, top alignment and realtime favourites do not leak old details',
    (tester) async {
      tester.view.physicalSize = const Size(1366, 768);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final auth = StoreMemberAuth()..linked = true;
      final realtime = PanelRealtime(auth.session);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StoreMembersPanel(
              auth: auth,
              language: UiLanguage.en,
              enableRealtime: true,
              realtimeFactory: (_) => realtime,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.refresh), findsNothing);
      expect(find.text('TEST_MEMBER'), findsNothing);
      expect(find.text('KM_TEST_ONLY'), findsOneWidget);
      auth.second = true;
      realtime.lastTopic = 'members';
      realtime.changed();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();
      expect(find.text('Second member'), findsOneWidget);
      final first = Completer<Map<String, dynamic>>();
      auth.pending['TEST_MEMBER'] = first;
      await tester.tap(find.byKey(const ValueKey('store-member-TEST_MEMBER')));
      await tester.pump();
      // Unrelated auth notifications must not invalidate the current member request.
      auth.announce();
      await tester.tap(find.byKey(const ValueKey('store-member-TEST_SECOND')));
      await tester.pumpAndSettle();
      expect(find.text('Second member'), findsNWidgets(2));
      expect(
        tester.getTopLeft(find.text('Second member').last).dy,
        lessThan(60),
      );
      first.complete({});
      await tester.pumpAndSettle();
      expect(find.text('Second member'), findsNWidgets(2));
      expect(find.text('Test member'), findsOneWidget);
      auth.pending.clear();
      await tester.tap(find.byKey(const ValueKey('store-member-TEST_MEMBER')));
      auth.announce();
      await tester.pumpAndSettle();
      expect(find.text('Test member'), findsNWidgets(2));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      auth.dispose();
    },
  );
  testWidgets(
    'scan enrols and opens details without confirmation; payment codes do not enrol',
    (tester) async {
      tester.view.physicalSize = const Size(1366, 768);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('kingclub/scanner'),
            (_) async => null,
          );
      final auth = StoreMemberAuth();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StoreMembersPanel(auth: auth, language: UiLanguage.en),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('No members yet. Scan to add.'), findsOneWidget);
      Future<void> scan(String code) async {
        await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
          'kingclub/scanner',
          const StandardMethodCodec().encodeSuccessEnvelope(code),
          (_) {},
        );
        await tester.pumpAndSettle();
      }

      await scan('123456789012345678');
      expect(auth.linked, false);
      auth.fail = true;
      await scan('KC:M:${'A' * 32}');
      expect(auth.linked, false);
      auth.fail = false;
      await scan('KC:M:${'A' * 32}');
      expect(auth.linked, true);
      expect(find.text('Test member'), findsWidgets);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.textContaining('Member card'), findsOneWidget);
      expect(find.textContaining('9.00'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      auth.dispose();
      debugDefaultTargetPlatformOverride = null;
    },
  );
}
