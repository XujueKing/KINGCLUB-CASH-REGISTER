import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/live/table_checkout_command.dart';
import 'package:kingclub_cash_register/src/network/ccsop_client.dart';

import 'staff_session_test.dart' as staff;

Map<String, dynamic> tableQuoteFixture() => {
  'result': {
    'version': 1,
    'state': 'quote',
    'storeRef': 'test-store',
    'tableRef': 'TEST_TABLE',
    'sessionRef': 'TEST_SESSION',
    'channel': 'member_balance',
    'accountType': 'store_balance',
    'currency': 'CNY',
    'quotedAt': '2026-09-30T00:00:00.000Z',
    'totalCents': 300,
    'orderCount': 2,
    'snapshotFingerprint': 'a' * 64,
    'allocations': [
      for (var n = 1; n <= 2; n++)
        {
          'orderRef': 'D0000000000$n',
          'totalCents': n * 100,
          'inventoryAction': 'issue_reserved',
        },
    ],
    'lines': [
      for (var n = 1; n <= 2; n++)
        {
          'orderRef': 'D0000000000$n',
          'productRef': 'TEST_PRODUCT',
          'quantity': n,
          'priceCents': 100,
          'names': {
            'zh-CN': '测试商品',
            'en': 'Test item',
            'zh-TW': '測試商品',
            'th': 'สินค้าทดสอบ',
          },
          'specifications': {
            'zh-CN': '瓶',
            'en': 'Bottle',
            'zh-TW': '瓶',
            'th': 'ขวด',
          },
          'revision': 1,
        },
    ],
  },
};
TableCheckoutQuote parseQuote(Object? raw) => TableCheckoutQuote.parse(
  raw,
  storeRef: 'test-store',
  tableRef: 'TEST_TABLE',
  sessionRef: 'TEST_SESSION',
  channel: 'member_balance',
  accountType: 'store_balance',
);
TableCheckoutCommand command() => TableCheckoutCommand.fromQuote(
  staff.session(),
  parseQuote(tableQuoteFixture()),
  requestId: '00000000-0000-4000-8000-000000000099',
);
void main() {
  test(
    'original localized line snapshots are required and reject control text',
    () {
      final parsed = parseQuote(tableQuoteFixture());
      expect(parsed.linesByOrder['D00000000001']!.single.names.first, '测试商品');
      expect(() => parsed.linesByOrder.clear(), throwsUnsupportedError);
      expect(() => parsed.lines.first.names.clear(), throwsUnsupportedError);
      for (final reason in ['missing', 'control', 'revision']) {
        final raw = tableQuoteFixture(),
            line = ((raw['result'] as Map)['lines'] as List).first as Map;
        if (reason == 'missing') line.remove('names');
        if (reason == 'control') (line['names'] as Map)['zh-CN'] = 'bad\u001b';
        if (reason == 'revision') line['revision'] = 0;
        expect(() => parseQuote(raw), throwsA(isA<CcsopFailure>()));
      }
    },
  );
  test(
    'keeps one account and immutable allocations across repeated products',
    () {
      final q = parseQuote(tableQuoteFixture());
      expect(q.totalCents, 300);
      expect(q.accountType, 'store_balance');
      expect(() => q.lines.clear(), throwsUnsupportedError);
      expect(() => q.allocations.clear(), throwsUnsupportedError);
      final c = command();
      expect(TableCheckoutCommand.decode(c.encoded).encoded, c.encoded);
      expect(c.params.containsKey('orderCount'), false);
      expect(c.permission, 'payment.balance');
    },
  );
  for (final field in [
    'storeRef',
    'accountType',
    'currency',
    'version',
    'totalCents',
    'orderCount',
    'snapshotFingerprint',
    'quotedAt',
  ]) {
    test('rejects corrupted quote $field', () {
      final raw = tableQuoteFixture();
      (raw['result'] as Map)[field] = 'wrong';
      expect(() => parseQuote(raw), throwsA(isA<CcsopFailure>()));
    });
  }
  test(
    'rejects duplicate lines, foreign orders and missing allocated lines',
    () {
      for (final reason in ['duplicate', 'foreign', 'missing']) {
        final raw = tableQuoteFixture(),
            lines = (raw['result'] as Map)['lines'] as List;
        if (reason == 'duplicate') lines.add(lines.first);
        if (reason == 'foreign') {
          (lines.first as Map)['orderRef'] = 'D00000000009';
        }
        if (reason == 'missing') lines.removeLast();
        expect(() => parseQuote(raw), throwsA(isA<CcsopFailure>()));
      }
    },
  );
  test('persistent command excludes secrets and rejects account or scope corruption', () {
    for (final patch in <String, dynamic>{
      'paymentCode': 'SECRET',
      'accountType': null,
      'base': 'http://service.invalid',
      'requestId': 'wrong',
      'expectedTotalCents': 0,
    }.entries) {
      expect(
        () => TableCheckoutCommand.decode({
          ...command().encoded,
          patch.key: patch.value,
        }),
        throwsA(isA<CcsopFailure>()),
      );
    }
  });
}
