import 'package:flutter_test/flutter_test.dart';

import 'package:kingclub_cash_register/src/live/balance_refund_context.dart';

Map<String, dynamic> fixture() => {
  'state': 'ready',
  'storeRef': 'TEST_STORE',
  'orderRef': 'D00000000001',
  'originalIntentRef': '00000000-0000-4000-8000-000000000001',
  'accountType': 'store_balance',
  'currency': 'CNY',
  'totalCents': 100,
  'principalCents': 80,
  'giftCents': 20,
  'lines': [
    {'productRef': 'TEST_PRODUCT', 'quantity': 2, 'servedQuantity': 1},
  ],
  'sources': [
    {
      'originalMovementRef': 'M00000000001',
      'productRef': 'TEST_PRODUCT',
      'batchRef': 'TEST_BATCH',
      'issuedQuantity': 2,
    },
  ],
};
BalanceRefundContext parse(Object? value) => BalanceRefundContext.parse(
  value,
  expectedStore: 'TEST_STORE',
  expectedOrder: 'D00000000001',
);
void main() {
  test(
    'preserves account split and original sources without choosing returns',
    () {
      final context = parse(fixture());
      expect(context.accountType, 'store_balance');
      expect(context.principalCents, 80);
      expect(context.giftCents, 20);
      expect(context.sources.single.issuedQuantity, 2);
      expect(context.lines.single.servedQuantity, 1);
      expect(() => context.sources.clear(), throwsUnsupportedError);
      expect(context.alreadyRefunded, isFalse);
    },
  );
  test('already refunded has no new refundable amounts', () {
    final context = parse({
      'state': 'already_refunded',
      'storeRef': 'TEST_STORE',
      'orderRef': 'D00000000001',
      'refundRef': '00000000-0000-4000-8000-000000000002',
    });
    expect(context.alreadyRefunded, isTrue);
    expect(context.totalCents, isNull);
    expect(context.sources, isEmpty);
  });
  for (final kind in [
    'store',
    'order',
    'split',
    'platformGift',
    'quantity',
    'served',
    'duplicate',
    'identity',
  ]) {
    test('rejects $kind mismatch', () {
      final value = fixture();
      switch (kind) {
        case 'store':
          value['storeRef'] = 'OTHER_STORE';
          break;
        case 'order':
          value['orderRef'] = 'D00000000002';
          break;
        case 'split':
          value['principalCents'] = 90;
          break;
        case 'platformGift':
          value['accountType'] = 'platform_cash';
          break;
        case 'quantity':
          (value['sources'] as List).first['issuedQuantity'] = 1;
          break;
        case 'served':
          (value['lines'] as List).first['servedQuantity'] = 3;
          break;
        case 'duplicate':
          (value['sources'] as List).add((value['sources'] as List).first);
          break;
        case 'identity':
          value['userAccount'] = 'TEST_MEMBER';
          break;
      }
      expect(() => parse(value), throwsFormatException);
    });
  }
}
