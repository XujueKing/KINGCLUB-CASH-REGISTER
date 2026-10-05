import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/auth/staff_access_page.dart';
import 'package:kingclub_cash_register/src/auth/staff_auth_controller.dart';
import 'package:kingclub_cash_register/src/auth/staff_session.dart';
import 'package:kingclub_cash_register/src/workbench_page.dart';
import 'live_tables_panel_test.dart' show TableAuth;
class RefreshAuth extends StaffAuthController {
 final fixture=TableAuth();
 StaffSession? value;bool refreshing=false;
 RefreshAuth(){value=fixture.session;}
 @override StaffSession? get session=>value;
 @override bool get busy=>refreshing;
 @override Future<void> restore() async {}
 @override Future<Object?> readWorkbench({String? afterTable})=>fixture.readWorkbench(afterTable:afterTable);
 void begin(){refreshing=true;value=null;notifyListeners();}
 void finish(){value=TableAuth().session;refreshing=false;notifyListeners();}
 void revoke(){value=null;refreshing=false;notifyListeners();}
}
void main(){testWidgets('credential refresh preserves workspace state; revocation removes it',(tester)async{
 tester.view.physicalSize=const Size(1366,768);tester.view.devicePixelRatio=1;
 addTearDown(tester.view.resetPhysicalSize);addTearDown(tester.view.resetDevicePixelRatio);
 final auth=RefreshAuth();
 await tester.pumpWidget(MaterialApp(home:StaffAccessPage(controller:auth)));await tester.pumpAndSettle();
 final state=tester.state(find.byType(WorkbenchPage));
 auth.begin();await tester.pump();expect(tester.state(find.byType(WorkbenchPage)),same(state));
 auth.finish();await tester.pumpAndSettle();expect(tester.state(find.byType(WorkbenchPage)),same(state));
 auth.revoke();await tester.pump();expect(find.byType(WorkbenchPage),findsNothing);
 await tester.pumpWidget(const SizedBox());auth.dispose();
});}
