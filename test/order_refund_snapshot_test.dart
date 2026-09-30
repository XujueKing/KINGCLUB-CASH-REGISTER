import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/live/order_snapshot.dart';

Map<String, dynamic> fixture() => {
  'refundRef': '00000000-0000-4000-8000-000000000001',
  'accountType': 'store_balance',
  'totalCents': 1200,
  'principalCents': 1000,
  'giftCents': 200,
  'refundedAt': '2026-09-30T00:00:00.000Z',
};
void main() {
  test('refund principal and gifts remain separate', () {
    final value = OrderRefund(fixture());
    expect(value.principalCents, 1000);
    expect(value.giftCents, 200);
  });
  test('rejects contradictory amount, account, date and extra fields', () {
    for (final patch in <Map<String, dynamic>>[
      {'totalCents': 1199},
      {'accountType': 'platform_cash'},
      {'giftCents': -1},
      {'accountType': 'other'},
      {'refundedAt': 'yesterday'},
      {'extra': true},
    ]) {
      expect(
        () => OrderRefund({...fixture(), ...patch}),
        throwsFormatException,
      );
    }
  });
}
