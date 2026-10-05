import 'provider_payment.dart';

/// Detection is local; authorization and the amount remain server-owned.
/// Identity codes are deliberately not payment authorization.
String? checkoutScanChannel(String code, {bool platformBalance = false}) {
  final value = code.trim();
  if (validProviderCode('wechat', value)) return 'wechat';
  if (validProviderCode('alipay', value)) return 'alipay';
  if (validProviderCode('member_balance', value)) {
    return platformBalance ? 'platform_cash' : 'store_balance';
  }
  return null;
}
