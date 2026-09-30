import 'dart:async';

import 'package:flutter/material.dart';

import '../live/receipt_document.dart';
import '../strings.dart';
import 'raster_preview.dart';
import 'receipt_document_renderer.dart';
import 'receipt_output_panel.dart';
import 'private_raster_image.dart';
import 'receipt_print_identity.dart';

typedef ReceiptPageRender = Future<RasterPreview> Function(
  ReceiptRasterPlan plan,
  int page,
);

/// Parent owns authenticated document lifetime and must remove this widget when
/// its source expires. Output is separately gated; no payment action here.
class ReceiptRasterPreviewPanel extends StatefulWidget {
  const ReceiptRasterPreviewPanel({
    super.key,
    required ReceiptDocument this.document,
    required this.language,
    this.render,
    this.sourceBase,
  }) : tableDocument = null;
  const ReceiptRasterPreviewPanel.forTable({
    super.key,
    required TableReceiptDocument document,
    required this.language,
    this.render,
    this.sourceBase,
  }) : tableDocument = document,
       document = null;
  final String? sourceBase;
  final ReceiptDocument? document;
  final TableReceiptDocument? tableDocument;
  bool get outputEnabled => tableDocument == null
      ? const bool.fromEnvironment(
          'CASHIER_RECEIPT_OUTPUT',
          defaultValue: false,
        )
      : const bool.fromEnvironment(
          'CASHIER_TABLE_RECEIPT_OUTPUT',
          defaultValue: false,
        );
  final UiLanguage language;
  final ReceiptPageRender? render;
  @override
  State<ReceiptRasterPreviewPanel> createState() =>
      _ReceiptRasterPreviewPanelState();
}

class _ReceiptRasterPreviewPanelState extends State<ReceiptRasterPreviewPanel>
    with WidgetsBindingObserver {
  int width = 576, page = 0, epoch = 0;
  bool busy = false, failed = false, foreground = true, queued = false;
  ReceiptRasterPlan? plan;
  RasterPreview? preview;
  String t(String key) => tr(widget.language, key);
  @override
  void initState() {
    super.initState();
    foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    if (foreground) unawaited(load());
  }

  @override
  void didUpdateWidget(covariant ReceiptRasterPreviewPanel old) {
    super.didUpdateWidget(old);
    if (old.document != widget.document ||
        old.tableDocument != widget.tableDocument ||
        old.language != widget.language ||
        old.render != widget.render ||
        old.sourceBase != widget.sourceBase) {
      epoch++;
      preview = null;
      plan = null;
      page = 0;
      failed = false;
      if (foreground) {
        if (busy) {
          queued = true;
        } else {
          unawaited(load());
        }
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    epoch++;
    foreground = state == AppLifecycleState.resumed;
    setState(() {
      preview = null;
      plan = null;
      queued = false;
      failed = false;
    });
    // Do not re-render old financial data on resume. Parent requires a fresh read.
  }

  @override
  void dispose() {
    epoch++;
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> load() async {
    if (!mounted || !foreground || busy) return;
    final generation = ++epoch;
    setState(() {
      busy = true;
      failed = false;
      preview = null;
    });
    try {
      final nextPlan =
          plan ??
          (widget.tableDocument != null
              ? ReceiptRasterPlan.forTable(
                  widget.tableDocument!,
                  language: widget.language,
                  widthDots: width,
                )
              : ReceiptRasterPlan.create(
                  widget.document!,
                  language: widget.language,
                  widthDots: width,
                ));
      final next =
          await (widget.render ?? (plan, page) => plan.renderPage(page))(
            nextPlan,
            page,
          );
      if (mounted && foreground && generation == epoch) {
        if (next.raster.width != width ||
            next.raster.height > ReceiptRasterPlan.maxRows) {
          throw const FormatException();
        }
        setState(() {
          plan = nextPlan;
          preview = next;
        });
      }
    } catch (_) {
      if (mounted && generation == epoch) {
        setState(() {
          failed = true;
          preview = null;
        });
      }
    } finally {
      if (mounted) {
        setState(() => busy = false);
        if (queued && foreground) {
          queued = false;
          unawaited(load());
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        t(widget.outputEnabled ? 'receiptOutputNotice' : 'receiptRasterNotice'),
      ),
      Wrap(
        spacing: 12,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(t('printerTestDotWidth')),
          DropdownButton<int>(
            key: const ValueKey('receipt-raster-width'),
            value: width,
            items: [
              for (final value in [384, 512, 576])
                DropdownMenuItem(value: value, child: Text('$value')),
            ],
            onChanged: busy || !foreground
                ? null
                : (value) {
                    if (value == null || value == width) return;
                    setState(() {
                      width = value;
                      page = 0;
                      plan = null;
                      preview = null;
                    });
                    unawaited(load());
                  },
          ),
          OutlinedButton(
            key: const ValueKey('receipt-raster-previous'),
            onPressed: !busy && foreground && page > 0
                ? () {
                    setState(() => page--);
                    unawaited(load());
                  }
                : null,
            child: Text(t('receiptPreviousPage')),
          ),
          Text(plan == null ? '—' : '${page + 1}/${plan!.pages.length}'),
          OutlinedButton(
            key: const ValueKey('receipt-raster-next'),
            onPressed:
                !busy &&
                    foreground &&
                    plan != null &&
                    page + 1 < plan!.pages.length
                ? () {
                    setState(() => page++);
                    unawaited(load());
                  }
                : null,
            child: Text(t('receiptNextPage')),
          ),
        ],
      ),
      if (busy) const LinearProgressIndicator(),
      if (failed) Text(t('printerTestPreviewFailed')),
      if (failed)
        TextButton(
          onPressed: busy || !foreground ? null : () => unawaited(load()),
          child: Text(t('ordersRefresh')),
        ),
      Expanded(
        child: ColoredBox(
          color: const Color(0xffdddddd),
          child: Center(
            child: preview == null
                ? const SizedBox()
                : PrivateRasterImage(
                    preview: preview!,
                    key: const ValueKey('receipt-raster-image'),
                    label: t('receiptRasterTitle'),
                    failureLabel: t('printerTestPreviewFailed'),
                  ),
          ),
        ),
      ),
      if (widget.outputEnabled && plan != null && widget.sourceBase != null)
        Flexible(
          child: SingleChildScrollView(
            child: ReceiptOutputPanel(
              plan: plan!,
              language: widget.language,
              identity: widget.tableDocument != null
                  ? ReceiptPrintIdentity.forTable(
                      base: widget.sourceBase!,
                      storeRef: widget.tableDocument!.storeRef,
                      checkoutRef: widget.tableDocument!.checkoutRef,
                    )
                  : ReceiptPrintIdentity(
                      base: widget.sourceBase!,
                      storeRef: widget.document!.storeRef,
                      orderRef: widget.document!.orderRef,
                    ),
            ),
          ),
        ),
    ],
  );
}
