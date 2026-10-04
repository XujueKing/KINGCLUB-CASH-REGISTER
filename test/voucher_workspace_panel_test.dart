import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/live/voucher_workspace_panel.dart';
import 'package:kingclub_cash_register/src/strings.dart';
import 'voucher_lookup_panel_test.dart' show LookupAuth;

class VoucherAuth extends LookupAuth {
  final requests=<Completer<Map<String,dynamic>>>[];
  @override
  Future<Map<String,dynamic>> prepareDouyinVoucher(String scan){
    final next=Completer<Map<String,dynamic>>();requests.add(next);return next.future;
  }
}
Map<String,dynamic> preview()=>{'state':'prepared','packages':[{
  'state':'mapped','selectionIndex':0,'title':'Beer package','revision':1,
  'lines':[{'name':'Beer','quantity':6}],
  'choiceGroups':[{'groupRef':'snacks','name':'Choose two','choose':2,'options':[
    for(final name in ['Beans','Peanuts','Tofu']){'productRef':name,'name':name,'quantity':1}]}]
}]};
void main(){
  Future<(VoucherAuth,StreamController<String>)> mount(WidgetTester tester)async{
    final auth=VoucherAuth(),scanner=StreamController<String>.broadcast();
    addTearDown(auth.dispose);addTearDown(scanner.close);
    await tester.pumpWidget(MaterialApp(home:Scaffold(body:VoucherWorkspacePanel(auth:auth,language:UiLanguage.en,tableName:'V1',scannerEvents:scanner.stream))));
    return(auth,scanner);
  }
  testWidgets('native scan needs no input focus, blocks payment codes and shows package options',(tester)async{
    final(auth,scanner)=await mount(tester);
    await tester.tap(find.byKey(const ValueKey('voucher-channel-douyin')));await tester.pump();
    scanner.add('130000000000000000');await tester.pump();
    expect(auth.requests,isEmpty);expect(find.text(tr(UiLanguage.en,'voucherWrongCode')),findsOneWidget);
    scanner.add('123456789012');await tester.pump();expect(auth.requests,hasLength(1));
    auth.requests.single.complete(preview());await tester.pumpAndSettle();
    expect(find.text('Beer package'),findsOneWidget);expect(find.text('Beer × 6'),findsOneWidget);
    await tester.ensureVisible(find.widgetWithText(FilterChip,'Beans × 1'));
    await tester.tap(find.widgetWithText(FilterChip,'Beans × 1'));await tester.pump();
    await tester.tap(find.widgetWithText(FilterChip,'Peanuts × 1'));await tester.pump();
    await tester.tap(find.widgetWithText(FilterChip,'Tofu × 1'));await tester.pump();
    expect(tester.widget<FilterChip>(find.widgetWithText(FilterChip,'Tofu × 1')).selected,isFalse);
    await tester.pump(const Duration(seconds:31));
    expect(find.text('Beer package'),findsNothing);
  });
  testWidgets('numeric code does not guess channel and late response cannot cross selection',(tester)async{
    final(auth,scanner)=await mount(tester);
    scanner.add('123456789012');await tester.pump();expect(auth.requests,isEmpty);
    expect(find.text(tr(UiLanguage.en,'voucherChooseChannel')),findsOneWidget);
    scanner.add('https://v.douyin.com/test/');await tester.pump();expect(auth.requests,hasLength(1));
    await tester.pumpWidget(const MaterialApp(home:Scaffold()));
    auth.requests.single.complete(preview());await tester.pump();
    expect(tester.takeException(),isNull);
  });
}
