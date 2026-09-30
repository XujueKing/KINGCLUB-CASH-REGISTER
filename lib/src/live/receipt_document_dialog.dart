import 'dart:async';
import 'package:flutter/material.dart';
import '../auth/staff_auth_controller.dart';
import '../strings.dart';
import '../hardware/receipt_raster_preview_panel.dart';
import 'receipt_document.dart';
import 'table_snapshot.dart';

/// Fresh read-only financial snapshot, not a local order preview or print action.
class ReceiptDocumentDialog extends StatefulWidget {
  const ReceiptDocumentDialog({super.key, required this.auth, required this.orderRef,
    required this.tableRef, required this.sessionRef, required this.language});
  final StaffAuthController auth;
  final String orderRef, tableRef, sessionRef;
  final UiLanguage language;
  @override
  State<ReceiptDocumentDialog> createState() => _ReceiptDocumentDialogState();
}
class _ReceiptDocumentDialogState extends State<ReceiptDocumentDialog> with WidgetsBindingObserver {
  ReceiptDocument? document;
  bool foreground = true, loading = false, failed = false, raster = false;
  int epoch = 0;
  Timer? expiry;
  String t(String key) => tr(widget.language, key);
  @override
  void initState() {
    super.initState();
    foreground = WidgetsBinding.instance.lifecycleState == null ||
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    widget.auth.addListener(invalidate);
    WidgetsBinding.instance.addObserver(this);
    if (foreground) unawaited(load());
  }
  void invalidate() {
    epoch++;
    expiry?.cancel();
    if (mounted) setState(() {document = null; loading = false; failed = false; raster = false;});
  }
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    invalidate();
  }
  @override
  void didUpdateWidget(covariant ReceiptDocumentDialog old) {
    super.didUpdateWidget(old);
    if (old.auth != widget.auth || old.orderRef != widget.orderRef ||
        old.tableRef != widget.tableRef || old.sessionRef != widget.sessionRef) {
      old.auth.removeListener(invalidate); widget.auth.addListener(invalidate);
      invalidate();
    }
  }
  @override
  void dispose() {
    epoch++; expiry?.cancel(); widget.auth.removeListener(invalidate);
    WidgetsBinding.instance.removeObserver(this); super.dispose();
  }
  Future<void> load() async {
    if (!mounted || !foreground || loading) return;
    final generation = ++epoch, identity = widget.auth.session;
    expiry?.cancel();
    setState(() {loading = true; failed = false; document = null;});
    final elapsed = Stopwatch()..start();
    try {
      if (identity == null || !identity.permissions.contains('orders.read') ||
          !identity.expiresAt.isAfter(DateTime.now())) {
        throw const FormatException();
      }
      final next = await widget.auth.readReceiptDocument(widget.orderRef);
      if (!mounted || !foreground || generation != epoch || !identical(identity, widget.auth.session)) return;
      final sessionRemaining = identity.expiresAt.difference(DateTime.now());
      final snapshotRemaining = const Duration(seconds: 30) - elapsed.elapsed;
      final remaining = sessionRemaining < snapshotRemaining ? sessionRemaining : snapshotRemaining;
      if (remaining <= Duration.zero || next.storeRef != identity.storeRef || next.orderRef != widget.orderRef ||
          next.tableRef != widget.tableRef || next.sessionRef != widget.sessionRef) {
        throw const FormatException();
      }
      setState(() => document = next);
      expiry = Timer(remaining, invalidate);
    } catch (_) {
      if (mounted && generation == epoch) setState(() {failed = true; document = null;});
    } finally {
      elapsed.stop();
      if (mounted && generation == epoch) setState(() => loading = false);
    }
  }
  Widget amount(String label, int cents) => Text('$label: CNY ${formatCents(cents)}');
  @override
  Widget build(BuildContext context) {
    final data = document;
    return Dialog(child: SizedBox(width: 680, height: 640, child: Padding(
      padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [Expanded(child: Text(t('receiptDocumentTitle'))),
          TextButton(key: const ValueKey('receipt-document-refresh'),
            onPressed: foreground && !loading ? () => unawaited(load()) : null, child: Text(t('ordersRefresh'))),
          TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(t('printerInspectClose'))),
        ]),
        Text(t('receiptDocumentNotice')),
        if (data != null) TextButton(key: const ValueKey('receipt-raster-toggle'),
          onPressed: () => setState(() => raster = !raster),
          child: Text(t(raster ? 'receiptDocumentTitle' : 'receiptRasterTitle'))),
        if (loading) const LinearProgressIndicator(),
        Expanded(child: data == null ? Center(child: Text(t(failed ? 'receiptDocumentFailed' : 'receiptDocumentReload')))
          : raster ? ReceiptRasterPreviewPanel(document: data, language: widget.language, sourceBase: widget.auth.session?.base.toString())
          : SingleChildScrollView(key: const ValueKey('receipt-document-content'), child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text('${data.storeRef} · ${data.tableRef} · ${data.sessionRef}'),
              Text(data.orderRef),
              Text(t(data.refunded ? 'liveRefunded' : 'order_paid')),
              Text('${t('receiptConfirmedAt')}: ${data.confirmedAt.toLocal()}'),
              Text('${t('liveObserved')}: ${data.observedAt.toLocal()}'),
              const Divider(),
              for (final item in data.items) Padding(padding: const EdgeInsets.symmetric(vertical: 6), child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Text('${item.name(widget.language)} · ${item.specification(widget.language)}'),
                  Text('${item.quantity} × CNY ${formatCents(item.priceCents)} = CNY ${formatCents(item.subtotalCents)}'),
                ])),
              const Divider(),
              Text(t(data.channel == 'cash' ? 'receiptCash' : 'provider_${data.channel}')),
              amount(t('orderPreviewTotal'), data.totalCents),
              if (data.receivedCents != null) amount(t('cashReceived'), data.receivedCents!),
              if (data.changeCents != null) amount(t('cashChange'), data.changeCents!),
              if (data.accountType != null) ...[
                Text(t('balance_${data.accountType}')),
                amount(t('receiptPrincipal'), data.principalCents!),
                amount(t('receiptGift'), data.giftCents!),
              ],
              amount(t('receiptRefundedAmount'), data.refundedCents),
              amount(t('receiptNetAmount'), data.netPaidCents),
              if (data.refunded) ...[
                Text('${t('liveRefunded')}: ${data.refundedAt!.toLocal()}'),
                Text(data.refundRef!),
                amount(t('refundPrincipal'), data.principalCents!), amount(t('refundGift'), data.giftCents!),
              ],
            ],
          ))),
      ]),
    )));
  }
}
