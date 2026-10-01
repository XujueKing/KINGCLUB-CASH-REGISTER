import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/auth/session_vault.dart';
import 'package:kingclub_cash_register/src/network/ccsop_client.dart';
import 'staff_session_test.dart' as staff;

class RetryAuth extends staff.TestAuth {
  bool offline=true;
  bool uncertain=false;
  @override Future<Map<String,dynamic>> call(String id,Map<String,dynamic> params) async {
    if(offline)throw CcsopFailure('TRANSPORT_FAILED',deliveryUncertain:uncertain);
    return super.call(id,params);
  }
}
void main(){
  test('proven unsent refresh retains encrypted credential but exposes no offline identity',() async {
    final storage=staff.TestStorage()..data[SessionVault.deviceKey]=staff.device;
    storage.data[SessionVault.sessionKey]=staff.session().encodeForSecureStorage();
    final auth=RetryAuth(),controller=staff.controller(storage,auth,staff.TestApi());
    await expectLater(controller.restore(),throwsA(isA<CcsopFailure>()));
    expect(controller.session,isNull);expect(controller.canRetryRestore,true);
    expect(storage.data.containsKey(SessionVault.sessionKey),true);
    auth.offline=false;await controller.restore();
    expect(controller.session?.employeeRef,staff.session().employeeRef);expect(controller.canRetryRestore,false);
    controller.dispose();
  });
  test('ambiguous refresh still removes old token and requires login',() async {
    final storage=staff.TestStorage()..data[SessionVault.deviceKey]=staff.device;
    storage.data[SessionVault.sessionKey]=staff.session().encodeForSecureStorage();
    final controller=staff.controller(storage,RetryAuth()..uncertain=true,staff.TestApi());
    await expectLater(controller.restore(),throwsA(isA<CcsopFailure>()));
    expect(controller.canRetryRestore,false);expect(storage.data.containsKey(SessionVault.sessionKey),false);
    controller.dispose();
  });
  test('logout removes retained retry credential',() async {
    final storage=staff.TestStorage()..data[SessionVault.deviceKey]=staff.device;
    storage.data[SessionVault.sessionKey]=staff.session().encodeForSecureStorage();
    final controller=staff.controller(storage,RetryAuth(),staff.TestApi());
    await expectLater(controller.restore(),throwsA(isA<CcsopFailure>()));
    await controller.logout();expect(controller.canRetryRestore,false);expect(storage.data.containsKey(SessionVault.sessionKey),false);
    controller.dispose();
  });
}
