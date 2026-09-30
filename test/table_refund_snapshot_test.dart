import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/live/table_snapshot.dart';

Map<String, dynamic> fixture() => {
  'sessionRef': 'H00000000001',
  'status': 'open',
  'paymentTiming': 'prepay',
  'businessDate': '2026-09-30',
  'partySize': 2,
  'partyRevision': 1,
  'elapsedMinutes': 5,
  'paidCents': 7000,
  'paidOrders': 1,
  'pendingCents': 0,
  'pendingOrders': 0,
};
void main() {
  test('historical payload without refund fields remains readable', () {
    final value = TableSessionSnapshot(fixture());
    expect(value.refundedOrders, 0);
    expect(value.refundedCents, 0);
  });
  test('shows separate refund total without adding it back to net paid', () {
    final value = TableSessionSnapshot({
      ...fixture(),
      'refundedOrders': 1,
      'refundedCents': 5000,
    });
    expect(value.paidCents, 7000);
    expect(value.refundedCents, 5000);
    expect(value.refundedOrders, 1);
  });
  test('rejects partial or inconsistent refund fields', () {
    for (final patch in <Map<String, dynamic>>[
      {'refundedOrders': 1},
      {'refundedCents': 100},
      {'refundedOrders': 0, 'refundedCents': 100},
      {'refundedOrders': 2, 'refundedCents': 1},
      {'refundedOrders': '1', 'refundedCents': 100},
      {'refundedOrders': 1, 'refundedCents': -1},
    ]) {
      expect(
        () => TableSessionSnapshot({...fixture(), ...patch}),
        throwsFormatException,
      );
    }
  });
}
