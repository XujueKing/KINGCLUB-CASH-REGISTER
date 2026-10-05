import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/live/store_members_panel.dart';
import 'package:kingclub_cash_register/src/strings.dart';

import 'live_tables_panel_test.dart' show TableAuth;

class StoreMemberAuth extends TableAuth {
  final calls = <Map<String, dynamic>>[];
  bool linked = false;
  bool fail = false;
  final member = <String, dynamic>{
    'userAccount': 'TEST_MEMBER',
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
        'members': [if (linked) member],
        'nextAfter': null,
      };
    return {
      'storeName': 'Test store',
      'member': member,
      'balance': {'principalCents': 700, 'giftCents': 200, 'status': 'active'},
      'history': [],
      'campaigns': [],
    };
  }
}

void main() {
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
