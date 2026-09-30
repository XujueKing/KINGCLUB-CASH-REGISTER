import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/live/order_snapshot.dart';

Map<String, dynamic> fixture() => {
  'currency': 'CNY',
  'paid': {'orderCount': 2, 'totalCents': 300},
  'pending': {'orderCount': 0, 'totalCents': 0},
  'expired': {'orderCount': 0, 'totalCents': 0},
  'refunded': {'orderCount': 1, 'totalCents': 100},
  'netPaid': {'orderCount': 1, 'totalCents': 200},
};
void main() {
  test('retains original paid and independent refund/net buckets', () {
    final value = SessionOrderSummary.parse(fixture(), []);
    expect(value.buckets['paid']!.totalCents, 300);
    expect(value.buckets['refunded']!.totalCents, 100);
    expect(value.buckets['netPaid']!.totalCents, 200);
  });
  test('rejects incomplete or contradictory refund summary', () {
    final missing = fixture()..remove('netPaid');
    expect(() => SessionOrderSummary.parse(missing, []), throwsFormatException);
    final wrong = fixture();
    wrong['netPaid'] = {'orderCount': 1, 'totalCents': 201};
    expect(() => SessionOrderSummary.parse(wrong, []), throwsFormatException);
  });
  test('legacy gross summary does not fabricate a refund bucket', () {
    final raw = fixture()
      ..remove('refunded')
      ..remove('netPaid');
    expect(
      SessionOrderSummary.parse(raw, []).buckets.containsKey('refunded'),
      isFalse,
    );
  });
}
