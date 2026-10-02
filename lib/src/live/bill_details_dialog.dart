import 'package:flutter/material.dart';

import '../strings.dart';
import 'bill_product_group.dart';
import 'order_snapshot.dart';
import 'table_snapshot.dart';

typedef BillDetailAction = ({
  LiveOrder order,
  OrderItem item,
  String action,
  bool served,
});

/// Each operation stays attached to its original priced order and delivery state.
class BillDetailsDialog extends StatelessWidget {
  const BillDetailsDialog({
    super.key,
    required this.group,
    required this.language,
    required this.canServe,
    this.canRecall,
    this.canRefund,
    this.canReturnUnserved,
  });
  final BillProductGroup group;
  final UiLanguage language;
  final bool Function(LiveOrder order, OrderItem item) canServe;
  final bool Function(LiveOrder order, OrderItem item)? canRecall, canRefund;
  final bool Function(LiveOrder order, OrderItem item)? canReturnUnserved;
  String t(String key) => tr(language, key);
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(group.item.name(language)),
    content: SizedBox(
      width: 640,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final line in group.lines)
              if (line.order.refund != null)
                row(
                  context,
                  line.order,
                  line.item,
                  line.item.quantity,
                  'refunded',
                )
              else if (!line.item.servingKnown)
                row(
                  context,
                  line.order,
                  line.item,
                  line.item.quantity,
                  'unknown',
                )
              else ...[
                if (line.item.remainingQuantity! > 0)
                  row(
                    context,
                    line.order,
                    line.item,
                    line.item.remainingQuantity!,
                    'unserved',
                  ),
                if (line.item.servedQuantity! > 0)
                  row(
                    context,
                    line.order,
                    line.item,
                    line.item.servedQuantity!,
                    'served',
                  ),
              ],
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        key: const ValueKey('bill-details-close'),
        onPressed: () => Navigator.pop(context),
        child: Text(t('staffCancelSelection')),
      ),
    ],
  );
  Widget row(
    BuildContext context,
    LiveOrder order,
    OrderItem item,
    int quantity,
    String state,
  ) {
    final paid = order.status == 'paid',
        served = state == 'served',
        returned = state == 'refunded';
    final time = order.createdAt.toLocal();
    final stamp =
        '${time.month}/${time.day} ${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
    void select(String action) => Navigator.pop(context, (
      order: order,
      item: item,
      action: action,
      served: served,
    ));
    return Container(
      key: ValueKey('bill-detail-${order.reference}-$state'),
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: const Color(0xffd9e2dd)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 10,
                  runSpacing: 4,
                  children: [
                    Text(
                      t(
                        returned
                            ? 'tableBillRefunded'
                            : paid
                            ? 'tableBillPaid'
                            : 'tableBillUnpaid',
                      ),
                      style: TextStyle(
                        color: paid
                            ? const Color(0xff216344)
                            : const Color(0xff994a16),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      '${t(state == 'served'
                          ? 'billServed'
                          : state == 'unserved'
                          ? 'billNotServed'
                          : state == 'unknown'
                          ? 'billProgressUnknown'
                          : 'tableBillRefunded')} × $quantity',
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  '${formatCents(item.priceCents)} × $quantity  ·  ${formatCents(item.priceCents * quantity)}',
                ),
                const SizedBox(height: 4),
                Text(
                  stamp,
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xff777777),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          if (!returned)
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (state == 'unserved' &&
                    canReturnUnserved?.call(order, item) == true)
                  OutlinedButton(
                    key: ValueKey('bill-return-unserved-${order.reference}'),
                    onPressed: () => select('return'),
                    child: Text(t('billRecallReturn')),
                  ),
                if (state == 'unserved' && canServe(order, item))
                  FilledButton(
                    key: ValueKey('bill-serve-${order.reference}'),
                    onPressed: () => select('serve'),
                    child: Text(t('billServed')),
                  ),
                if (served)
                  OutlinedButton(
                    key: ValueKey('bill-recall-${order.reference}'),
                    onPressed: canRecall?.call(order, item) == true
                        ? () => select('recall')
                        : null,
                    child: Text(t('billRecall')),
                  ),
                if (paid)
                  OutlinedButton(
                    key: ValueKey('bill-refund-${order.reference}-$state'),
                    onPressed: canRefund?.call(order, item) == true
                        ? () => select('refund')
                        : null,
                    child: Text(t('billSingleRefund')),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}
