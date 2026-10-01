import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/auth/session_vault.dart';
import 'package:kingclub_cash_register/src/auth/staff_auth_controller.dart';
import 'package:kingclub_cash_register/src/live/provider_payment.dart';
import 'staff_session_test.dart' as staff;
class CloseApi extends staff.TestApi {
  bool invalid=false;
  @override Future<Object?> call(String id,Map<String,dynamic> p)async{
    expect(id,'K260930001949');
    return {'result':{'state':'closed_unpaid','requestId':p['requestId'],'receipt':{
      'storeRef':p['storeRef'],'orderRef':p['orderRef'],'requestId':p['requestId'],
      'intentRef':'00000000-0000-4000-8000-000000000001','channel':p['channel'],
      'totalCents':invalid?101:p['expectedTotalCents'],'currency':'CNY','closedBy':'E00000000001','closureStatus':'closed_unpaid',
    }}};
  }
}
void main(){
  for(final invalid in [false,true]){
    test('unpaid closure journal acknowledgement requires exact proof invalid=$invalid',()async{
      final storage=staff.TestStorage();storage.data[SessionVault.deviceKey]=staff.device;
      final api=CloseApi()..invalid=invalid;
      final login=staff.TestAuth()..result={...staff.response(),'permissions':['workbench.read','payment.wechat']};
      final journal=ProviderPaymentJournal(storage:storage);
      final auth=StaffAuthController(vault:SessionVault(storage:storage),providerJournal:journal,
        authFactory:(_)=>login,sessionFactory:(_)=>api,now:()=>staff.now);
      addTearDown(auth.dispose);await staff.login(auth);
      final command=ProviderPayment.create(auth.session!,'D00000000001','wechat',100);
      await journal.save(auth.session!,command);
      if(invalid){
        await expectLater(auth.queryProvider(command),throwsA(anything));
        expect((await journal.load(auth.session!)).single.requestId,command.requestId);
      }else{
        final result=await auth.queryProvider(command);
        expect(result.closedUnpaid,isTrue);expect(result.confirmed,isFalse);
        expect(await journal.load(auth.session!),isEmpty);
      }
    });
  }
}
