import 'dart:async';

import 'package:flutter/material.dart';

import '../strings.dart';
import 'printer_discovery.dart';
import 'printer_status.dart';

/// Discovery and explicitly requested read-only status, without employee login.
class PrinterDiscoveryDialog extends StatefulWidget {
  const PrinterDiscoveryDialog({
    super.key,
    required this.language,
    this.inspect,
  });
  final UiLanguage language;
  final Future<PrinterDiscovery> Function()? inspect;
  @override
  State<PrinterDiscoveryDialog> createState() => _PrinterDiscoveryDialogState();
}

class _PrinterDiscoveryDialogState extends State<PrinterDiscoveryDialog>
    with WidgetsBindingObserver {
  PrinterDiscovery? observation;
  DateTime? observedAt;
  PrinterStatus? status;
  DateTime? statusObservedAt;
  bool statusBusy = false, statusFailed = false;
  bool busy = false, failed = false, foreground = true;
  int epoch = 0;
  String t(String key) => tr(widget.language, key);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(inspect());
  }

  Future<void> inspect() async {
    if (!mounted || busy || statusBusy || !foreground) return;
    final generation = ++epoch;
    setState(() {
      busy = true;
      failed = false;
      observation = null;
      observedAt = null;
      status = null;
      statusObservedAt = null;
      statusFailed = false;
    });
    try {
      final result =
          await (widget.inspect ?? const PrinterDiscoveryClient().inspect)();
      if (mounted && foreground && generation == epoch) {
        setState(() {
          observation = result;
          observedAt = DateTime.now();
        });
      }
    } catch (_) {
      if (mounted && foreground && generation == epoch) {
        setState(() => failed = true);
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> inspectStatus() async {
    if (!mounted ||
        busy ||
        statusBusy ||
        !foreground ||
        observation?.serviceResolvable != true) {
      return;
    }
    final generation = epoch;
    setState(() {
      statusBusy = true;
      statusFailed = false;
      status = null;
      statusObservedAt = null;
    });
    try {
      final result = await const PrinterStatusClient().inspect();
      if (mounted && foreground && generation == epoch) {
        setState(() {
          status = result;
          statusObservedAt = DateTime.now();
        });
      }
    } catch (_) {
      if (mounted && foreground && generation == epoch) {
        setState(() => statusFailed = true);
      }
    } finally {
      if (mounted) setState(() => statusBusy = false);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    setState(() {
      if (!foreground) {
        ++epoch;
        observation = null;
        observedAt = null;
        failed = false;
        status = null;
        statusObservedAt = null;
        statusFailed = false;
      }
    });
  }

  @override
  void dispose() {
    ++epoch;
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final data = observation;
    String flag(bool value) =>
        t(value ? 'printerDetected' : 'printerNotDetected');
    return AlertDialog(
      title: Text(t('printerInspectTitle')),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(t('printerInspectNotice')),
              const SizedBox(height: 12),
              if (busy) const LinearProgressIndicator(),
              if (failed)
                Text(
                  t('printerInspectFailed'),
                  key: const ValueKey('printer-inspect-failed'),
                ),
              if (!busy && !failed && data == null)
                Text(t('printerInspectStale')),
              if (data != null) ...[
                Text(
                  '${t('printerServiceInstalled')}: ${flag(data.serviceInstalled)}',
                ),
                Text(
                  '${t('printerServiceEnabled')}: ${flag(data.serviceEnabled)}',
                ),
                Text(
                  '${t('printerServiceResolvable')}: ${flag(data.serviceResolvable)}',
                ),
                Text(
                  '${t('printerServiceVersion')}: ${data.serviceVersion ?? t('printerUnknown')}',
                ),
                Text(
                  '${t('printerUsbCandidates')}: ${data.usbPrinterCandidates}',
                ),
                Text('${t('printerObservedAt')}: ${observedAt!.toLocal()}'),
                for (final usb in data.usbPrinters) ...[
                  const Divider(),
                  Text('USB ${usb.vendorProduct}'),
                  Text(
                    '${t('printerUsbPermission')}: ${flag(usb.hasPermission)}',
                  ),
                  for (final interface in usb.interfaces)
                    Text(
                      '${t('printerUsbInterface')} ${interface.id}/${interface.alternate} '
                      '(${interface.classCode}/${interface.subclass}/${interface.protocol}) · '
                      '${t('printerUsbBulkOut')}: ${flag(interface.hasBulkOutput)}',
                    ),
                ],
                if (data.usbPrinters.isNotEmpty) Text(t('printerUsbNotice')),
              ],
              const SizedBox(height: 12),
              Text(t('printerReadinessUnknown')),
              const Divider(),
              Text(t('printerStatusNotice')),
              if (statusBusy) const LinearProgressIndicator(),
              if (statusFailed)
                Text(
                  t('printerInspectFailed'),
                  key: const ValueKey('printer-status-failed'),
                ),
              if (status case final report?) ...[
                Text(
                  '${t('printerStatusReport')}: ${t(report.stateLabelKey)} (${report.statusCode ?? t('printerUnknown')})',
                  key: const ValueKey('printer-status-report'),
                ),
                Text(
                  '${t('printerPaperRaw')}: ${report.paperCode ?? t('printerUnknown')}',
                  key: const ValueKey('printer-paper-code'),
                ),
                Text(
                  '${t('printerObservedAt')}: ${statusObservedAt!.toLocal()}',
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('printer-inspect-close'),
          onPressed: () => Navigator.of(context).pop(),
          child: Text(t('printerInspectClose')),
        ),
        FilledButton(
          key: const ValueKey('printer-inspect-refresh'),
          onPressed: busy || statusBusy || !foreground
              ? null
              : () => unawaited(inspect()),
          child: Text(t('printerInspectRefresh')),
        ),
        OutlinedButton(
          key: const ValueKey('printer-status-inspect'),
          onPressed:
              busy ||
                  statusBusy ||
                  !foreground ||
                  data?.serviceResolvable != true
              ? null
              : () => unawaited(inspectStatus()),
          child: Text(t('printerStatusInspect')),
        ),
      ],
    );
  }
}
