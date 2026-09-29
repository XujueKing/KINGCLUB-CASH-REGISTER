import 'dart:async';

import 'package:flutter/material.dart';

import '../strings.dart';
import '../auth/staff_auth_controller.dart';
import 'order_snapshot.dart';
import 'table_snapshot.dart';

/// In-memory single-order projection. No export, payment proof or printer transport.
class OrderPreviewDialog extends StatefulWidget {
  const OrderPreviewDialog({
    super.key,
    required this.order,
    required this.language,
    required this.observedAt,
    required this.expiresAt,
    required this.auth,
  });
  final LiveOrder order;
  final StaffAuthController auth;
  final UiLanguage language;
  final DateTime observedAt, expiresAt;
  @override
  State<OrderPreviewDialog> createState() => _OrderPreviewDialogState();
}

class _OrderPreviewDialogState extends State<OrderPreviewDialog>
    with WidgetsBindingObserver {
  Timer? expiry;
  bool valid = false;
  String t(String key) => tr(widget.language, key);
  @override
  void initState() {
    super.initState();
    widget.auth.addListener(invalidate);
    WidgetsBinding.instance.addObserver(this);
    final remaining = widget.expiresAt.difference(DateTime.now());
    valid = remaining > Duration.zero;
    if (valid) {
      expiry = Timer(remaining, invalidate);
    }
  }

  void invalidate() {
    expiry?.cancel();
    if (mounted) setState(() => valid = false);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) invalidate();
  }

  @override
  void dispose() {
    expiry?.cancel();
    widget.auth.removeListener(invalidate);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Dialog(
    child: SizedBox(
      width: 620,
      height: 640,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(child: Text(t('orderPreviewTitle'))),
                TextButton(
                  key: const ValueKey('order-preview-close'),
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(t('printerInspectClose')),
                ),
              ],
            ),
            Expanded(
              child: valid
                  ? SingleChildScrollView(
                      key: const ValueKey('order-preview-content'),
                      child: ColoredBox(
                        color: Colors.white,
                        child: Padding(
                          padding: const EdgeInsets.all(20),
                          child: DefaultTextStyle(
                            style: const TextStyle(
                              color: Colors.black,
                              fontSize: 16,
                              height: 1.5,
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                const Text('KINGCLUB POS'),
                                Text(t('orderPreviewNotice')),
                                const Divider(),
                                Text(widget.order.reference),
                                Text(
                                  '${t('orderPreviewStatus')}: ${t('order_${widget.order.status}')}',
                                ),
                                Text(
                                  '${t('liveObserved')}: ${widget.observedAt.toLocal()}',
                                ),
                                for (final item in widget.order.items)
                                  Padding(
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 8,
                                    ),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      children: [
                                        Text(
                                          '${item.name(widget.language)} · ${item.specification(widget.language)}',
                                        ),
                                        Text(
                                          '${item.quantity} × ${widget.order.currency} ${formatCents(item.priceCents)} = ${widget.order.currency} ${formatCents(item.subtotalCents)}',
                                        ),
                                      ],
                                    ),
                                  ),
                                const Divider(),
                                Text(
                                  '${t('orderPreviewTotal')}: ${widget.order.currency} ${formatCents(widget.order.totalCents)}',
                                ),
                                Text(t('orderPreviewNotice')),
                              ],
                            ),
                          ),
                        ),
                      ),
                    )
                  : Center(child: Text(t('orderPreviewExpired'))),
            ),
          ],
        ),
      ),
    ),
  );
}
