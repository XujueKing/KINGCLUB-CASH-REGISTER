import '../strings.dart';
import 'table_snapshot.dart';

class RefundFunding {
  RefundFunding(Map<String, dynamic> value) : data = Map.unmodifiable(value) {
    for (final k in [
      'originalTotalCents',
      'previousGrossCents',
      'grossCents',
      'externalOriginalCents',
      'externalCents',
      'platformCashCents',
      'coins',
      'storeOriginalCents',
      'storePreviousCents',
      'storeCents',
      'storeGiftCents',
      'storePrincipalCents',
      'couponDiscountCents',
    ]) {
      if (data[k] is! int || n(k) < 0 || n(k) > 100000000)
        throw const FormatException('REFUND_FUNDING_INVALID');
    }
    if (data['version'] != 1 ||
        data['fingerprint'] is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(fingerprint) ||
        ![true, false, 0, 1].contains(data['restoreCoupon']) ||
        n('grossCents') < 1 ||
        n('previousGrossCents') + n('grossCents') > n('originalTotalCents') ||
        n('externalCents') > n('externalOriginalCents') ||
        n('storePrincipalCents') + n('storeGiftCents') != n('storeCents') ||
        n('storePreviousCents') + n('storeCents') > n('storeOriginalCents') ||
        (restoreCoupon &&
            n('previousGrossCents') + n('grossCents') !=
                n('originalTotalCents')))
      throw const FormatException('REFUND_FUNDING_INVALID');
  }
  final Map<String, dynamic> data;
  int n(String k) => data[k] as int;
  String get fingerprint => data['fingerprint'] as String;
  bool get restoreCoupon =>
      data['restoreCoupon'] == true || data['restoreCoupon'] == 1;
  int get principal =>
      n('externalCents') +
      n('platformCashCents') +
      n('storePrincipalCents') +
      n('coins') * 10;
  List<String> lines(UiLanguage language) {
    String l(String zh, String en, String tw, String th) =>
        [zh, en, tw, th][language.index];
    return [
      for (final row in [
        ['externalCents', l('退回微信', 'WeChat', '退回微信', 'คืน WeChat')],
        [
          'storePrincipalCents',
          l('退回本店本金', 'Store principal', '退回本店本金', 'คืนเงินต้นร้าน'),
        ],
        [
          'storeGiftCents',
          l('退回本店赠送', 'Store gift balance', '退回本店贈送', 'คืนโบนัสร้าน'),
        ],
        [
          'platformCashCents',
          l('退回平台余额', 'Platform balance', '退回平台餘額', 'คืนยอดแพลตฟอร์ม'),
        ],
      ])
        if (n(row[0]) > 0) '${row[1]}  ¥ ${formatCents(n(row[0]))}',
      if (n('coins') > 0)
        '${l('退回金币', 'Coins returned', '退回金幣', 'คืนเหรียญ')}  ${n('coins')}',
      l(
        '券抵扣不退现金',
        'Coupon discounts are not cash',
        '券抵扣不退現金',
        'ส่วนลดคูปองไม่คืนเป็นเงินสด',
      ),
      if (restoreCoupon)
        l(
          '整单退完，退回原券（有效期不变）',
          'Full refund returns the coupon with its original expiry',
          '整單退完，退回原券（有效期不變）',
          'คืนคูปองเมื่อคืนครบ วันหมดอายุเดิม',
        ),
    ];
  }
}
