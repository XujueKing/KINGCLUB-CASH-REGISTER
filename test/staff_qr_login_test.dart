import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/auth/staff_qr_login.dart';
import 'package:kingclub_cash_register/src/auth/staff_auth_controller.dart';
import 'package:kingclub_cash_register/src/network/ccsop_client.dart';
import 'package:kingclub_cash_register/src/strings.dart';

class QrAuth extends StaffAuthController {
  bool failPoll = false, expiredCancel = false;
  final actions = <String>[];
  @override
  Future<Map<String, dynamic>> qrLoginCall(
    String base,
    Map<String, dynamic> p, {
    required bool Function() stillCurrent,
  }) async {
    actions.add(p['action'] as String);
    if (p['action'] == 'cancel' && expiredCancel)
      throw const CcsopFailure('CASHIER_QR_EXPIRED');
    if (p['action'] == 'poll' && failPoll)
      throw const CcsopFailure('TRANSPORT_FAILED');
    if (p['action'] == 'create')
      return {
        'challengeId': 'a' * 64,
        'pollSecret': 'b' * 64,
        'code': 'kingclub://cashier-login/v1/${'a' * 64}',
        'expiresAtMs': DateTime.now()
            .add(const Duration(minutes: 5))
            .millisecondsSinceEpoch,
      };
    return {'status': 'pending'};
  }
}

void main() {
  Future<void> show(WidgetTester t, QrAuth a) async {
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StaffQrLogin(
            auth: a,
            base: 'https://service.invalid',
            language: UiLanguage.en,
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
  }

  testWidgets('recovered polling removes stale network error', (t) async {
    final a = QrAuth();
    addTearDown(a.dispose);
    await show(t, a);
    a.failPoll = true;
    await t.pump(const Duration(seconds: 2));
    await t.pump();
    expect(find.text(tr(UiLanguage.en, 'staffQrFailed')), findsOneWidget);
    a.failPoll = false;
    await t.pump(const Duration(seconds: 2));
    await t.pump();
    expect(find.text(tr(UiLanguage.en, 'staffQrFailed')), findsNothing);
    await t.pumpWidget(const SizedBox());
  });
  testWidgets('expired screen challenge does not block fresh member code', (
    t,
  ) async {
    final a = QrAuth()..expiredCancel = true;
    addTearDown(a.dispose);
    await show(t, a);
    final dynamic state = t.state(find.byType(StaffQrLogin));
    await state.scan('KC:M:${'A' * 32}');
    await t.pump();
    expect(a.actions, containsAllInOrder(['create', 'cancel', 'member']));
    expect(find.text(tr(UiLanguage.en, 'staffQrDenied')), findsNothing);
    await t.pumpWidget(const SizedBox());
  });
}
