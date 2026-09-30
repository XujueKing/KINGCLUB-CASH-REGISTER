import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/auth/session_vault.dart';
import 'package:kingclub_cash_register/src/auth/staff_auth_controller.dart';
import 'package:kingclub_cash_register/src/live/recharge_journal.dart';
import 'staff_session_test.dart' as staff;

const reference = '00000000-0000-4000-8000-000000000010';
const payerCode = '130000000000000000'; // Synthetic test only.
class RechargeApi extends staff.TestApi {
  final calls = <String>[];
  String state = 'unknown';
  bool creditedAfterSend = false;
  void Function()? onQuery;
  @override
  Future<Object?> call(String id, Map<String,dynamic> params) async {
    calls.add(id);
    if (id == 'K260930001934') {
      expect(params.containsKey('authCode'), isFalse); onQuery?.call();
    } else {
      expect(id, 'K260930001933'); expect(params['authCode'], payerCode);
      if (creditedAfterSend) state = 'credited';
    }
    return {'result': {'state': state, 'rechargeRef': reference, if (state == 'credited') 'receipt': {
      'version': 1, 'rechargeRef': reference, 'storeRef': 'test-store', 'userAccount': 'TEST_MEMBER',
      'currency': 'CNY', 'accountType': 'store_balance', 'lotRef': '00000000-0000-4000-8000-000000000011',
      'principalCents': '10000', 'giftCents': '2000', 'creditedAt': '2026-09-30T00:00:00.000Z'}}};
  }
}
Future<({StaffAuthController auth, RechargeJournal journal, staff.TestStorage storage, RechargeApi api})> fixture() async {
  final storage = staff.TestStorage()..data[SessionVault.deviceKey] = staff.device;
  final journal = RechargeJournal(storage: storage), api = RechargeApi();
  final login = staff.TestAuth()..result = {...staff.response(), 'permissions': ['workbench.read','payment.wechat']};
  final auth = StaffAuthController(vault: SessionVault(storage: storage), rechargeJournal: journal,
    authFactory: (_) => login, sessionFactory: (_) => api, now: () => staff.now);
  addTearDown(auth.dispose); await staff.login(auth);
  return (auth: auth, journal: journal, storage: storage, api: api);
}
void main() {
  test('uncertain initial send retains journal and blocks duplicate initial command', () async {
    final f = await fixture();
    final result = await f.auth.collectRecharge(rechargeRef: reference, channel: 'wechat', principalCents: 10000,
      authCode: payerCode, stillCurrent: () => true);
    expect(result.state, 'unknown'); expect(await f.auth.pendingRecharges('wechat'), hasLength(1));
    expect(jsonEncode(f.storage.data), isNot(contains(payerCode)));
    await expectLater(f.auth.collectRecharge(rechargeRef: reference, channel: 'wechat', principalCents: 10000,
      authCode: payerCode, stillCurrent: () => true), throwsA(anything));
    expect(f.api.calls, ['K260930001933']);
  });
  for (final state in ['unknown','pending','credit_pending','review_required','credited','not_sent']) {
    test('explicit resume from $state sends only if server proves not_sent', () async {
      final f = await fixture();
      final command = RechargeCommand.forSession(f.auth.session!, rechargeRef: reference, channel: 'wechat', principalCents: 10000);
      await f.journal.save(f.auth.session!, command);
      f.api.state = state; f.api.creditedAfterSend = true;
      final result = await f.auth.sendUnsentRecharge(command, authCode: payerCode, stillCurrent: () => true);
      expect(f.api.calls, state == 'not_sent' ? ['K260930001934','K260930001933'] : ['K260930001934']);
      expect(await f.auth.pendingRecharges('wechat'), result.credited ? isEmpty : hasLength(1));
    });
  }
  test('context changed during lookup cannot send', () async {
    final f = await fixture(); var current = true;
    final command = RechargeCommand.forSession(f.auth.session!, rechargeRef: reference, channel: 'wechat', principalCents: 10000);
    await f.journal.save(f.auth.session!, command);
    f.api.state = 'not_sent'; f.api.onQuery = () => current = false;
    await expectLater(f.auth.sendUnsentRecharge(command, authCode: payerCode, stillCurrent: () => current), throwsA(anything));
    expect(f.api.calls, ['K260930001934']); expect(await f.auth.pendingRecharges('wechat'), hasLength(1));
  });
}
