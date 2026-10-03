import '../network/ccsop_client.dart';

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../auth/staff_auth_controller.dart';
import '../hardware/scanner_input.dart';
import '../strings.dart';
import 'table_checkout_command.dart';

class TableDiscountDialog extends StatefulWidget {
  const TableDiscountDialog({
    super.key,
    required this.auth,
    required this.quote,
    required this.language,
    required this.requestId,
    this.waive = false,
  });
  final StaffAuthController auth;
  final TableCheckoutQuote quote;
  final UiLanguage language;
  final String requestId;
  final bool waive;
  @override
  State<TableDiscountDialog> createState() => _TableDiscountDialogState();
}

class _TableDiscountDialogState extends State<TableDiscountDialog>
    with WidgetsBindingObserver {
  static const storage = FlutterSecureStorage();
  StreamSubscription<String>? scanner;
  Map<String, Object>? pending;
  late final String journalKey;
  int rate = 900, epoch = 0;
  bool busy = true, scanning = false, failed = false, foreground = true;
  String t(String key) => tr(widget.language, key);
  @override
  void initState() {
    super.initState();
    rate = widget.waive ? 0 : 900;
    final identity = widget.auth.session!;
    journalKey =
        'table-discount-v1:${base64Url.encode(utf8.encode(jsonEncode([identity.base.toString(), identity.storeRef, identity.employeeRef, widget.quote.sessionRef])))}';
    WidgetsBinding.instance.addObserver(this);
    widget.auth.addListener(invalidate);
    scanner = ScannerInput.codes.listen((code) {
      if (mounted &&
          scanning &&
          !busy &&
          foreground &&
          ModalRoute.of(context)?.isCurrent == true)
        unawaited(send(code));
    });
    unawaited(load());
  }

  void invalidate() {
    epoch++;
    if (mounted) Navigator.of(context).pop();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    if (!foreground) {
      epoch++;
      scanning = false;
      busy = false;
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    epoch++;
    scanner?.cancel();
    widget.auth.removeListener(invalidate);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> load() async {
    try {
      final raw = await storage.read(key: journalKey);
      if (!mounted) return;
      if (raw != null) {
        final row = Map<String, Object>.from(jsonDecode(raw) as Map);
        if (row['tableRef'] != widget.quote.tableRef ||
            row['sessionRef'] != widget.quote.sessionRef ||
            row['rate'] is! int ||
            row['requestId'] is! String ||
            row['expectedSnapshotFingerprint'] is! String ||
            row.length != 5)
          throw const FormatException();
        pending = row;
        rate = row['rate'] as int;
        await send(null);
      }
    } catch (_) {
      if (mounted) setState(() => failed = true);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> begin() async {
    if (busy || !foreground) return;
    setState(() {
      busy = true;
      failed = false;
    });
    try {
      pending ??= {
        'tableRef': widget.quote.tableRef,
        'sessionRef': widget.quote.sessionRef,
        'requestId': widget.requestId,
        'rate': rate,
        'expectedSnapshotFingerprint': widget.quote.fingerprint,
      };
      await storage.write(key: journalKey, value: jsonEncode(pending));
      if (mounted) setState(() => scanning = true);
    } catch (_) {
      if (mounted) setState(() => failed = true);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> send(String? code) async {
    if (pending == null || !foreground || !mounted) return;
    final ticket = epoch;
    setState(() {
      busy = true;
      failed = false;
    });
    try {
      final result = await widget.auth.adjustTableBill(
        pending!,
        identityCode: code,
        queryOnly: code == null,
      );
      if (result['state'] == 'applied') {
        await storage.delete(key: journalKey);
        if (mounted && ticket == epoch && foreground)
          Navigator.pop(context, result);
      } else if (mounted && ticket == epoch) {
        setState(() => scanning = true);
      }
    } catch (error) {
      if (error is CcsopFailure && error.code == 'ITEM_PRICE_STATE_CHANGED') {
        await storage.delete(key: journalKey);
        if (mounted && ticket == epoch) {
          Navigator.pop(context);
          return;
        }
      }
      if (mounted && ticket == epoch) setState(() => failed = true);
    } finally {
      if (mounted && ticket == epoch) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: AlertDialog(
      title: Text(t(rate == 0 ? 'checkoutWaive' : 'checkoutDiscount')),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(t('checkoutDiscountScope')),
            const SizedBox(height: 20),
            if (!scanning && pending == null)
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (final value in [
                    950,
                    900,
                    850,
                    800,
                    750,
                    700,
                    600,
                    500,
                    0,
                  ])
                    ChoiceChip(
                      label: Text(
                        value == 0 ? t('checkoutWaive') : '${value / 100} 折',
                      ),
                      selected: rate == value,
                      onSelected: busy
                          ? null
                          : (_) => setState(() => rate = value),
                    ),
                ],
              ),
            if (scanning) ...[
              const Icon(Icons.qr_code_scanner, size: 64),
              const SizedBox(height: 16),
              Text(t('checkoutManagerScan')),
            ],
            if (busy)
              const Padding(
                padding: EdgeInsets.all(16),
                child: CircularProgressIndicator(),
              ),
            if (failed)
              Text(
                t('checkoutDiscountFailed'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: busy ? null : () => Navigator.pop(context),
          child: Text(t('cancel')),
        ),
        if (pending != null)
          TextButton(
            onPressed: busy ? null : () => send(null),
            child: Text(t('checkoutDiscountQuery')),
          ),
        if (!scanning)
          FilledButton(
            onPressed: busy ? null : begin,
            child: Text(t('confirm')),
          ),
      ],
    ),
  );
}
