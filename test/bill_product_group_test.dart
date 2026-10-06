import 'package:flutter_test/flutter_test.dart';

import 'package:kingclub_cash_register/src/live/bill_product_group.dart';
import 'package:kingclub_cash_register/src/live/order_snapshot.dart';
import 'package:kingclub_cash_register/src/live/workspace_read_cache.dart';

import 'support/order_fixture.dart';

LiveOrder order(String ref, String status, int served, {int price = 600}) {
  final data = orderFixture()['result']['orders'][0] as Map<String, dynamic>;
  data['orderRef'] = ref;
  data['status'] = status;
  data['totalCents'] = price * 2;
  data['items'][0]['servedQuantity'] = served;
  data['items'][0]['remainingQuantity'] = 2 - served;
  data['items'][0]['priceCents'] = price;
  data['items'][0]['subtotalCents'] = price * 2;
  return LiveOrder(data);
}

void main() {
  test(
    'special price identity keeps the same SKU separate from normal orders',
    () {
      final data =
          orderFixture()['result']['orders'][0] as Map<String, dynamic>;
      data['orderRef'] = 'D00000000003';
      data['items'][0]['snapshot']['pricing'] = {
        'originalUnitPriceCents': 800,
        'unitPriceCents': 600,
        'selectionRef': 'price-test',
        'operatedBy': 'E00000000001',
      };
      final groups = groupBillProducts([
        order('D00000000001', 'pending', 0),
        order('D00000000002', 'paid', 0),
        LiveOrder(data),
      ]);
      expect(groups.length, 2);
      expect(groups.singleWhere((g) => g.specialPrice).quantity, 2);
      expect(groups.singleWhere((g) => !g.specialPrice).quantity, 4);
      data['items'][0]['snapshot']['pricing']['unitPriceCents'] = 500;
      expect(() => LiveOrder(data), throwsFormatException);
    },
  );
  test('item refund keeps gross history but removes returned units from active bill', () {
    final data = orderFixture()['result']['orders'][0] as Map<String, dynamic>;
    data.addAll({
      'status': 'paid',
      'cashierOrder': true,
      'refunds': [
        {
          'refundRef': '00000000-0000-4000-8000-000000000001',
          'accountType': 'platform_cash',
          'totalCents': 600,
          'principalCents': 600,
          'giftCents': 0,
          'refundedAt': '2026-10-03T00:00:00Z',
        },
      ],
    });
    data['items'][0]['refundedQuantity'] = 1;
    data['items'][0]['remainingQuantity'] = 1;
    final partial = LiveOrder(data);
    final group = groupBillProducts([
      partial,
      order('D00000000002', 'pending', 0),
    ]).single;
    expect(partial.totalCents, 1200);
    expect(partial.items.single.quantity, 2);
    expect(partial.refundQuantitiesKnown, true);
    expect(group.quantity, 3);
    expect(group.returned, 1);
    expect(group.paidQuantity, 1);
    expect(group.unpaidQuantity, 2);
    expect(group.remaining, 3);
    expect(group.totalCents, 1800);
    data['items'][0]['remainingQuantity'] = 2;
    expect(() => LiveOrder(data), throwsFormatException);
    data['items'][0]['remainingQuantity'] = 1;
    data['refunds'][0]['totalCents'] = 500;
    data['refunds'][0]['principalCents'] = 500;
    expect(() => LiveOrder(data), throwsFormatException);
  });
  test(
    'repeat product merges payment and delivery counts but retains originals',
    () {
      final group = groupBillProducts([
        order('D00000000001', 'paid', 1),
        order('D00000000002', 'pending', 0, price: 800),
        order('D00000000003', 'paid', 2),
        order('D00000000004', 'expired', 0),
      ]).single;
      expect(group.quantity, 6);
      expect(group.paidQuantity, 4);
      expect(group.unpaidQuantity, 2);
      expect(group.served, 3);
      expect(group.remaining, 3);
      expect(group.totalCents, 4000);
      expect(group.mixedPrices, isTrue);
      expect(group.lines.length, 3);
    },
  );
  test(
    'display cache never crosses identity or table scope and stays bounded',
    () {
      final a = Object(), b = Object();
      WorkspaceReadCache.put(a, 'table-a', 'old');
      expect(WorkspaceReadCache.read<String>(a, 'table-a'), 'old');
      expect(WorkspaceReadCache.read<String>(b, 'table-a'), isNull);
      expect(WorkspaceReadCache.read<String>(a, 'table-b'), isNull);
      for (var i = 0; i < 128; i++) {
        WorkspaceReadCache.put(a, 'table-$i', i);
      }
      expect(WorkspaceReadCache.read<String>(a, 'table-a'), isNull);
    },
  );
}
