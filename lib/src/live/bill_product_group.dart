import 'order_snapshot.dart';

class BillProductGroup {
  BillProductGroup(this.productRef, this.currency);
  String get groupingRef => item.groupingRef;
  bool get specialPrice => item.specialPrice;
  final String productRef, currency;
  final lines = <({LiveOrder order, OrderItem item})>[];
  OrderItem get item => lines.first.item;
  Iterable<({LiveOrder order, OrderItem item})> get active => lines.where(
    (line) => !line.order.fullyRefunded && line.item.activeQuantity > 0,
  );
  int get quantity => active.fold(0, (n, line) => n + line.item.activeQuantity);
  int get returned => lines.fold(
    0,
    (n, line) =>
        n +
        (line.order.fullyRefunded
            ? line.item.quantity
            : (line.item.refundedQuantity ?? 0)),
  );
  int get totalCents => active.fold(
    0,
    (n, line) => n + line.item.activeQuantity * line.item.priceCents,
  );
  int get paidQuantity => active
      .where((line) => line.order.status == 'paid' && line.item.priceCents > 0)
      .fold(0, (n, line) => n + line.item.activeQuantity);
  int get waivedQuantity => active
      .where((line) => line.item.priceCents == 0)
      .fold(0, (n, line) => n + line.item.activeQuantity);
  int get unpaidQuantity => active
      .where(
        (line) => line.order.status == 'pending' && line.item.priceCents > 0,
      )
      .fold(0, (n, line) => n + line.item.activeQuantity);
  bool get servingKnown => active.every((line) => line.item.servingKnown);
  int get served =>
      active.fold(0, (n, line) => n + (line.item.servedQuantity ?? 0));
  int get remaining =>
      active.fold(0, (n, line) => n + (line.item.remainingQuantity ?? 0));
  bool get mixedPrices =>
      active.map((line) => line.item.priceCents).toSet().length > 1;
}

List<BillProductGroup> groupBillProducts(List<LiveOrder> orders) {
  final groups = <String, BillProductGroup>{};
  for (final order in orders) {
    if (order.status == 'expired') continue;
    for (final item in order.items) {
      final key = '${order.currency}/${item.groupingRef}';
      (groups.putIfAbsent(
        key,
        () => BillProductGroup(item.productRef, order.currency),
      )).lines.add((order: order, item: item));
    }
  }
  return groups.values.toList();
}
