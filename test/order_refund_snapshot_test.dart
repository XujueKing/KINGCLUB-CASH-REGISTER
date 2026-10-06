import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/live/order_snapshot.dart';

import 'support/order_fixture.dart';

Map<String, dynamic> fixture() => {
  'refundRef': '00000000-0000-4000-8000-000000000001',
  'accountType': 'store_balance',
  'totalCents': 1200,
  'principalCents': 1000,
  'giftCents': 200,
  'refundedAt': '2026-09-30T00:00:00.000Z',
};
void main() {
  test('table-paid APP orders retain WeChat refund quantities without pretending to be wallet refunds', () {
    final raw = orderFixture();
    final order = ((raw['result'] as Map)['orders'] as List).first as Map<String,dynamic>;
    final item = Map<String,dynamic>.from((order['items'] as List).first);
    final value = LiveOrder({...order, 'status':'paid','cashierOrder':false,
      'refunds':[{...fixture(),'accountType':'wechat','totalCents':600,'principalCents':600,'giftCents':0}],
      'items':[{...item,'refundedQuantity':1,'remainingQuantity':1}]});
    expect(value.netPaidCents,600);expect(value.items.single.quantity,2);
    expect(value.items.single.activeQuantity,1);expect(value.refunds.single.accountType,'wechat');
    expect(() => OrderRefund({...fixture(),'accountType':'wechat'}),throwsFormatException);
  });
  LiveOrder orderWithRefunds(List<Map<String, dynamic>> receipts) {
    final raw = orderFixture();
    final order =
        ((raw['result'] as Map)['orders'] as List).first
            as Map<String, dynamic>;
    return LiveOrder({
      ...order,
      'status': 'paid',
      'cashierOrder': true,
      'refunds': receipts,
    });
  }

  test('partial receipt history preserves original items and remaining paid amount', () {
    final receipt = {
      ...fixture(),
      'totalCents': 300,
      'principalCents': 200,
      'giftCents': 100,
    };
    final original = orderWithRefunds([]);
    final partial = orderWithRefunds([receipt]);
    expect(partial.totalCents, original.totalCents);
    expect(partial.items.single.quantity, original.items.single.quantity);
    expect(partial.netPaidCents, original.totalCents - 300);
    expect(partial.fullyRefunded, false);
    final remainder = original.totalCents - 300;
    final full = orderWithRefunds([
      receipt,
      {
        ...fixture(),
        'refundRef': '00000000-0000-4000-8000-000000000002',
        'totalCents': remainder,
        'principalCents': remainder,
        'giftCents': 0,
      },
    ]);
    expect(full.fullyRefunded, true);
    expect(full.netPaidCents, 0);
    expect(full.refund, isNull);
    expect(() => orderWithRefunds([receipt, receipt]), throwsFormatException);
    expect(
      () => orderWithRefunds([
        receipt,
        {
          ...receipt,
          'refundRef': '00000000-0000-4000-8000-000000000002',
          'accountType': 'platform_cash',
          'principalCents': 300,
          'giftCents': 0,
        },
      ]),
      throwsFormatException,
    );
    expect(
      () => orderWithRefunds([
        {
          ...receipt,
          'totalCents': original.totalCents + 1,
          'principalCents': original.totalCents + 1,
          'giftCents': 0,
        },
      ]),
      throwsFormatException,
    );
  });
  test('partial refunds preserve remaining net paid orders', () {
    final data = <String, dynamic>{
      'currency': 'CNY',
      'paid': {'orderCount': 1, 'totalCents': 300},
      'pending': {'orderCount': 0, 'totalCents': 0},
      'expired': {'orderCount': 0, 'totalCents': 0},
      'refunded': {'orderCount': 1, 'totalCents': 100},
      'netPaid': {'orderCount': 1, 'totalCents': 200},
      'fullyRefundedOrderCount': 0,
    };
    expect(
      SessionOrderSummary.parse(data, []).buckets['netPaid']!.totalCents,
      200,
    );
    for (final invalid in [-1, 1, 2, null, '0']) {
      expect(
        () => SessionOrderSummary.parse({
          ...data,
          'fullyRefundedOrderCount': invalid,
        }, []),
        throwsFormatException,
      );
    }
    expect(
      () => SessionOrderSummary.parse(
        {...data}..remove('fullyRefundedOrderCount'),
        [],
      ),
      throwsFormatException,
    );
  });
  test('refund principal and gifts remain separate', () {
    final value = OrderRefund(fixture());
    expect(value.principalCents, 1000);
    expect(value.giftCents, 200);
  });
  test('rejects contradictory amount, account, date and extra fields', () {
    for (final patch in <Map<String, dynamic>>[
      {'totalCents': 1199},
      {'accountType': 'platform_cash'},
      {'giftCents': -1},
      {'accountType': 'other'},
      {'refundedAt': 'yesterday'},
      {'extra': true},
    ]) {
      expect(
        () => OrderRefund({...fixture(), ...patch}),
        throwsFormatException,
      );
    }
  });
}
