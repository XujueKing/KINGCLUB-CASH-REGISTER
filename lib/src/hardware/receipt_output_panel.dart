import 'dart:async';

import 'package:flutter/material.dart';

import '../strings.dart';
import 'escpos_raster.dart';
import 'native_raster_print_transport.dart';
import 'printer_discovery.dart';
import 'raster_print_coordinator.dart';
import 'receipt_document_renderer.dart';
import 'usb_printer_permission.dart';
import 'receipt_print_identity.dart';

/// Parent must remove this with the authenticated financial snapshot. USB
/// authorization is never requested here; granting OS access is a separate action.
class ReceiptOutputPanel extends StatefulWidget {
  const ReceiptOutputPanel({
    super.key,
    required this.plan,
    required this.language,
    required this.identity,
    this.coordinator,
    this.inspect,
  });
  final ReceiptRasterPlan plan;
  final UiLanguage language;
  final ReceiptPrintIdentity identity;
  final RasterPrintCoordinator? coordinator;
  final Future<PrinterDiscovery> Function()? inspect;
  @override
  State<ReceiptOutputPanel> createState() => _ReceiptOutputPanelState();
}

class _ReceiptOutputPanelState extends State<ReceiptOutputPanel>
    with WidgetsBindingObserver {
  late final RasterPrintCoordinator coordinator;
  List<UsbPrinterSelection> targets = [];
  UsbPrinterSelection? selected;
  bool busy = false,
      foreground = true,
      compatible = false,
      consent = false,
      attempted = false;
  String? status;
  int epoch = 0;
  String t(String key) => tr(widget.language, key);
  @override
  void initState() {
    super.initState();
    coordinator =
        widget.coordinator ??
        RasterPrintCoordinator(
          transport: const NativeRasterPrintTransport(),
          enabled: const bool.fromEnvironment(
            'CASHIER_USB_RASTER_OUTPUT',
            defaultValue: false,
          ),
        );
    foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
  }

  void invalidate({bool documentChanged = false}) {
    epoch++;
    targets = [];
    selected = null;
    compatible = false;
    consent = false;
    // An attempt belongs to one logical receipt, not the reusable widget. Keep
    // the same receipt fenced across layout changes; another receipt must not
    // inherit its status. Durable journal entries are never removed here.
    if (documentChanged) attempted = false;
    status = attempted ? 'printerOutputReview' : null;
  }

  @override
  void didUpdateWidget(covariant ReceiptOutputPanel old) {
    super.didUpdateWidget(old);
    final documentChanged = old.identity.canonical != widget.identity.canonical;
    if (old.plan != widget.plan || documentChanged) {
      invalidate(documentChanged: documentChanged);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    setState(() {
      foreground = state == AppLifecycleState.resumed;
      invalidate();
    });
  }

  @override
  void dispose() {
    epoch++;
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  bool current(int generation) => mounted && foreground && epoch == generation;
  Future<void> discover() async {
    if (busy || attempted || !foreground || !coordinator.enabled) return;
    final generation = ++epoch;
    setState(() {
      busy = true;
      targets = [];
      selected = null;
      compatible = false;
      consent = false;
      status = null;
    });
    try {
      final discovery =
          await (widget.inspect ?? const PrinterDiscoveryClient().inspect)();
      if (!current(generation)) return;
      final candidates = <UsbPrinterSelection>[
        for (final device in discovery.usbPrinters.where(
          (d) => d.hasPermission,
        ))
          for (final interface in device.interfaces.where(
            (i) => i.hasBulkOutput && i.alternate == 0,
          ))
            for (final endpoint in interface.endpoints.where(
              (e) => e.type == 2 && e.address > 0 && e.address < 16,
            ))
              UsbPrinterSelection.choose(device, interface, endpoint),
      ];
      setState(() {
        targets = candidates;
        if (candidates.isEmpty) status = 'receiptPrinterUnavailable';
      });
    } catch (_) {
      if (current(generation)) setState(() => status = 'printerInspectFailed');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> send() async {
    final target = selected;
    if (busy ||
        attempted ||
        !foreground ||
        !coordinator.enabled ||
        target == null ||
        !compatible ||
        !consent) {
      return;
    }
    final generation = epoch, plan = widget.plan, identity = widget.identity;
    setState(() {
      busy = true;
      attempted = true;
      status = null;
    });
    final rasters = <MonochromeRaster>[];
    try {
      for (var page = 0; page < plan.pages.length; page++) {
        if (!current(generation)) throw const FormatException();
        final rendered = await plan.renderPage(page);
        if (!current(generation)) throw const FormatException();
        rasters.add(rendered.raster); // Do not retain each page's PNG preview.
      }
      final result = await coordinator.printRasters(
        rasters: rasters,
        target: target,
        documentIdentity: identity,
        confirmed: true,
        compatibilityVerified: compatible,
        stillCurrent: () => current(generation) && identical(widget.plan, plan),
      );
      if (current(generation)) {
        setState(
          () => status = result.state == 'transport_accepted'
              ? 'printerOutputAccepted'
              : 'printerOutputReview',
        );
      }
    } catch (_) {
      if (current(generation)) setState(() => status = 'printerOutputReview');
    } finally {
      rasters.clear();
      if (mounted) {
        setState(() {
          busy = false;
          consent = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(t('receiptOutputNotice')),
      if (!coordinator.enabled) Text(t('printerOutputDisabled')),
      if (!attempted && coordinator.enabled) ...[
        OutlinedButton(
          key: const ValueKey('receipt-output-discover'),
          onPressed: foreground && !busy ? () => unawaited(discover()) : null,
          child: Text(t('receiptSelectPrinter')),
        ),
        for (final target in targets)
          OutlinedButton(
            onPressed: busy || !foreground
                ? null
                : () => setState(() {
                    selected = target;
                    compatible = false;
                    consent = false;
                  }),
            child: Text(
              '${identical(selected, target) ? "✓ " : ""}USB ${target.device.vendorProduct} · '
              '${target.device.deviceId} · ${target.interface.id} · OUT ${target.endpoint.address}',
            ),
          ),
        if (selected != null) ...[
          CheckboxListTile(
            key: const ValueKey('receipt-output-compatible'),
            dense: true,
            contentPadding: EdgeInsets.zero,
            value: compatible,
            title: Text(t('printerOutputCompatibility')),
            onChanged: foreground && !busy
                ? (v) => setState(() {
                    compatible = v == true;
                    consent = false;
                  })
                : null,
          ),
          CheckboxListTile(
            key: const ValueKey('receipt-output-consent'),
            dense: true,
            contentPadding: EdgeInsets.zero,
            value: consent,
            title: Text(
              '${t('receiptOutputConsent')} (${widget.plan.pages.length})',
            ),
            onChanged: foreground && !busy && compatible
                ? (v) => setState(() => consent = v == true)
                : null,
          ),
          FilledButton(
            key: const ValueKey('receipt-output-send'),
            onPressed: foreground && !busy && compatible && consent
                ? () => unawaited(send())
                : null,
            child: Text(t('print')),
          ),
        ],
      ],
      if (busy) const LinearProgressIndicator(),
      if (status != null)
        Text(t(status!), key: const ValueKey('receipt-output-status')),
    ],
  );
}
