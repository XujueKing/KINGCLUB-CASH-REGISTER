import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/live/recharge_context.dart';
import 'package:kingclub_cash_register/src/live/recharge_terms_view.dart';
import 'package:kingclub_cash_register/src/strings.dart';
import 'recharge_context_test.dart' as data;

void main(){
  for(final language in UiLanguage.values){
    testWidgets('original terms and exact percentage in ${language.name}',(tester)async{
      final raw=data.fixture();raw['result']['rulesSnapshot']['maxGiftBasisPoints']=1234;
      final value=RechargeContext.parse(raw,storeRef:'TEST_STORE',rechargeRef:data.original);
      await tester.pumpWidget(MaterialApp(home:Scaffold(body:RechargeTermsView(value:value,language:language))));
      expect(find.textContaining('12.34%'),findsOneWidget);
      expect(find.textContaining('TEST_PRODUCT'),findsOneWidget);
      expect(find.text(tr(language,'recharge_principal_first')),findsOneWidget);
      expect(find.text('TEST ONLY terms'),findsOneWidget);
    });
  }
  testWidgets('empty and unrestricted scopes are not conflated',(tester)async{
    for(final products in <List<String>?>[null,[]]){
      final raw=data.fixture();raw['result']['rulesSnapshot']['eligibleProductRefs']=products;
      final value=RechargeContext.parse(raw,storeRef:'TEST_STORE',rechargeRef:data.original);
      await tester.pumpWidget(MaterialApp(home:Scaffold(body:RechargeTermsView(value:value,language:UiLanguage.en))));
      expect(find.textContaining(tr(UiLanguage.en,products==null?'rechargeAllProducts':'rechargeNoProducts')),findsOneWidget);
    }
  });
}
