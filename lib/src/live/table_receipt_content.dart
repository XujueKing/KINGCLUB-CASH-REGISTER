import 'package:flutter/material.dart';

import '../strings.dart';
import 'receipt_document.dart';
import 'table_snapshot.dart';

/// Display only, no network or printer access. The owning authenticated dialog
/// must remove this content on logout, scope change, background or expiry.
/// Lazy order sections avoid constructing every line of a large receipt at once.
class TableReceiptContent extends StatelessWidget {
  const TableReceiptContent({
    super.key,
    required this.document,
    required this.language,
  });
  final TableReceiptDocument document;
  final UiLanguage language;

  String t(String key) => tr(language, key);
  Widget amount(String key, int cents) =>
      Text('${t(key)}: CNY ${formatCents(cents)}');

  @override
  Widget build(BuildContext context) {
    final tender = document.tender;
    return ListView.builder(
      key: ValueKey('table-receipt-${document.checkoutRef}'),
      padding: const EdgeInsets.all(16),
      itemCount: document.orders.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                t('tableReceiptTitle'),
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              Text(t('tableReceiptNotice')),
              const SizedBox(height: 12),
              Text(
                '${document.storeRef} · ${document.tableRef} · ${document.sessionRef}',
              ),
              SelectableText(document.checkoutRef),
              Text('${t('tableReceiptOrders')}: ${document.orders.length}'),
              Text(
                '${t('receiptConfirmedAt')}: ${document.confirmedAt.toLocal()}',
              ),
              Text(
                '${t('tableReceiptSettledAt')}: ${document.settledAt.toLocal()}',
              ),
              Text('${t('liveObserved')}: ${document.observedAt.toLocal()}'),
              const Divider(),
              Text(
                t(
                  tender.channel == 'cash'
                      ? 'receiptCash'
                      : 'provider_${tender.channel}',
                ),
              ),
              amount('orderPreviewTotal', document.totalCents),
              if (tender.receivedCents != null)
                amount('cashReceived', tender.receivedCents!),
              if (tender.changeCents != null)
                amount('cashChange', tender.changeCents!),
              if (tender.accountType != null) ...[
                Text(t('balance_${tender.accountType}')),
                amount('receiptPrincipal', tender.principalCents!),
                amount('receiptGift', tender.giftCents!),
              ],
              const Divider(),
            ],
          );
        }
        final order = document.orders[index - 1];
        return ExpansionTile(
          key: ValueKey(
            'table-receipt-order-${document.checkoutRef}-${order.orderRef}',
          ),
          title: Text(order.orderRef),
          subtitle: amount('tableReceiptAllocation', order.allocatedCents),
          initiallyExpanded: document.orders.length == 1,
          children: [
            for (final item in order.items)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      '${item.name(language)} · ${item.specification(language)}',
                    ),
                    Text(
                      '${item.quantity} × CNY ${formatCents(item.priceCents)} = CNY ${formatCents(item.subtotalCents)}',
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}
