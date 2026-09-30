import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/live/provider_payment.dart';
import 'staff_session_test.dart' as staff;
import 'cash_command_test.dart' show Storage;

Map<String,dynamic> receipt(ProviderPayment command)=>{
  'storeRef':command.params['storeRef'],'orderRef':command.params['orderRef'],
  'intentRef':'00000000-0000-4000-8000-000000000001',
  'paymentRef':'balance:00000000-0000-4000-8000-000000000001',
  'channel':'member_balance','accountType':command.accountType,'userAccount':'TEST_MEMBER',
  'grantRef':'00000000-0000-4000-8000-000000000002','totalCents':100,
  'principalCents':100,'giftCents':0,'currency':'CNY','confirmedBy':command.query.employeeRef,
  'confirmationStatus':'confirmed',
};
void main(){
  test('balance commands require explicit account type and never carry a code',(){
    final identity=staff.session();
    expect(()=>ProviderPayment.create(identity,'D00000000001','member_balance',100),throwsA(anything));
    final command=ProviderPayment.create(identity,'D00000000001','member_balance',100,accountType:'store_balance');
    expect(command.params['accountType'],'store_balance');
    expect(command.params.containsKey('paymentCode'),isFalse);
    expect(()=>ProviderPayment.create(identity,'D00000000001','wechat',100,accountType:'platform_cash'),throwsA(anything));
  });
  test('requires the encrypted interface result envelope and exact account receipt',(){
    final command=ProviderPayment.create(staff.session(),'D00000000001','member_balance',100,accountType:'platform_cash');
    final value={'state':'confirmed','requestId':command.requestId,'receipt':receipt(command)};
    expect(ProviderPaymentResult.parse({'result':value},command).confirmed,isTrue);
    expect(()=>ProviderPaymentResult.parse(value,command),throwsA(anything));
    for(final patch in [
      {'accountType':'store_balance'},{'giftCents':1,'principalCents':99},{'totalCents':100.0},
      {'storeRef':'OTHER'},{'paymentCode':'TEST_ONLY_UNEXPECTED'},
    ]){
      expect(()=>ProviderPaymentResult.parse({'result':{...value,'receipt':{...receipt(command),...patch}}},command),throwsA(anything));
    }
  });
  test('recognizes dedicated member codes, never identity or pickup codes',(){
    expect(validProviderCode('member_balance','KCPAY1:${base64Url.encode(List.filled(32,1)).replaceAll('=', '')}'),isTrue);
    expect(validProviderCode('member_balance','121234567890123456'),isFalse);
    expect(validProviderCode('member_balance','identity:TEST_ONLY'),isFalse);
    expect(validProviderCode('wechat','121234567890123456'),isTrue);
  });
  test('persists exact balance account in the shared journal and blocks another channel for that order',()async{
    final storage=Storage(),identity=staff.session(),journal=ProviderPaymentJournal(storage:storage);
    final command=ProviderPayment.create(identity,'D00000000001','member_balance',100,accountType:'store_balance');
    await journal.save(identity,command);
    final restored=(await ProviderPaymentJournal(storage:storage).load(identity)).single;
    expect(restored.params,command.params);
    await expectLater(journal.save(identity,ProviderPayment.create(identity,'D00000000001','wechat',100)),throwsA(anything));
    await journal.acknowledge(identity,restored);
    expect(await journal.load(identity),isEmpty);
  });
}
