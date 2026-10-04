import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/auth/staff_access_page.dart';
import 'package:kingclub_cash_register/src/auth/staff_auth_controller.dart';

// UI-only double: never used as an authentication or persistence fallback.
class UiAuth extends StaffAuthController {
  @override
  Future<Map<String,dynamic>> qrLoginCall(String base,Map<String,dynamic> params,{required bool Function() stillCurrent}) async => {
    'challengeId':'a'*64,'pollSecret':'b'*64,'code':'kingclub://cashier-login/v1/${'a'*64}',
    'expiresAtMs':DateTime.now().add(const Duration(minutes:5)).millisecondsSinceEpoch,'status':'pending'};
  int restores = 0, logins = 0;
  String? submittedPassword;
  Completer<void>? gate;
  bool waiting = false;
  bool retryRestore = false;
  @override bool get canRetryRestore => retryRestore;
  @override
  bool get busy => waiting;
  @override
  Future<void> restore() async {
    restores++;
    if(retryRestore&&restores==1)throw StateError('TEST_OFFLINE');
    retryRestore=false;
    notifyListeners();
  }

  @override
  Future<void> login({
    required String base,
    String? storeRef,
    Future<String?> Function(List<Map<String, String>> stores)? selectStore,
    required String loginName,
    required String password,
  }) async {
    logins++;
    submittedPassword = password;
    waiting = true;
    notifyListeners();
    if (gate != null) await gate!.future;
    waiting = false;
    notifyListeners();
    throw StateError('PRIVATE_SERVER_ERROR_MUST_NOT_RENDER');
  }
}

void main() {
  Future<void> show(WidgetTester tester, UiAuth auth) async {
    tester.view.physicalSize = const Size(1024, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(auth.dispose);
    await tester.pumpWidget(
      MaterialApp(home: StaffAccessPage(controller: auth)),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('unsent restore has one reconnect action without entering a password',(tester) async {
    final auth=UiAuth()..retryRestore=true;
    await show(tester,auth);
    final button=find.widgetWithText(FilledButton,'重新连接');expect(button,findsOneWidget);
    await tester.tap(button);await tester.pumpAndSettle();
    expect(auth.restores,2);expect(auth.logins,0);expect(button,findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Cold restore and all four languages fit compact landscape', (
    tester,
  ) async {
    final auth = UiAuth();
    await show(tester, auth);
    expect(auth.restores, 1);
    expect(find.text('T01'), findsNothing);
    for (final label in ['English', '繁體中文', 'ไทย', '简体中文']) {
      await tester.tap(find.byKey(const ValueKey('staff-language')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(label).last);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'Only account and password are shown; password clears and errors are redacted',
    (tester) async {
      final auth = UiAuth();
      await show(tester, auth);
      expect(find.byType(TextFormField), findsNothing);
      await tester.tap(find.byKey(const ValueKey('staff-login-mode')));
      await tester.pumpAndSettle();
      Future<void> enter(String field, String value) =>
          tester.enterText(find.byKey(ValueKey('staff-$field')), value);
      expect(find.byKey(const ValueKey('staff-endpoint')), findsNothing);
      expect(find.byKey(const ValueKey('staff-store')), findsNothing);
      expect(find.byType(TextFormField), findsNWidgets(2));
      await enter('account', 'cashier');
      await enter('password', 'test-only-password');
      auth.gate = Completer<void>();
      await tester.ensureVisible(find.byKey(const ValueKey('staff-login')));
      await tester.tap(find.byKey(const ValueKey('staff-login')));
      await tester.pump();
      expect(auth.logins, 1);
      expect(auth.submittedPassword, 'test-only-password');
      expect(
        tester
            .widget<TextFormField>(find.byKey(const ValueKey('staff-password')))
            .controller!
            .text,
        isEmpty,
      );
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('staff-login')))
            .onPressed,
        isNull,
      );
      auth.gate!.complete();
      await tester.pumpAndSettle();
      expect(find.textContaining('无法确认员工会话'), findsOneWidget);
      expect(find.textContaining('PRIVATE_SERVER_ERROR'), findsNothing);
      expect(find.byKey(const ValueKey('staff-logout')), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
