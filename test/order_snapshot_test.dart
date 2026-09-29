import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/live/order_snapshot.dart';
import 'package:kingclub_cash_register/src/strings.dart';

import 'support/order_fixture.dart';

OrderSnapshot parse(Object? raw, {String? after}) => OrderSnapshot.parse(
  raw,
  storeRef: 'test-store',
  tableRef: 'test-000',
  sessionRef: 'session-0',
  afterOrder: after,
);
void main() {
  Map<String, dynamic> line(Map<String, dynamic> raw) =>
      ((((raw['result'] as Map)['orders'] as List).first as Map)['items']
                  as List)
              .first
          as Map<String, dynamic>;
  test('keeps delivery progress separate from payment and session timing', () {
    final raw = orderFixture();
    line(raw).addAll({'servedQuantity': 1, 'remainingQuantity': 1});
    final result = parse(raw);
    expect(result.paymentTiming, 'prepay');
    expect(result.orders.single.status, 'pending');
    expect(result.orders.single.items.single.servedQuantity, 1);
    expect(result.orders.single.items.single.remainingQuantity, 1);
  });
  test('old server without either count stays unknown rather than zero', () {
    final raw = orderFixture();
    line(raw)
      ..remove('servedQuantity')
      ..remove('remainingQuantity');
    final item = parse(raw).orders.single.items.single;
    expect(item.servingKnown, false);
    expect(item.servedQuantity, isNull);
    expect(item.remainingQuantity, isNull);
  });
  for (final patch in <Map<String, dynamic>>[
    {'servedQuantity': null},
    {'remainingQuantity': null},
    {'servedQuantity': true},
    {'servedQuantity': -1},
    {'servedQuantity': '0'},
    {'servedQuantity': 0.5},
    {'servedQuantity': 3, 'remainingQuantity': 0},
    {'servedQuantity': 1, 'remainingQuantity': 2},
    {'servedQuantity': 1001, 'remainingQuantity': 0},
  ]) {
    test('rejects malformed or inconsistent progress $patch', () {
      final raw = orderFixture();
      line(raw).addAll(patch);
      expect(() => parse(raw), throwsFormatException);
    });
  }
  test(
    'rejects partially missing fields and accepts fully delivered history',
    () {
      for (final field in ['servedQuantity', 'remainingQuantity']) {
        final raw = orderFixture();
        line(raw).remove(field);
        expect(() => parse(raw), throwsFormatException);
      }
      final raw = orderFixture();
      line(raw).addAll({'servedQuantity': 2, 'remainingQuantity': 0});
      ((raw['result'] as Map)['session'] as Map)['status'] = 'closed';
      expect(parse(raw).orders.single.items.single.remainingQuantity, 0);
    },
  );
  test(
    'missing origin is ineligible; only explicit boolean origin is accepted',
    () {
      expect(parse(orderFixture()).orders.single.cashierOrder, false);
      for (final origin in [true, false, null, 1, 'true']) {
        final raw = orderFixture();
        final orders = (raw['result'] as Map)['orders'] as List;
        (raw['result'] as Map)['orders'] = [
          <String, dynamic>{
            ...orders.first as Map<String, dynamic>,
            'cashierOrder': origin,
          },
        ];
        if (origin is bool) {
          expect(parse(raw).orders.single.cashierOrder, origin);
        } else {
          expect(() => parse(raw), throwsFormatException);
        }
      }
    },
  );
  test('parses scoped cents and all four languages without inferring expired payment', () {
    final data = parse(orderFixture());
    expect(data.orders.single.status, 'pending');
    expect(data.orders.single.items.single.subtotalCents, 1200);
    expect(data.orders.single.items.single.name(UiLanguage.en), 'Test product');
    expect(data.orders.single.items.single.name(UiLanguage.tw), '測試商品');
    expect(data.orders.single.items.single.specification(UiLanguage.th), 'ขวด');
    expect(() => data.orders.clear(), throwsUnsupportedError);
  });
  for (final reason in [
    'store',
    'session',
    'money',
    'quantity',
    'duplicate',
    'status',
    'cursor',
    'date',
  ]) {
    test('rejects invalid $reason', () {
      final raw = orderFixture(), data = raw['result'] as Map<String, dynamic>;
      final order = (data['orders'] as List).first as Map<String, dynamic>;
      if (reason == 'store') data['storeRef'] = 'other-store';
      if (reason == 'session') {
        (data['session'] as Map)['sessionRef'] = 'other-session';
      }
      if (reason == 'money') order['totalCents'] = 1201;
      if (reason == 'quantity') {
        ((order['items'] as List).first as Map)['quantity'] = true;
      }
      if (reason == 'duplicate') (data['orders'] as List).add(order);
      if (reason == 'status') order['status'] = 'success';
      if (reason == 'cursor') data['nextAfterOrder'] = order['orderRef'];
      if (reason == 'date') order['createdAt'] = '2026-02-31T08:00:00Z';
      expect(() => parse(raw), throwsA(anything));
    });
  }
  test('rejects repeated/reversed cursor and allows empty closed historical session', () {
    expect(
      () => parse(orderFixture(), after: 'D00000000001'),
      throwsA(anything),
    );
    final raw = orderFixture();
    (raw['result'] as Map)['orders'] = [];
    ((raw['result'] as Map)['session'] as Map)['status'] = 'closed';
    expect(parse(raw).orders, isEmpty);
  });
}
