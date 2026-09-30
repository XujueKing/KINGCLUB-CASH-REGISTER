import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/live/recharge_journal.dart';
import 'package:kingclub_cash_register/src/live/recharge_result.dart';
import 'staff_session_test.dart' as staff;

const reference = '00000000-0000-4000-8000-000000000010';
void main() {
  test('writes frozen scope without payer code, restores, blocks duplicate original', () async {
    final storage=staff.TestStorage(),journal=RechargeJournal(storage:storage),identity=staff.session();
    final command=RechargeCommand.forSession(identity,rechargeRef:reference,channel:'wechat',principalCents:10000);
    await journal.save(identity,command);
    final restored=await RechargeJournal(storage:storage).load(identity);
    expect(restored.single.encoded,command.encoded);
    expect(storage.data[RechargeJournal.key],isNot(contains('authCode')));
    await expectLater(journal.save(identity,command),throwsA(anything));
    final other=staff.session({...staff.response(),'employee':{'employeeRef':'E00000000002','displayName':'TEST OTHER'}});
    expect(await journal.load(other),isEmpty);
    final second=RechargeCommand.forSession(other,rechargeRef:reference,channel:'wechat',principalCents:10000);
    await expectLater(journal.save(other,second),throwsA(anything));
  });
  test('keeps ambiguous or paid-pending rows, removes only matching credit', () async {
    final storage=staff.TestStorage(),journal=RechargeJournal(storage:storage),identity=staff.session();
    final command=RechargeCommand.forSession(identity,rechargeRef:reference,channel:'wechat',principalCents:10000);
    await journal.save(identity,command);
    for(final state in ['not_sent','unknown','credit_pending','review_required']) {
      final result=RechargeResult.parse({'result':{'state':state,'rechargeRef':reference}},storeRef:'test-store',rechargeRef:reference);
      await expectLater(journal.acknowledge(identity,command,result),throwsA(anything));
      expect(await journal.load(identity),hasLength(1));
    }
    final result=RechargeResult.parse({'result':{'state':'credited','rechargeRef':reference,'receipt':{
      'version':1,'rechargeRef':reference,'storeRef':'test-store','userAccount':'TEST_MEMBER','currency':'CNY',
      'accountType':'store_balance','lotRef':'00000000-0000-4000-8000-000000000011',
      'principalCents':'10000','giftCents':'2000','creditedAt':'2026-09-30T00:00:00.000Z'}}},storeRef:'test-store',rechargeRef:reference);
    await journal.acknowledge(identity,command,result);expect(await journal.load(identity),isEmpty);
  });
  test('fails closed on corrupt entries or extra secret field', () async {
    final storage=staff.TestStorage(),journal=RechargeJournal(storage:storage),identity=staff.session();
    final command=RechargeCommand.forSession(identity,rechargeRef:reference,channel:'wechat',principalCents:10000);
    storage.data[RechargeJournal.key]=jsonEncode([{...command.encoded,'authCode':'TEST_NOT_REAL'}]);
    await expectLater(journal.load(identity),throwsA(anything));
    storage.fail=true;await expectLater(journal.save(identity,command),throwsA(anything));
  });
}
