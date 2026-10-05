import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/live/checkout_scan.dart';

void main() {
  test(
    'detects provider and member payment codes, without identity-code debits',
    () {
      expect(checkoutScanChannel('130000000000000000'), 'wechat');
      expect(checkoutScanChannel('280000000000000000'), 'alipay');
      expect(checkoutScanChannel('KCPAY1:${'a' * 43}'), 'store_balance');
      expect(
        checkoutScanChannel('KCPAY1:${'a' * 43}', platformBalance: true),
        'platform_cash',
      );
      for (final code in [
        'KC:M:${'A' * 32}',
        'KC:W:${'A' * 32}',
        'KM00000000001',
        '',
        'https://example.com',
      ]) {
        expect(checkoutScanChannel(code), isNull);
      }
    },
  );
}
