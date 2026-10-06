import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/live/order_snapshot.dart';
import 'package:kingclub_cash_register/src/live/refund_funding.dart';
import 'package:kingclub_cash_register/src/strings.dart';

Map<String, dynamic> fundingFixture(int quantity) => {
  'version': 1,
  'originalTotalCents': 1200,
  'previousGrossCents': 0,
  'grossCents': 600 * quantity,
  'externalOriginalCents': 600,
  'externalCents': 300 * quantity,
  'platformCashCents': 100 * quantity,
  'coins': 0,
  'storeOriginalCents': 300,
  'storePreviousCents': 0,
  'storeCents': 150 * quantity,
  'storePrincipalCents': 100 * quantity,
  'storeGiftCents': 50 * quantity,
  'couponDiscountCents': 50 * quantity,
  'restoreCoupon': quantity == 2 ? 1 : 0,
  'fingerprint': List.filled(64, '$quantity').join(),
};

void main() {
  test('mixed history separates goods, returned money and coupon value', () {
    final receipt = OrderRefund({
      'refundRef': '00000000-0000-4000-8000-000000000001',
      'accountType': 'mixed',
      'totalCents': 600,
      'principalCents': 500,
      'giftCents': 50,
      'refundedAt': '2026-10-07T00:00:00.000Z',
      'funding': fundingFixture(1),
    });
    expect(receipt.funding!.principal, 500);
    expect(receipt.funding!.restoreCoupon, false);
    expect(RefundFunding(fundingFixture(2)).restoreCoupon, true);
    expect(receipt.funding!.lines(UiLanguage.en).join(' '), contains('WeChat'));
    expect(
      () => RefundFunding({...fundingFixture(1), 'restoreCoupon': 1}),
      throwsFormatException,
    );
    expect(
      () => RefundFunding({...fundingFixture(1), 'storeGiftCents': 51}),
      throwsFormatException,
    );
  });
}
