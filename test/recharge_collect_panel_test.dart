import 'support/lifecycle.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/live/recharge_collect_panel.dart';
import 'package:kingclub_cash_register/src/live/recharge_context.dart';
import 'package:kingclub_cash_register/src/live/recharge_result.dart';
import 'package:kingclub_cash_register/src/strings.dart';
import 'recharge_context_test.dart' as context_fixture;
import 'recharge_recovery_panel_test.dart';

class CollectAuth extends RecoveryAuth {
  int reads=0,sends=0;
  Completer<RechargeContext>? contextGate;
  RechargeContext get contextValue {
    final raw=context_fixture.fixture();
    raw['result']['storeRef']=command.storeRef;
    raw['result']['rechargeRef']=command.rechargeRef;
    return RechargeContext.parse(raw,storeRef:command.storeRef,rechargeRef:command.rechargeRef);
  }
  @override Future<RechargeContext> readRechargeContext(String rechargeRef) async {
    reads++;
    return contextGate==null?contextValue:await contextGate!.future;
  }
  @override Future<RechargeResult> collectRecharge({required String rechargeRef,required String channel,
    required int principalCents,required String authCode,required bool Function() stillCurrent}) async {
    expect(stillCurrent(),isTrue);expect(principalCents,10000);
    sends++;
    return RechargeResult.parse({'result':{'state':'unknown','rechargeRef':rechargeRef}},
      storeRef:command.storeRef,rechargeRef:rechargeRef);
  }
}

void main(){
  testWidgets('loads original split amounts and requires consent before one send',(tester)async{
    final auth=CollectAuth();addTearDown(auth.dispose);
    await tester.pumpWidget(MaterialApp(home:Scaffold(body:RechargeCollectPanel(auth:auth,language:UiLanguage.en,onBack:(){}))));
    expect(auth.reads,0);expect(auth.sends,0);
    await tester.enterText(find.byType(TextField).first,auth.command.rechargeRef);
    await tester.tap(find.text(tr(UiLanguage.en,'rechargeReadOriginal')));await tester.pump();
    expect(find.textContaining('100.00'),findsOneWidget);
    expect(find.textContaining('CNY 20.00'),findsOneWidget);
    await tester.enterText(find.byType(TextField).last,'130000000000000000');
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,isNull);
    await tester.ensureVisible(find.byType(CheckboxListTile));
    await tester.tap(find.byType(CheckboxListTile));await tester.pump();
    await tester.ensureVisible(find.byType(FilledButton));
    await tester.tap(find.byType(FilledButton));await tester.pump();
    expect(auth.sends,1);expect(find.byType(FilledButton),findsNothing);
    expect(find.text(tr(UiLanguage.en,'rechargeState_unknown')),findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('background drops late original context and clears locator',(tester)async{
    final auth=CollectAuth()..contextGate=Completer<RechargeContext>();addTearDown(auth.dispose);
    await tester.pumpWidget(MaterialApp(home:Scaffold(body:RechargeCollectPanel(auth:auth,language:UiLanguage.en,onBack:(){}))));
    await tester.enterText(find.byType(TextField),auth.command.rechargeRef);
    await tester.tap(find.text(tr(UiLanguage.en,'rechargeReadOriginal')));await tester.pump();
    await transitionLifecycle(tester, AppLifecycleState.paused);await tester.pump();
    auth.contextGate!.complete(auth.contextValue);await tester.pump();
    expect(find.textContaining('TEST_MEMBER'),findsNothing);expect(auth.sends,0);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,isEmpty);
    await tester.pumpWidget(const SizedBox());
    await transitionLifecycle(tester, AppLifecycleState.resumed);
  });
}
