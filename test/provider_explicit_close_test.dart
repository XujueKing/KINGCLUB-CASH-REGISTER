import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/auth/session_vault.dart';
import 'package:kingclub_cash_register/src/auth/staff_auth_controller.dart';
import 'package:kingclub_cash_register/src/live/provider_payment.dart';
import 'package:kingclub_cash_register/src/live/provider_payment_panel.dart';
import 'package:kingclub_cash_register/src/strings.dart';
import 'staff_session_test.dart' as staff;
import 'table_checkout_dialog_test.dart' show CheckoutDialogAuth;

class CloseApi extends staff.TestApi {
  final calls=<String>[];
  @override Future<Object?> call(String id,Map<String,dynamic> p) async {
    calls.add(id);expect(p.containsKey('authCode'),false);
    return {'result':{'state':'unknown','requestId':p['requestId']}};
  }
}
class CloseAuth extends CheckoutDialogAuth {
  CloseAuth():super(permissions:['workbench.read','payment.alipay']);
  late final original=ProviderPayment.create(session,'D00000000001','alipay',100);
  int closes=0;
  @override Future<List<ProviderPayment>> pendingProviderPayments(String channel) async=>[original];
  @override Future<ProviderPaymentResult> queryProvider(ProviderPayment command) async=>ProviderPaymentResult.parse(
    {'result':{'state':'pending','requestId':command.requestId,'canCloseUnpaid':closes==0}},command);
  @override Future<ProviderPaymentResult> closeProvider(ProviderPayment command,{required bool Function() stillCurrent}) async {
    expect(stillCurrent(),true);closes++;
    return ProviderPaymentResult.parse({'result':{'state':'unknown','requestId':command.requestId}},command);
  }
}
void main(){
  test('explicit close uses original journal and retains unknown result',() async {
    final storage=staff.TestStorage();storage.data[SessionVault.deviceKey]=staff.device;
    final api=CloseApi(),login=staff.TestAuth()..result={...staff.response(),'permissions':['workbench.read','payment.alipay']};
    final journal=ProviderPaymentJournal(storage:storage);
    final auth=StaffAuthController(vault:SessionVault(storage:storage),authFactory:(_)=>login,sessionFactory:(_)=>api,providerJournal:journal,now:()=>staff.now);
    await staff.login(auth);
    final command=ProviderPayment.create(auth.session!,'D00000000001','alipay',100);
    await expectLater(auth.closeProvider(command,stillCurrent:()=>true),throwsA(anything));
    expect(api.calls,isEmpty);
    await journal.save(auth.session!,command);
    await expectLater(auth.closeProvider(command,stillCurrent:()=>false),throwsA(anything));
    expect(api.calls,isEmpty);
    expect((await auth.closeProvider(command,stillCurrent:()=>true)).state,'unknown');
    expect(api.calls,['K261002001962']);expect((await journal.load(auth.session!)).single.requestId,command.requestId);
    auth.dispose();
  });
  testWidgets('close is explicit and disappears after send; polling never closes again',(tester) async {
    final auth=CloseAuth();
    await tester.pumpWidget(MaterialApp(home:Scaffold(body:ProviderPaymentPanel(auth:auth,orderRef:'D00000000001',totalCents:100,language:UiLanguage.en,recoveryOnly:true))));
    await tester.pumpAndSettle();
    final close=find.text(tr(UiLanguage.en,'provider_close_attempt'));
    expect(close,findsNothing);
    await tester.tap(find.text(tr(UiLanguage.en,'provider_query')));await tester.pumpAndSettle();
    expect(close,findsOneWidget);expect(auth.closes,0);
    await tester.tap(close);await tester.pumpAndSettle();
    expect(close,findsNothing);expect(auth.closes,1);
    await tester.pump(const Duration(seconds:11));await tester.pumpAndSettle();expect(auth.closes,1);
    await tester.pumpWidget(const SizedBox());auth.dispose();
  });
}
