import '../hardware/paid_receipt_printer.dart';

import 'dart:async';

import 'package:flutter/material.dart';

import '../auth/staff_auth_controller.dart';
import '../hardware/receipt_raster_preview_panel.dart';
import '../strings.dart';
import 'receipt_document.dart';
import 'table_receipt_content.dart';

/// A short-lived server snapshot. Reading never confirms payment or prints.
class TableReceiptDialog extends StatefulWidget {
  const TableReceiptDialog({
    super.key,
    required this.auth,
    required this.checkoutRef,
    required this.tableRef,
    required this.sessionRef,
    required this.language,
  });
  final StaffAuthController auth;
  final String checkoutRef, tableRef, sessionRef;
  final UiLanguage language;
  @override
  State<TableReceiptDialog> createState() => _TableReceiptDialogState();
}

class _TableReceiptDialogState extends State<TableReceiptDialog>
    with WidgetsBindingObserver {
  TableReceiptDocument? document;
  bool foreground = true, loading = false, failed = false;
  bool raster = false;
  bool printing = false;
  String printStatus = '';

  Future<void> printReceipt() async {
    if (printing || document == null) return;
    setState(() {
      printing = true;
      printStatus = 'checkoutPrinting';
    });
    final status = await printPaidTableReceipt(
      auth: widget.auth,
      checkoutRef: widget.checkoutRef,
      tableRef: widget.tableRef,
      sessionRef: widget.sessionRef,
      language: widget.language,
      reprint: true,
      stillCurrent: () => mounted && foreground,
    );
    if (mounted)
      setState(() {
        printing = false;
        printStatus = status;
      });
  }

  int epoch = 0;
  Timer? expiry;
  String t(String key) => tr(widget.language, key);

  @override
  void initState() {
    super.initState();
    foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    widget.auth.addListener(invalidate);
    WidgetsBinding.instance.addObserver(this);
    if (foreground) unawaited(load());
  }

  void invalidate() {
    epoch++;
    expiry?.cancel();
    expiry = null;
    if (mounted) {
      setState(() {
        document = null;
        raster = false;
        loading = false;
        failed = false;
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    invalidate();
  }

  @override
  void didUpdateWidget(covariant TableReceiptDialog old) {
    super.didUpdateWidget(old);
    if (old.auth != widget.auth ||
        old.checkoutRef != widget.checkoutRef ||
        old.tableRef != widget.tableRef ||
        old.sessionRef != widget.sessionRef) {
      old.auth.removeListener(invalidate);
      widget.auth.addListener(invalidate);
      invalidate();
    }
  }

  @override
  void dispose() {
    epoch++;
    expiry?.cancel();
    widget.auth.removeListener(invalidate);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> load() async {
    if (!mounted || !foreground || loading) return;
    final generation = ++epoch, identity = widget.auth.session;
    expiry?.cancel();
    setState(() {
      document = null;
      raster = false;
      failed = false;
      loading = true;
    });
    final elapsed = Stopwatch()..start();
    try {
      if (identity == null ||
          !identity.permissions.contains('orders.read') ||
          !identity.expiresAt.isAfter(DateTime.now())) {
        throw const FormatException();
      }
      final next = await widget.auth.readTableReceiptDocument(
        widget.checkoutRef,
      );
      if (!mounted ||
          !foreground ||
          generation != epoch ||
          !identical(identity, widget.auth.session)) {
        return;
      }
      final sessionRemaining = identity.expiresAt.difference(DateTime.now());
      final snapshotRemaining = const Duration(seconds: 30) - elapsed.elapsed;
      final remaining = sessionRemaining < snapshotRemaining
          ? sessionRemaining
          : snapshotRemaining;
      if (remaining <= Duration.zero ||
          next.storeRef != identity.storeRef ||
          next.checkoutRef != widget.checkoutRef ||
          next.tableRef != widget.tableRef ||
          next.sessionRef != widget.sessionRef) {
        throw const FormatException();
      }
      setState(() => document = next);
      expiry = Timer(remaining, invalidate);
    } catch (_) {
      if (mounted && generation == epoch) {
        setState(() {
          document = null;
          failed = true;
        });
      }
    } finally {
      elapsed.stop();
      if (mounted && generation == epoch) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = document;
    return Dialog(
      child: SizedBox(
        width: 680,
        height: 640,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(child: Text(t('tableReceiptTitle'))),
                  FilledButton.icon(
                    onPressed: data == null || printing ? null : printReceipt,
                    icon: const Icon(Icons.print_outlined),
                    label: Text(t('receiptReprint')),
                  ),
                  if (data != null)
                    IconButton(
                      key: const ValueKey('table-receipt-raster-toggle'),
                      tooltip: t(
                        raster ? 'tableReceiptTitle' : 'receiptRasterTitle',
                      ),
                      onPressed: () => setState(() => raster = !raster),
                      icon: Icon(raster ? Icons.list_alt : Icons.receipt_long),
                    ),
                  TextButton(
                    key: const ValueKey('table-receipt-refresh'),
                    onPressed: foreground && !loading
                        ? () => unawaited(load())
                        : null,
                    child: Text(t('ordersRefresh')),
                  ),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(t('printerInspectClose')),
                  ),
                ],
              ),
              if (printStatus.isNotEmpty) Text(t(printStatus)),
              if (loading) const LinearProgressIndicator(),
              Expanded(
                child: data == null
                    ? Center(
                        child: Text(
                          t(
                            failed
                                ? 'receiptDocumentFailed'
                                : 'receiptDocumentReload',
                          ),
                        ),
                      )
                    : raster
                    ? ReceiptRasterPreviewPanel.forTable(
                        document: data,
                        language: widget.language,
                        sourceBase: widget.auth.session?.base.toString(),
                      )
                    : TableReceiptContent(
                        key: const ValueKey('table-receipt-content'),
                        document: data,
                        language: widget.language,
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
