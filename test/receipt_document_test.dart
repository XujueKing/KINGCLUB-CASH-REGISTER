import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/live/receipt_document.dart';
import 'package:kingclub_cash_register/src/network/ccsop_client.dart';

Map<String, dynamic> document({String channel = 'cash', bool refund = false}) => {
  'version': 1, 'documentType': 'cashier_order_receipt', 'storeRef': 'TEST_STORE',
  'tableRef': 'TEST_TABLE', 'sessionRef': 'TEST_SESSION', 'orderRef': 'D00000000001', 'currency': 'CNY',
  'createdAt': '2026-09-30T00:00:00.000Z', 'confirmedAt': '2026-09-30T00:01:00.000Z', 'observedAt': '2026-09-30T00:03:00.000Z',
  'status': refund ? 'refunded' : 'paid', 'totalCents': 100, 'refundedCents': refund ? 100 : 0, 'netPaidCents': refund ? 0 : 100,
  'tender': {'channel': channel,
    if (channel == 'cash') ...{'receivedCents': 150, 'changeCents': 50},
    if (channel == 'member_balance') ...{'accountType': 'store_balance', 'principalCents': 80, 'giftCents': 20}},
  'items': [{'productRef': 'TEST_PRODUCT', 'quantity': 2, 'priceCents': 50, 'subtotalCents': 100, 'revision': 1,
    'names': {'zh-CN': '测试', 'en': 'TEST', 'zh-TW': '測試', 'th': 'ทดสอบ'},
    'specifications': {'zh-CN': '标准', 'en': 'SPEC', 'zh-TW': '標準', 'th': 'มาตรฐาน'}}],
  'refund': refund ? {'refundRef': '00000000-0000-4000-8000-000000000001', 'refundedAt': '2026-09-30T00:02:00.000Z',
    'accountType': 'store_balance', 'principalCents': 80, 'giftCents': 20} : null,
};
ReceiptDocument parse(Map<String, dynamic> row) => ReceiptDocument.parse({'result': row}, storeRef: 'TEST_STORE', orderRef: 'D00000000001');
void main() {
  for (final channel in ['cash','wechat','alipay','member_balance']) {
    test('parses $channel without combining accounts and detaches immutable snapshot', () {
      final row = document(channel: channel), result = parse(row);
      expect(result.totalCents, 100); expect(result.netPaidCents, 100);
      expect(result.refunded, isFalse); expect(result.channel, channel);
      row['items'][0]['names']['en'] = 'CHANGED';
      expect(result.items.single.names[1], 'TEST');
      expect(() => result.items.clear(), throwsUnsupportedError);
      expect(() => result.items.single.names[0] = 'CHANGED', throwsUnsupportedError);
    });
  }
  test('refund preserves original principal/gift and reports net zero', () {
    final result = parse(document(channel: 'member_balance', refund: true));
    expect(result.refunded, isTrue); expect(result.refundedCents, 100); expect(result.netPaidCents, 0);
    expect(result.principalCents, 80); expect(result.giftCents, 20);
  });
  test('platform cash cannot contain store gift value', () {
    final row = document(channel: 'member_balance');
    row['tender']['accountType'] = 'platform_cash';
    expect(() => parse(row), throwsA(isA<CcsopFailure>()));
    row['tender']['principalCents'] = 100; row['tender']['giftCents'] = 0;
    expect(parse(row).accountType, 'platform_cash');
  });
  test('rejects stale scope, malformed amounts, extra fields and misleading text', () {
    final mutations = <void Function(Map<String,dynamic>)>[
      (r) => r['storeRef'] = 'OTHER', (r) => r['orderRef'] = 'D00000000002',
      (r) => r['version'] = 1.0, (r) => r['totalCents'] = 100.0,
      (r) => r['items'][0]['quantity'] = 3, (r) => r['items'].add(r['items'][0]),
      (r) => r['tender']['changeCents'] = 49, (r) => r['tender']['paymentCode'] = 'TEST_ONLY',
      (r) => r['userAccount'] = 'TEST_ONLY', (r) => r['status'] = 'pending',
      (r) => r['items'][0]['names']['en'] = '\u001b@', (r) => r['items'][0]['names']['en'] = '\u202eTEST',
      (r) => r['observedAt'] = '2026-02-30T00:00:00.000Z', (r) => r['confirmedAt'] = '2026-09-29T00:01:00.000Z',
    ];
    for (final mutate in mutations) {
      final row = document(); mutate(row);
      expect(() => parse(row), throwsA(isA<CcsopFailure>()));
    }
  });
  test('refund must match original account, amounts and timeline', () {
    for (final patch in [{'accountType': 'platform_cash'}, {'principalCents': 100, 'giftCents': 0},
      {'refundRef': 'bad'}, {'refundedAt': '2026-09-30T00:04:00.000Z'}]) {
      final row = document(channel: 'member_balance', refund: true);
      row['refund'].addAll(patch);
      expect(() => parse(row), throwsA(isA<CcsopFailure>()));
    }
    expect(() => parse(document(refund: true)), throwsA(isA<CcsopFailure>()));
  });
}
