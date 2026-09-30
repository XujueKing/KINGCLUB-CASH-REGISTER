import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/live/receipt_document.dart';
import 'package:kingclub_cash_register/src/network/ccsop_client.dart';
import 'package:kingclub_cash_register/src/strings.dart';

const checkout = '00000000-0000-4000-8000-000000000001';
Map<String, dynamic> tableReceiptFixture() => {
  'result': {
    'version': 1,
    'documentType': 'cashier_table_receipt',
    'checkoutRef': checkout,
    'storeRef': 'TEST_STORE',
    'tableRef': 'TEST_TABLE',
    'sessionRef': 'TEST_SESSION',
    'currency': 'CNY',
    'status': 'paid',
    'totalCents': 300,
    'refundedCents': 0,
    'netPaidCents': 300,
    'createdAt': '2026-09-30T00:00:00.000Z',
    'confirmedAt': '2026-09-30T00:00:01.000Z',
    'settledAt': '2026-09-30T00:00:02.000Z',
    'observedAt': '2026-09-30T00:00:03.000Z',
    'orderCount': 2,
    'tender': {
      'channel': 'member_balance',
      'accountType': 'store_balance',
      'principalCents': 240,
      'giftCents': 60,
    },
    'orders': [
      for (var n = 1; n <= 2; n++)
        {
          'orderRef': 'D0000000000$n',
          'allocatedCents': n * 100,
          'items': [
            {
              'productRef': 'TEST_PRODUCT',
              'quantity': n,
              'priceCents': 100,
              'subtotalCents': n * 100,
              'revision': 1,
              'names': {
                'zh-CN': '测试商品',
                'en': 'Test product',
                'zh-TW': '測試商品',
                'th': 'สินค้าทดสอบ',
              },
              'specifications': {
                'zh-CN': '测试规格',
                'en': 'Test specification',
                'zh-TW': '測試規格',
                'th': 'แบบทดสอบ',
              },
            },
          ],
        },
    ],
  },
};
TableReceiptDocument parse(Map<String, dynamic> raw) =>
    TableReceiptDocument.parse(
      raw,
      storeRef: 'TEST_STORE',
      checkoutRef: checkout,
    );
void main() {
  test(
    'keeps one tender and immutable child allocations with all languages',
    () {
      final document = parse(tableReceiptFixture());
      expect(document.totalCents, 300);
      expect(document.tender.principalCents, 240);
      expect(document.tender.giftCents, 60);
      expect(document.orders.map((o) => o.allocatedCents), [100, 200]);
      for (final language in UiLanguage.values) {
        expect(document.orders.first.items.first.name(language), isNotEmpty);
      }
      expect(() => document.orders.clear(), throwsUnsupportedError);
      expect(() => document.orders.first.items.clear(), throwsUnsupportedError);
      expect(
        () => document.orders.first.items.first.names.clear(),
        throwsUnsupportedError,
      );
    },
  );
  test('shares cash and provider tender validation with ordinary receipts', () {
    for (final tender in [
      {'channel': 'cash', 'receivedCents': 500, 'changeCents': 200},
      {'channel': 'wechat'},
      {'channel': 'alipay'},
      {
        'channel': 'member_balance',
        'accountType': 'platform_cash',
        'principalCents': 300,
        'giftCents': 0,
      },
    ]) {
      final raw = tableReceiptFixture();
      raw['result']['tender'] = tender;
      expect(parse(raw).tender.channel, tender['channel']);
    }
  });
  for (final kind in [
    'scope',
    'parent',
    'count',
    'duplicate',
    'sum',
    'line',
    'time',
    'gift',
    'code',
    'refunded',
    'control',
  ]) {
    test('rejects $kind corruption without interpreting it as success', () {
      final raw = tableReceiptFixture(), row = raw['result'];
      if (kind == 'scope') row['storeRef'] = 'OTHER';
      if (kind == 'parent') {
        row['checkoutRef'] = '00000000-0000-4000-8000-000000000002';
      }
      if (kind == 'count') row['orderCount'] = 1001;
      if (kind == 'duplicate') {
        row['orders'][1]['orderRef'] = row['orders'][0]['orderRef'];
      }
      if (kind == 'sum') row['orders'][0]['allocatedCents'] = 101;
      if (kind == 'line') row['orders'][0]['items'][0]['quantity'] = 2;
      if (kind == 'time') row['settledAt'] = '2026-09-30T00:00:00.000Z';
      if (kind == 'gift') row['tender']['accountType'] = 'platform_cash';
      if (kind == 'code') row['tender']['paymentCode'] = 'TEST_ONLY';
      if (kind == 'refunded') row['status'] = 'refunded';
      if (kind == 'control') {
        row['orders'][0]['items'][0]['names']['en'] = 'Test\u001b@';
      }
      expect(
        () => parse(raw),
        throwsA(
          isA<CcsopFailure>().having(
            (e) => e.code,
            'code',
            'TABLE_RECEIPT_DOCUMENT_INVALID',
          ),
        ),
      );
    });
  }
}
