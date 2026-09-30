import 'support/lifecycle.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/live/recharge_resume_dialog.dart';
import 'package:kingclub_cash_register/src/live/recharge_journal.dart';
import 'package:kingclub_cash_register/src/live/recharge_result.dart';
import 'package:kingclub_cash_register/src/strings.dart';
import 'recharge_recovery_panel_test.dart' as recovery;
import 'recharge_context_test.dart' as context_fixture;
import 'package:kingclub_cash_register/src/live/recharge_context.dart';

class ResumeAuth extends recovery.RecoveryAuth {
  int sends=0;
  bool wrongAmount=false;
  @override Future<RechargeContext> readRechargeContext(String rechargeRef) async {
    final raw=context_fixture.fixture();
    raw['result']['storeRef']=command.storeRef;
    raw['result']['rechargeRef']=command.rechargeRef;
    if(wrongAmount)raw['result']['principalCents']='9000';
    return RechargeContext.parse(raw,storeRef:command.storeRef,rechargeRef:command.rechargeRef);
  }
  @override Future<RechargeResult> sendUnsentRecharge(RechargeCommand command,{
    required String authCode,required bool Function() stillCurrent}) async {
    expect(stillCurrent(),isTrue);expect(authCode,'130000000000000000');sends++;
    return RechargeResult.parse({'result':{'state':'unknown','rechargeRef':command.rechargeRef}},
      storeRef:command.storeRef,rechargeRef:command.rechargeRef);
  }
}
void main(){
  testWidgets('requires explicit consent and fresh code; one attempt per dialog',(tester)async{
    final auth=ResumeAuth();addTearDown(auth.dispose);
    await tester.pumpWidget(MaterialApp(home:Scaffold(body:RechargeResumeDialog(auth:auth,command:auth.command,language:UiLanguage.zh))));
    await tester.pump();
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,isNull);
    expect(find.textContaining('CNY 20.00'),findsOneWidget);
    await tester.ensureVisible(find.byType(TextField));
    await tester.enterText(find.byType(TextField),'130000000000000000');await tester.pump();
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,isNull);
    await tester.ensureVisible(find.byType(CheckboxListTile));
    await tester.tap(find.byType(CheckboxListTile));await tester.pump();
    await tester.tap(find.byType(FilledButton));await tester.pump();
    expect(auth.sends,1);expect(find.byType(TextField),findsNothing);expect(find.byType(FilledButton),findsNothing);
    expect(find.text(tr(UiLanguage.zh,'rechargeState_unknown')),findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('background discards payer code and disables continuation',(tester)async{
    final auth=ResumeAuth();addTearDown(auth.dispose);
    await tester.pumpWidget(MaterialApp(home:Scaffold(body:RechargeResumeDialog(auth:auth,command:auth.command,language:UiLanguage.en))));
    await tester.pump();
    await tester.ensureVisible(find.byType(TextField));
    await tester.enterText(find.byType(TextField),'130000000000000000');
    final controller=tester.widget<TextField>(find.byType(TextField)).controller!;
    await transitionLifecycle(tester, AppLifecycleState.paused);await tester.pump();
    expect(controller.text,isEmpty);expect(find.byType(TextField),findsNothing);expect(auth.sends,0);
    await transitionLifecycle(tester, AppLifecycleState.resumed);await tester.pump();
    expect(find.byType(FilledButton),findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('mismatched original amount prevents consent and sending',(tester)async{
    final auth=ResumeAuth()..wrongAmount=true;addTearDown(auth.dispose);
    await tester.pumpWidget(MaterialApp(home:Scaffold(body:RechargeResumeDialog(auth:auth,command:auth.command,language:UiLanguage.en))));
    await tester.pump();
    expect(find.byType(TextField),findsNothing);expect(find.byType(FilledButton),findsNothing);
    expect(auth.sends,0);await tester.pumpWidget(const SizedBox());
  });
}
