import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/live/recharge_result.dart';

const ref = '00000000-0000-4000-8000-000000000001';
Map<String, dynamic> fixture() => {'result': {'state': 'credited', 'rechargeRef': ref,
  'receipt': {'version': 1, 'rechargeRef': ref, 'storeRef': 'TEST_STORE', 'userAccount': 'TEST_MEMBER',
    'currency': 'CNY', 'accountType': 'store_balance', 'lotRef': '00000000-0000-4000-8000-000000000002',
    'principalCents': '10000', 'giftCents': '2000', 'creditedAt': '2026-09-30T00:00:00.000Z'}}};
void main() {
  test('separates principal and gift and omits member identity from projection', () {
    final result = RechargeResult.parse(fixture(), storeRef: 'TEST_STORE', rechargeRef: ref, expectedPrincipalCents: 10000);
    expect(result.credited, isTrue); expect(result.principalCents, 10000); expect(result.giftCents, 2000);
  });
  test('non-credit states never become spendable success', () {
    for (final state in ['not_sent','pending','unknown','review_required','credit_pending']) {
      final result = RechargeResult.parse({'result': {'state': state, 'rechargeRef': ref}}, storeRef: 'TEST_STORE', rechargeRef: ref);
      expect(result.credited, isFalse); expect(result.principalCents, isNull);
    }
  });
  test('rejects wrong scope, account, amount, malformed dates and extra fields', () {
    for (final change in <String, dynamic>{'storeRef':'OTHER_STORE', 'accountType':'platform_cash',
      'principalCents':'12000', 'giftCents':'-1', 'creditedAt':'2026-02-30T00:00:00.000Z', 'extra':'TEST'}.entries) {
      final raw = fixture();
      (raw['result']['receipt'] as Map<String, dynamic>)[change.key] = change.value;
      expect(() => RechargeResult.parse(raw, storeRef: 'TEST_STORE', rechargeRef: ref, expectedPrincipalCents: 10000), throwsA(anything));
    }
  });
}
