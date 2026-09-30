import 'dart:async';

import 'package:flutter/material.dart';

import '../auth/staff_auth_controller.dart';
import '../auth/staff_session.dart';
import '../strings.dart';
import 'voucher_lookup.dart';

class VoucherLookupPanel extends StatefulWidget {
  const VoucherLookupPanel({
    super.key,
    required this.auth,
    required this.language,
    required this.onBack,
  });
  final StaffAuthController auth;
  final UiLanguage language;
  final VoidCallback onBack;
  @override
  State<VoucherLookupPanel> createState() => _VoucherLookupPanelState();
}

class _VoucherLookupPanelState extends State<VoucherLookupPanel>
    with WidgetsBindingObserver {
  final request = TextEditingController();
  String? provider;
  int epoch = 0;
  bool foreground = true, busy = false, failed = false;
  VoucherLookup? result;
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
  }

  void invalidate() {
    expiry?.cancel();
    epoch++;
    request.clear();
    if (mounted) {
      setState(() {
        result = null;
        failed = false;
        busy = false;
        provider = null;
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    invalidate();
  }

  @override
  void didUpdateWidget(covariant VoucherLookupPanel old) {
    super.didUpdateWidget(old);
    if (old.auth != widget.auth) {
      old.auth.removeListener(invalidate);
      widget.auth.addListener(invalidate);
      invalidate();
    }
  }

  @override
  void dispose() {
    expiry?.cancel();
    epoch++;
    widget.auth.removeListener(invalidate);
    WidgetsBinding.instance.removeObserver(this);
    request.dispose();
    super.dispose();
  }

  Future<void> lookup() async {
    if (!foreground ||
        busy ||
        provider == null ||
        !uuidPattern.hasMatch(request.text)) {
      return;
    }
    final e = ++epoch,
        auth = widget.auth,
        session = widget.auth.session,
        channel = provider!,
        id = request.text;
    final remaining = session?.expiresAt.difference(DateTime.now());
    if (remaining == null || remaining <= Duration.zero) {
      invalidate();
      return;
    }
    expiry?.cancel();
    // Covers both an in-flight lookup and an already displayed receipt.
    // Expiry invalidates the generation without retrying the operation.
    expiry = Timer(remaining, invalidate);
    setState(() {
      busy = true;
      failed = false;
      result = null;
    });
    try {
      final value = await auth.lookupVoucher(provider: channel, requestId: id);
      if (mounted &&
          foreground &&
          e == epoch &&
          session!.expiresAt.isAfter(DateTime.now()) &&
          identical(auth, widget.auth) &&
          identical(session, auth.session)) {
        setState(() => result = value);
      }
    } catch (_) {
      if (mounted && foreground && e == epoch) setState(() => failed = true);
    } finally {
      if (mounted && e == epoch) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.all(16),
        child: Wrap(
          spacing: 16,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            OutlinedButton(
              onPressed: widget.onBack,
              child: Text(t('ordersBack')),
            ),
            Text(t('voucherLookupTitle')),
            for (final channel in ['douyin', 'meituan'])
              if (widget.auth.session?.permissions.contains(
                    'voucher.$channel',
                  ) ==
                  true)
                ChoiceChip(
                  label: Text(t('voucherReport_$channel')),
                  selected: provider == channel,
                  onSelected: foreground && !busy
                      ? (_) => setState(() {
                          provider = channel;
                          result = null;
                          failed = false;
                        })
                      : null,
                ),
          ],
        ),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Text(t('voucherLookupNotice')),
      ),
      Padding(
        padding: const EdgeInsets.all(20),
        child: TextField(
          controller: request,
          enabled: foreground && !busy,
          autocorrect: false,
          enableSuggestions: false,
          enableIMEPersonalizedLearning: false,
          autofillHints: null,
          decoration: InputDecoration(labelText: t('voucherLookupRequest')),
          onChanged: (_) => setState(() {
            result = null;
            failed = false;
          }),
          onSubmitted: (_) {},
          onEditingComplete: () {},
        ),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: OutlinedButton(
          onPressed:
              foreground &&
                  !busy &&
                  provider != null &&
                  uuidPattern.hasMatch(request.text)
              ? () => unawaited(lookup())
              : null,
          child: Text(t('voucherLookupRead')),
        ),
      ),
      if (busy) const LinearProgressIndicator(),
      Expanded(
        child: !foreground
            ? const SizedBox()
            : ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  if (failed) Text(t('voucherReportFailed')),
                  if (result != null) Text(t('voucherLookup_${result!.state}')),
                  if (result != null)
                    for (final row in result!.rows)
                      ListTile(
                        title: Text(
                          row.code == 0
                              ? t('voucherLookupSuccess')
                              : t('voucherLookupNotSuccess'),
                        ),
                        subtitle: Text(
                          row.code == 0
                              ? '${row.certificateId} · ${row.verifyId}'
                              : '${row.code}',
                        ),
                      ),
                ],
              ),
      ),
    ],
  );
}
