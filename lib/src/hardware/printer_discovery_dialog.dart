import 'dart:async';

import 'package:flutter/material.dart';

import '../strings.dart';
import 'printer_discovery.dart';

/// Read-only device metadata, accessible without a store/employee login.
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
    if (!mounted || busy || !foreground) return;
    final generation = ++epoch;
    setState(() {
      busy = true;
      failed = false;
      observation = null;
      observedAt = null;
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

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    setState(() {
      if (!foreground) {
        ++epoch;
        observation = null;
        observedAt = null;
        failed = false;
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
              ],
              const SizedBox(height: 12),
              Text(t('printerReadinessUnknown')),
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
          onPressed: busy || !foreground ? null : () => unawaited(inspect()),
          child: Text(t('printerInspectRefresh')),
        ),
      ],
    );
  }
}
