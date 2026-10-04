import 'dart:async';

import 'package:flutter/material.dart';

import '../auth/staff_auth_controller.dart';
import '../hardware/scanner_input.dart';
import '../network/ccsop_client.dart';
import '../strings.dart';
import 'provider_payment.dart';
import 'voucher_group_admission_card.dart';

/// Scan/preview only until official confirmation and table fulfillment are wired.
/// A prepared package never appears in the bill as a completed redemption.
class VoucherWorkspacePanel extends StatefulWidget {
  const VoucherWorkspacePanel({
    super.key,
    required this.auth,
    required this.language,
    this.tableName,
    this.scannerEvents,
  });
  final StaffAuthController auth;
  final UiLanguage language;
  final String? tableName;
  final Stream<String>? scannerEvents;
  @override
  State<VoucherWorkspacePanel> createState() => _VoucherWorkspacePanelState();
}

class _VoucherWorkspacePanelState extends State<VoucherWorkspacePanel>
    with WidgetsBindingObserver {
  StreamSubscription<String>? scanner;
  Timer? expiry;
  String? channel, message;
  Map<String, dynamic>? result;
  bool busy = false, foreground = true;
  int epoch = 0;
  final choices = <String, Set<String>>{};
  String t(String key) => tr(widget.language, key);
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.auth.addListener(clear);
    foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    scanner = (widget.scannerEvents ?? ScannerInput.codes).listen(
      (value) {
        if (mounted &&
            foreground &&
            !busy &&
            ModalRoute.of(context)?.isCurrent == true)
          unawaited(scan(value.trim()));
      },
      onError: (Object error) {
        if (mounted) setState(() => message = 'voucherScanFailed');
      },
    );
  }

  void clear() {
    expiry?.cancel();
    epoch++;
    if (mounted)
      setState(() {
        busy = false;
        result = null;
        choices.clear();
        message = null;
        channel = null;
      });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    clear();
  }

  @override
  void didUpdateWidget(covariant VoucherWorkspacePanel old) {
    super.didUpdateWidget(old);
    if (old.auth != widget.auth) {
      old.auth.removeListener(clear);
      widget.auth.addListener(clear);
      clear();
    } else if (old.tableName != widget.tableName)
      clear();
  }

  @override
  void dispose() {
    expiry?.cancel();
    epoch++;
    unawaited(scanner?.cancel());
    widget.auth.removeListener(clear);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> scan(String value) async {
    if (!foreground || busy || value.isEmpty) return;
    // Never forward payment or member identity credentials to a voucher provider.
    if (value.length > 8192 ||
        value.startsWith('KC:') ||
        value.startsWith('KCPAY') ||
        validProviderCode('wechat', value) ||
        validProviderCode('alipay', value)) {
      setState(() {
        result = null;
        choices.clear();
        message = 'voucherWrongCode';
      });
      return;
    }
    final uri = Uri.tryParse(value);
    final detected = uri?.scheme == 'https' && uri?.host == 'v.douyin.com'
        ? 'douyin'
        : null;
    final selected = detected ?? channel;
    if (selected == null) {
      setState(() => message = 'voucherChooseChannel');
      return;
    }
    if (selected != 'douyin') {
      setState(() => message = 'voucherChannelPending');
      return;
    }
    if (widget.auth.session?.permissions.contains('voucher.douyin') != true) {
      setState(() => message = 'staffAuthFailure');
      return;
    }
    final current = ++epoch;
    expiry?.cancel();
    expiry = Timer(const Duration(seconds: 30), () {
      if (mounted && epoch == current) {
        epoch++;
        setState(() {
          busy = false;
          result = null;
          choices.clear();
          message = 'voucherScanExpired';
        });
      }
    });
    setState(() {
      channel = selected;
      busy = true;
      message = null;
      result = null;
      choices.clear();
    });
    try {
      final data = await widget.auth.prepareDouyinVoucher(value);
      if (mounted && foreground && epoch == current)
        setState(() => result = data);
    } catch (error) {
      if (mounted && epoch == current)
        setState(
          () => message =
              error is CcsopFailure &&
                  error.code == 'DOUYIN_PREPARATION_NOT_ENABLED'
              ? 'voucherChannelPending'
              : 'voucherScanFailed',
        );
    } finally {
      if (mounted && epoch == current) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      Row(
        children: [
          Text(
            t('voucherWorkspace'),
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
          ),
          if (widget.tableName != null) ...[
            const SizedBox(width: 16),
            Text(widget.tableName!),
          ],
        ],
      ),
      const SizedBox(height: 20),
      Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          for (final item in ['douyin', 'meituan', 'king', 'wine'])
            SizedBox(
              width: 150,
              height: 76,
              child: OutlinedButton.icon(
                key: ValueKey('voucher-channel-$item'),
                style: OutlinedButton.styleFrom(
                  backgroundColor: channel == item
                      ? const Color(0xffe8eee8)
                      : null,
                ),
                onPressed: busy
                    ? null
                    : () => setState(() {
                        epoch++;
                        channel = item;
                        result = null;
                        choices.clear();
                        message = item == 'douyin'
                            ? null
                            : 'voucherChannelPending';
                      }),
                icon: Icon(
                  item == 'wine'
                      ? Icons.wine_bar_outlined
                      : Icons.confirmation_number_outlined,
                ),
                label: Text(t('voucherChannel_$item')),
              ),
            ),
        ],
      ),
      const SizedBox(height: 28),
      const Icon(Icons.qr_code_scanner, size: 48),
      const SizedBox(height: 12),
      Text(
        t(busy ? 'voucherReading' : 'voucherScanHint'),
        textAlign: TextAlign.center,
      ),
      if (message != null)
        Padding(
          padding: const EdgeInsets.only(top: 16),
          child: Text(t(message!), textAlign: TextAlign.center),
        ),
      if (result != null) ...[
        const SizedBox(height: 16),
        Text(t('voucherPreviewOnly')),
        if ((result!['packages'] as List? ?? []).isEmpty)
          Text(t('voucherNoPackage')),
        for (final raw in result!['packages'] as List? ?? [])
          packageCard(Map<String, dynamic>.from(raw as Map)),
      ],
    ],
  );
  Widget packageCard(Map<String, dynamic> package) {
    if (package['state'] != 'mapped')
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(t('voucherNoPackage')),
        ),
      );
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              package['title'] as String? ?? t('voucherPackage'),
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            if (package['groupAdmission'] is Map)
              VoucherGroupAdmissionCard(
                key: ValueKey(
                  '${epoch}:${package['selectionIndex']}:${package['revision']}',
                ),
                data: Map<String, dynamic>.from(
                  package['groupAdmission'] as Map,
                ),
                language: widget.language,
              ),
            for (final line in package['lines'] as List)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Text('${line['name']} × ${line['quantity']}'),
              ),
            for (final group in package['choiceGroups'] as List) ...[
              const Divider(),
              Text('${group['name']} (${group['choose']})'),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final option in group['options'] as List)
                    Builder(
                      builder: (context) {
                        final key =
                            '${package['selectionIndex']}:${group['groupRef']}';
                        final selected = choices.putIfAbsent(key, () => {});
                        final ref = option['productRef'] as String;
                        return FilterChip(
                          label: Text(
                            '${option['name']} × ${option['quantity']}',
                          ),
                          selected: selected.contains(ref),
                          onSelected: (on) {
                            if (on && selected.length >= group['choose'])
                              return;
                            setState(() {
                              if (on) {
                                selected.add(ref);
                              } else {
                                selected.remove(ref);
                              }
                            });
                          },
                        );
                      },
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
