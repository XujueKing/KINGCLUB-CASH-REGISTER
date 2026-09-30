import 'support/lifecycle.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/auth/staff_auth_controller.dart';
import 'package:kingclub_cash_register/src/auth/staff_session.dart';
import 'package:kingclub_cash_register/src/live/recharge_journal.dart';
import 'package:kingclub_cash_register/src/live/recharge_result.dart';
import 'package:kingclub_cash_register/src/live/recharge_recovery_panel.dart';
import 'package:kingclub_cash_register/src/strings.dart';
import 'staff_session_test.dart' as staff;

class RecoveryAuth extends StaffAuthController {
  final identity=staff.session({...staff.response(),'permissions':['workbench.read','payment.wechat'],
    'expiresAtMs':DateTime.utc(2090).millisecondsSinceEpoch,'refreshExpiresAtMs':DateTime.utc(2091).millisecondsSinceEpoch});
  int queries=0;
  String state='credit_pending';
  Completer<RechargeResult>? gate;
  @override StaffSession get session=>identity;
  RechargeCommand get command=>RechargeCommand.forSession(identity,
    rechargeRef:'00000000-0000-4000-8000-000000000010',channel:'wechat',principalCents:10000);
  @override Future<List<RechargeCommand>> pendingRecharges(String channel) async=>[command];
  @override Future<RechargeResult> recoverRecharge(RechargeCommand command) async {
    queries++;
    if(gate!=null)return gate!.future;
    return RechargeResult.parse({'result':{'state':state,'rechargeRef':command.rechargeRef}},
      storeRef:command.storeRef,rechargeRef:command.rechargeRef);
  }
}
void main(){
  testWidgets('shows original principal and explicit pending-credit result without payer input',(tester)async{
    final auth=RecoveryAuth();addTearDown(auth.dispose);
    await tester.pumpWidget(MaterialApp(home:Scaffold(body:RechargeRecoveryPanel(auth:auth,language:UiLanguage.zh,onBack:(){}))));
    await tester.pump();
    expect(find.textContaining('100.00'),findsOneWidget);
    expect(find.byType(TextField),findsNothing);expect(auth.queries,0);
    await tester.tap(find.text(tr(UiLanguage.zh,'rechargeQuery')));await tester.pump();
    expect(auth.queries,1);expect(find.text(tr(UiLanguage.zh,'rechargeState_credit_pending')),findsOneWidget);
    expect(find.text(tr(UiLanguage.zh,'rechargeState_credited')),findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('background clears records and late query cannot restore them',(tester)async{
    final auth=RecoveryAuth()..gate=Completer<RechargeResult>();addTearDown(auth.dispose);
    await tester.pumpWidget(MaterialApp(home:Scaffold(body:RechargeRecoveryPanel(auth:auth,language:UiLanguage.en,onBack:(){}))));
    await tester.pump();await tester.tap(find.text(tr(UiLanguage.en,'rechargeQuery')));await tester.pump();
    await transitionLifecycle(tester, AppLifecycleState.paused);await tester.pump();
    auth.gate!.complete(RechargeResult.parse({'result':{'state':'unknown','rechargeRef':auth.command.rechargeRef}},
      storeRef:'test-store',rechargeRef:auth.command.rechargeRef));
    await tester.pump();expect(find.textContaining(auth.command.rechargeRef),findsNothing);
    await tester.pumpWidget(const SizedBox());
    await transitionLifecycle(tester, AppLifecycleState.resumed);
  });
}
