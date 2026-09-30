import 'dart:async';
import 'package:flutter/material.dart';
import '../strings.dart';
import 'native_raster_print_transport.dart';
import 'raster_print_coordinator.dart';
import 'test_receipt_renderer.dart';
import 'usb_printer_permission.dart';

/// Fixed diagnostic receipt only. Acknowledgements do not establish hardware
/// compatibility: the operator must have verified it before authorizing output.
class TestReceiptOutputPanel extends StatefulWidget {
  const TestReceiptOutputPanel({super.key, required this.receipt,
    required this.target, required this.language, this.coordinator});
  final RenderedTestReceipt receipt;
  final UsbPrinterSelection target;
  final UiLanguage language;
  final RasterPrintCoordinator? coordinator;
  @override
  State<TestReceiptOutputPanel> createState() => _TestReceiptOutputPanelState();
}

class _TestReceiptOutputPanelState extends State<TestReceiptOutputPanel>
    with WidgetsBindingObserver {
  late final RasterPrintCoordinator coordinator;
  bool foreground = true, compatible = false, consent = false;
  bool busy = false, attempted = false;
  int epoch = 0;
  String? status;
  String t(String key) => tr(widget.language, key);

  @override
  void initState() {
    super.initState();
    foreground = WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    coordinator = widget.coordinator ?? RasterPrintCoordinator(
      transport: const NativeRasterPrintTransport(),
      enabled: const bool.fromEnvironment('CASHIER_USB_RASTER_OUTPUT', defaultValue: false),
    );
    WidgetsBinding.instance.addObserver(this);
  }
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    epoch++;
    setState(() {
      foreground = state == AppLifecycleState.resumed;
      compatible = false;
      consent = false;
      if (busy) status = 'printerOutputReview';
    });
  }
  @override
  void didUpdateWidget(covariant TestReceiptOutputPanel old) {
    super.didUpdateWidget(old);
    if (old.receipt != widget.receipt || old.target != widget.target) {
      epoch++;
      compatible = false;
      consent = false;
      // Once attempted, don't let changing preview bypass review in this panel.
      if (busy) status = 'printerOutputReview';
    }
  }
  @override
  void dispose() {
    epoch++;
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
  Future<void> send() async {
    if (!coordinator.enabled || !foreground || busy || attempted || !compatible || !consent) return;
    final generation = epoch, receipt = widget.receipt, target = widget.target;
    setState(() { busy = true; attempted = true; status = null; });
    try {
      final result = await coordinator.printRaster(
        raster: receipt.raster, target: target, confirmed: true,
        compatibilityVerified: compatible,
        stillCurrent: () => mounted && foreground && epoch == generation &&
            identical(widget.receipt, receipt) && identical(widget.target, target),
      );
      if (mounted && epoch == generation) {
        setState(() => status = result.state == 'transport_accepted'
          ? 'printerOutputAccepted' : 'printerOutputReview');
      }
    } catch (_) {
      if (mounted) setState(() => status = 'printerOutputReview');
    } finally {
      if (mounted) setState(() { busy = false; consent = false; });
    }
  }
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      Text('USB ${widget.target.device.vendorProduct} · ${widget.target.device.deviceId} · '
        '${widget.target.interface.id}/${widget.target.interface.alternate} · OUT ${widget.target.endpoint.address}'),
      if (!coordinator.enabled) Text(t('printerOutputDisabled')),
      if (!attempted && coordinator.enabled) ...[
        CheckboxListTile(
          key: const ValueKey('test-print-compatible'), dense: true,
          contentPadding: EdgeInsets.zero, title: Text(t('printerOutputCompatibility')),
          value: compatible, onChanged: foreground && !busy ? (value) =>
            setState(() { compatible = value == true; consent = false; }) : null,
        ),
        CheckboxListTile(
          key: const ValueKey('test-print-consent'), dense: true,
          contentPadding: EdgeInsets.zero, title: Text(t('printerOutputConsent')),
          value: consent, onChanged: foreground && !busy && compatible ? (value) =>
            setState(() => consent = value == true) : null,
        ),
        FilledButton(
          key: const ValueKey('test-print-send'),
          onPressed: foreground && !busy && compatible && consent ? () => unawaited(send()) : null,
          child: Text(t('printerOutputSend')),
        ),
      ],
      if (busy) const LinearProgressIndicator(),
      if (status != null) Text(t(status!), key: const ValueKey('test-print-status')),
    ],
  );
}
