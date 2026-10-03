import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/live/table_discount_dialog.dart';
import 'package:kingclub_cash_register/src/live/table_checkout_command.dart';
import 'package:kingclub_cash_register/src/network/ccsop_client.dart';
import 'package:kingclub_cash_register/src/strings.dart';
import 'table_checkout_dialog_test.dart' show CheckoutDialogAuth;
import 'table_checkout_command_test.dart' as fixture;

class DiscountAuth extends CheckoutDialogAuth {
  int calls=0; bool fail=false;
  final requests=<Map<String,Object>>[];
  @override Future<Map<String,dynamic>> adjustTableBill(Map<String,Object> request,{String? identityCode,bool queryOnly=false}) async {
    calls++;requests.add({...request,'queryOnly':queryOnly});
    if(fail)throw const CcsopFailure('NETWORK_ERROR');
    if(!queryOnly)expect(identityCode,'KC:M:${'A'*32}');
    return {'state':'applied','requestId':request['requestId'],'totalCents':240,'discountCents':60,'changedLines':2};
  }
}
void main(){
 testWidgets('one manager scan applies bill discount and uncertain original is queried after reopening',(tester)async{
  FlutterSecureStorage.setMockInitialValues({});
  debugDefaultTargetPlatformOverride=TargetPlatform.android;
  addTearDown(()=>debugDefaultTargetPlatformOverride=null);
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('kingclub/scanner'),(_)async=>null);
  final auth=DiscountAuth();
  final quote=TableCheckoutQuote.parse(fixture.tableQuoteFixture(),storeRef:'test-store',tableRef:'TEST_TABLE',sessionRef:'TEST_SESSION',channel:'member_balance',accountType:'store_balance');
  await tester.pumpWidget(MaterialApp(home:Builder(builder:(context)=>Scaffold(body:TextButton(onPressed:()=>showDialog<Map<String,dynamic>>(context:context,builder:(_)=>TableDiscountDialog(auth:auth,quote:quote,language:UiLanguage.en,requestId:'00000000-0000-4000-8000-000000000001')),child:const Text('Open'))))));
  await tester.tap(find.text('Open'));await tester.pumpAndSettle();
  await tester.tap(find.text(tr(UiLanguage.en,'confirm')));await tester.pumpAndSettle();
  expect(auth.calls,0);
  auth.fail=true;
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage('kingclub/scanner',const StandardMethodCodec().encodeSuccessEnvelope('KC:M:${'A'*32}'),(_){});
  await tester.pumpAndSettle();expect(auth.calls,1);expect(find.byType(AlertDialog),findsOneWidget);
  await tester.tap(find.text(tr(UiLanguage.en,'cancel')));await tester.pumpAndSettle();
  auth.fail=false;
  await tester.tap(find.text('Open'));await tester.pumpAndSettle();
  expect(auth.calls,2);expect(auth.requests.last['queryOnly'],true);expect(auth.requests.last['requestId'],auth.requests.first['requestId']);
  expect(find.byType(AlertDialog),findsNothing);
  await tester.pumpWidget(const SizedBox());auth.dispose();debugDefaultTargetPlatformOverride=null;
 });
}
