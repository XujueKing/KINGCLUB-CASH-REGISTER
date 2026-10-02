import 'package:flutter_test/flutter_test.dart';
import '../lib/src/live/bill_product_group.dart';
import '../lib/src/live/order_snapshot.dart';
import '../lib/src/live/workspace_read_cache.dart';
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
  test('repeat product merges payment and delivery counts but retains originals', () {
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
  });
  test('display cache never crosses identity or table scope and stays bounded', () {
    final a = Object(), b = Object();
    WorkspaceReadCache.put(a, 'table-a', 'old');
    expect(WorkspaceReadCache.read<String>(a, 'table-a'), 'old');
    expect(WorkspaceReadCache.read<String>(b, 'table-a'), isNull);
    expect(WorkspaceReadCache.read<String>(a, 'table-b'), isNull);
    for (var i = 0; i < 24; i++) { WorkspaceReadCache.put(a, 'table-$i', i); }
    expect(WorkspaceReadCache.read<String>(a, 'table-a'), isNull);
  });
}
