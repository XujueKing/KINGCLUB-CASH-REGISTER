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
  test('unpaid closure resolves original request without claiming payment or refund',(){
    for(final channel in ['wechat','alipay']) {
      final command=ProviderPayment.create(staff.session(),'D00000000001',channel,100);
      final closed={'storeRef':command.params['storeRef'],'orderRef':command.params['orderRef'],
        'intentRef':'00000000-0000-4000-8000-000000000001','requestId':command.requestId,
        'channel':channel,'totalCents':100,'currency':'CNY','closedBy':command.query.employeeRef,'closureStatus':'closed_unpaid'};
      dynamic response(Map<String,dynamic> r)=>{'result':{'state':'closed_unpaid','requestId':command.requestId,'receipt':r}};
      final result=ProviderPaymentResult.parse(response(closed),command);
      expect(result.resolved,isTrue);expect(result.closedUnpaid,isTrue);
      expect(result.confirmed,isFalse);expect(result.refunded,isFalse);
      for(final patch in [{'totalCents':101},{'closedBy':'E00000000002'},{'orderRef':'D00000000002'},
        {'requestId':'other'},{'channel':'member_balance'},{'closureStatus':'confirmed'},{'extra':true}]) {
        expect(()=>ProviderPaymentResult.parse(response({...closed,...patch}),command),throwsA(anything));
      }
    }
  });

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
