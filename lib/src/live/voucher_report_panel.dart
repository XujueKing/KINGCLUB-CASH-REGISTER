import 'dart:async';

import 'package:flutter/material.dart';

import '../auth/staff_auth_controller.dart';
import '../strings.dart';
import 'voucher_report.dart';

class VoucherReportPanel extends StatefulWidget {
  const VoucherReportPanel({
    super.key,
    required this.auth,
    required this.language,
    required this.onBack,
  });
  final StaffAuthController auth;
  final UiLanguage language;
  final VoidCallback onBack;
  @override
  State<VoucherReportPanel> createState() => _VoucherReportPanelState();
}

class _VoucherReportPanelState extends State<VoucherReportPanel>
    with WidgetsBindingObserver {
  late DateTimeRange range;
  String provider = 'all';
  bool foreground = true, loading = false, failed = false;
  int epoch = 0;
  VoucherReport? report;
  Timer? expiry;
  final cursors = <String?>[null];
  int page = 0;
  String t(String key) => tr(widget.language, key);
  String day(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    range = DateTimeRange(start: now, end: now);
    foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    widget.auth.addListener(invalidate);
    if (foreground) unawaited(load());
  }

  void invalidate() {
    expiry?.cancel();
    ++epoch;
    if (mounted) {
      setState(() {
        report = null;
        loading = false;
        failed = false;
        cursors
          ..clear()
          ..add(null);
        page = 0;
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    invalidate();
    if (foreground) unawaited(load());
  }

  @override
  void didUpdateWidget(covariant VoucherReportPanel old) {
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
    ++epoch;
    widget.auth.removeListener(invalidate);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> load({int target = 0}) async {
    if (!mounted || !foreground) return;
    if (target == 0) {
      cursors
        ..clear()
        ..add(null);
    }
    if (target < 0 || target >= cursors.length) return;
    expiry?.cancel();
    final after = cursors[target];
    final generation = ++epoch,
        auth = widget.auth,
        session = widget.auth.session;
    final from = day(range.start),
        to = day(range.end),
        selectedProvider = provider;
    setState(() {
      report = null;
      loading = true;
      failed = false;
    });
    try {
      if (session == null ||
          !session.permissions.contains('report.read') ||
          !session.expiresAt.isAfter(DateTime.now())) {
        throw const FormatException();
      }
      // Expire already-rendered financial details as well as in-flight reads.
      expiry = Timer(session.expiresAt.difference(DateTime.now()), invalidate);
      final raw = await auth.readVoucherReport(
        from: from,
        to: to,
        provider: selectedProvider,
        afterVoucher: after,
      );
      if (!mounted ||
          !foreground ||
          generation != epoch ||
          !session.expiresAt.isAfter(DateTime.now()) ||
          !identical(auth, widget.auth) ||
          !identical(session, auth.session)) {
        return;
      }
      final parsed = VoucherReport.parse(
        raw,
        storeRef: session.storeRef,
        from: from,
        to: to,
        provider: selectedProvider,
        afterVoucher: after,
      );
      if (parsed.nextAfter != null &&
          cursors.take(target + 1).contains(parsed.nextAfter)) {
        throw const FormatException();
      }
      setState(() {
        report = parsed;
        page = target;
      });
    } catch (_) {
      if (mounted && foreground && generation == epoch) {
        setState(() => failed = true);
      }
    } finally {
      if (mounted && generation == epoch) setState(() => loading = false);
    }
  }

  Future<void> chooseDates() async {
    final generation = epoch;
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2000),
      lastDate: DateTime.now(),
      initialDateRange: range,
    );
    if (!mounted || !foreground || generation != epoch || picked == null) {
      return;
    }
    setState(() => range = picked);
    unawaited(load());
  }

  @override
  Widget build(BuildContext context) {
    final data = report;
    return Column(
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
              Text(t('voucherReportTitle')),
              OutlinedButton(
                onPressed: foreground && !loading && data != null && page > 0
                    ? () => unawaited(load(target: page - 1))
                    : null,
                child: Text(t('voucherReportPrevious')),
              ),
              OutlinedButton(
                onPressed: foreground && !loading && data?.nextAfter != null
                    ? () {
                        if (cursors.length > page + 1) {
                          cursors.removeRange(page + 1, cursors.length);
                        }
                        cursors.add(data!.nextAfter);
                        unawaited(load(target: page + 1));
                      }
                    : null,
                child: Text(t('voucherReportNext')),
              ),
              OutlinedButton(
                onPressed: foreground && !loading ? chooseDates : null,
                child: Text('${day(range.start)} — ${day(range.end)}'),
              ),
              for (final item in ['all', 'douyin', 'meituan'])
                ChoiceChip(
                  label: Text(t('voucherReport_$item')),
                  selected: provider == item,
                  onSelected: foreground && !loading
                      ? (_) {
                          setState(() => provider = item);
                          unawaited(load());
                        }
                      : null,
                ),
              OutlinedButton(
                onPressed: foreground && !loading
                    ? () => unawaited(load())
                    : null,
                child: Text(t('ordersRefresh')),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Text(t('voucherReportNotice')),
        ),
        if (loading) const LinearProgressIndicator(),
        Expanded(
          child: !foreground
              ? const SizedBox()
              : failed
              ? Center(child: Text(t('voucherReportFailed')))
              : data == null
              ? const SizedBox()
              : ListView(
                  padding: const EdgeInsets.all(20),
                  children: [
                    for (final key in VoucherReport.countKeys)
                      ListTile(
                        title: Text(t('voucherReport_$key')),
                        trailing: Text('${data.counts[key]}'),
                      ),
                    for (final key in VoucherReport.amountKeys)
                      ListTile(
                        title: Text(t('voucherReport_$key')),
                        trailing: Text('CNY ${data.money(key)}'),
                      ),
                    const Divider(),
                    Text(t('voucherReportDetailsNotice')),
                    for (final detail in data.details)
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${t('voucherReport_${detail.provider}')} · ${detail.certificateId}',
                              ),
                              if (detail.reversed)
                                Text(t('voucherReportReversed')),
                              Text(
                                '${t('voucherReportRedemptionDay')}: ${detail.redemptionDay ?? t('voucherReportUnknown')}',
                              ),
                              Text(
                                '${t('voucherReportExpectedDay')}: ${detail.expectedDay ?? t('voucherReportUnknown')}',
                              ),
                              for (final key in VoucherReportDetail.amountKeys)
                                Text(
                                  '${t('voucherDetail_$key')}: ${detail.money(key) == null ? t('voucherReportUnknown') : 'CNY ${detail.money(key)}'}',
                                ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}
