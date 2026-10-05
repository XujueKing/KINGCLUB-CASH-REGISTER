import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import '../scan_icon.dart';

import '../auth/staff_auth_controller.dart';
import '../hardware/scanner_input.dart';
import '../network/ccsop_client.dart';
import '../strings.dart';
import 'provider_payment.dart';
import 'voucher_group_admission_card.dart';
import 'wine_pickup_panel.dart';

/// Redeem against the selected bill without replacing the ordering workspace.
class VoucherScanButton extends StatelessWidget {
  const VoucherScanButton({
    super.key,
    required this.auth,
    required this.language,
    this.tableName,
    this.tableRef,
    this.sessionRef,
  });
  final StaffAuthController auth;
  final UiLanguage language;
  final String? tableName, tableRef, sessionRef;

  @override
  Widget build(BuildContext context) => IconButton(
    key: const ValueKey('bill-voucher-scan'),
    tooltip: tr(language, 'billVoucher'),
    icon: const ScanIcon(size: 24),
    onPressed: () => showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        child: SizedBox(
          width: 560,
          height: MediaQuery.sizeOf(context).height * 0.8,
          child: Column(
            children: [
              Align(
                alignment: Alignment.centerRight,
                child: IconButton(
                  tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ),
              Expanded(
                child: VoucherWorkspacePanel(
                  auth: auth,
                  language: language,
                  tableName: tableName,
                  tableRef: tableRef,
                  sessionRef: sessionRef,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// Official single-coupon redemption is separate from package fulfillment.
/// No preview or redemption alone adds AA drinks to the table bill.
class VoucherWorkspacePanel extends StatefulWidget {
  const VoucherWorkspacePanel({
    super.key,
    required this.auth,
    required this.language,
    this.tableName,
    this.tableRef,
    this.sessionRef,
    this.scannerEvents,
  });
  final StaffAuthController auth;
  final UiLanguage language;
  final String? tableName, tableRef, sessionRef;
  final Stream<String>? scannerEvents;
  @override
  State<VoucherWorkspacePanel> createState() => _VoucherWorkspacePanelState();
}

class _VoucherWorkspacePanelState extends State<VoucherWorkspacePanel>
    with WidgetsBindingObserver {
  StreamSubscription<String>? scanner;
  Timer? expiry;
  final wineCodes = StreamController<String>.broadcast();
  String? wineInitialCode;
  String? channel, message;
  Map<String, dynamic>? result;
  bool busy = false, foreground = true;
  int epoch = 0;
  String? confirmationId;
  int? confirmationIndex;
  String? confirmationMessage;
  bool confirmationFinished = false;
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
        wineInitialCode = null;
        confirmationId = null;
        confirmationIndex = null;
        confirmationMessage = null;
        confirmationFinished = false;
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
    } else if (old.tableName != widget.tableName ||
        old.tableRef != widget.tableRef ||
        old.sessionRef != widget.sessionRef)
      clear();
  }

  @override
  void dispose() {
    expiry?.cancel();
    epoch++;
    unawaited(wineCodes.close());
    unawaited(scanner?.cancel());
    widget.auth.removeListener(clear);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> scan(String value) async {
    if (!foreground ||
        busy ||
        value.isEmpty ||
        confirmationId != null && !confirmationFinished)
      return;
    if (RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(value) ||
        RegExp(r'^KC:W:[0-9A-F]{32}$').hasMatch(value)) {
      if (widget.tableRef == null || widget.sessionRef == null) {
        setState(() => message = 'voucherSelectTable');
        return;
      }
      if (channel == 'wine') {
        wineCodes.add(value);
      } else {
        setState(() {
          channel = 'wine';
          wineInitialCode = value;
          result = null;
          message = null;
        });
      }
      return;
    }
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
    final selected = detected ?? (channel == 'wine' ? null : channel);
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
    setState(() => channel = 'douyin');
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
      confirmationId = null;
      confirmationIndex = null;
      confirmationMessage = null;
      confirmationFinished = false;
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

  String localized(String zh, String en, String tw, String th) =>
      switch (widget.language) {
        UiLanguage.zh => zh,
        UiLanguage.en => en,
        UiLanguage.tw => tw,
        UiLanguage.th => th,
      };
  Future<void> confirm(int index) async {
    if (busy || result == null || confirmationFinished) return;
    final preparation = result!['preparationRef'];
    if (preparation is! String) return;
    if (confirmationId == null) {
      final bytes = List.generate(16, (_) => Random.secure().nextInt(256));
      bytes[6] = (bytes[6] & 15) | 64;
      bytes[8] = (bytes[8] & 63) | 128;
      final h = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      confirmationId =
          '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
      confirmationIndex = index;
    }
    if (confirmationIndex != index) return;
    expiry?.cancel();
    final current = epoch;
    setState(() => busy = true);
    try {
      final receipt = await widget.auth.confirmDouyinRedemption(
        preparationRef: preparation,
        requestId: confirmationId!,
        selectionIndex: index,
      );
      if (!mounted || epoch != current) return;
      setState(() {
        confirmationFinished = receipt['state'] == 'completed';
        final rows = (receipt['receipt'] as Map?)?['results'] as List? ?? [];
        confirmationMessage = confirmationFinished
            ? (rows.length == 1 && rows.first['result'] == 0
                  ? localized('核销成功', 'Redeemed', '核銷成功', 'ใช้คูปองสำเร็จ')
                  : localized(
                      '本次未核销成功',
                      'Redemption unsuccessful',
                      '本次未核銷成功',
                      'ใช้คูปองไม่สำเร็จ',
                    ))
            : localized(
                '正在确认核销结果',
                'Checking redemption result',
                '正在確認核銷結果',
                'กำลังตรวจสอบผล',
              );
      });
    } catch (_) {
      if (mounted && epoch == current)
        setState(
          () => confirmationMessage = localized(
            '结果尚未确认，请查询原结果',
            'Result unconfirmed. Check the original attempt.',
            '結果尚未確認，請查詢原結果',
            'ยังไม่ยืนยันผล โปรดตรวจสอบรายการเดิม',
          ),
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
            ['核券', 'Redeem', '核券', 'Redeem'][widget.language.index],
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
          ),
          if (widget.tableName != null) ...[
            const SizedBox(width: 16),
            Text(widget.tableName!),
          ],
        ],
      ),
      const SizedBox(height: 20),
      if (message == 'voucherChooseChannel')
        Wrap(
          spacing: 12,
          children: [
            for (final item in ['douyin', 'meituan', 'king'])
              OutlinedButton(
                onPressed: () => setState(() => channel = item),
                child: Text(t('voucherChannel_$item')),
              ),
          ],
        ),
      const SizedBox(height: 16),
      if (channel == 'wine')
        WinePickupPanel(
          key: ValueKey(
            'wine/${widget.tableRef}/${widget.sessionRef}/${widget.auth.session?.employeeRef}',
          ),
          auth: widget.auth,
          language: widget.language,
          tableRef: widget.tableRef,
          sessionRef: widget.sessionRef,
          scannerEvents: wineCodes.stream,
          initialCode: wineInitialCode,
        )
      else ...[
        const ScanIcon(size: 48),
        const SizedBox(height: 12),
        Text(
          busy
              ? t('voucherReading')
              : [
                  '请扫团购券、KING券或取酒码',
                  'Scan voucher or wine pickup code',
                  '請掃團購券、KING券或取酒碼',
                  'Scan voucher or pickup code',
                ][widget.language.index],
          textAlign: TextAlign.center,
        ),
        if (message != null)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Text(t(message!), textAlign: TextAlign.center),
          ),
      ],
      if (result != null) ...[
        const SizedBox(height: 16),
        if (confirmationMessage != null)
          Text(
            confirmationMessage!,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 20),
          ),
        for (final certificate
            in (result!['selection'] as Map?)?['certificates'] as List? ?? [])
          Card(
            child: Column(
              children: [
                if ((certificate['title'] as String? ?? '').contains('卡颜'))
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                    child: Image.asset(
                      'assets/products/kayan-bundle-a.png',
                      height: 190,
                      fit: BoxFit.contain,
                      semanticLabel: 'Package A drinks illustration',
                    ),
                  ),
                ListTile(
                  title: Text(
                    certificate['title'] as String? ?? t('voucherPackage'),
                  ),
                  subtitle: Text(
                    localized(
                      '核销记入当前登录门店',
                      'Recorded for the current store',
                      '核銷記入目前登入門店',
                      'บันทึกสำหรับร้านปัจจุบัน',
                    ),
                  ),
                  trailing: FilledButton(
                    onPressed:
                        busy ||
                            confirmationFinished ||
                            (confirmationIndex != null &&
                                confirmationIndex !=
                                    certificate['selectionIndex'])
                        ? null
                        : () => confirm(certificate['selectionIndex'] as int),
                    child: Text(
                      confirmationId == null
                          ? localized(
                              '确认核销',
                              'Redeem',
                              '確認核銷',
                              'ยืนยันใช้คูปอง',
                            )
                          : localized(
                              '查询结果',
                              'Check result',
                              '查詢結果',
                              'ตรวจสอบผล',
                            ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        if ((result!['packages'] as List? ?? []).isEmpty)
          Text(t('voucherNoPackage')),
        for (final raw in result!['packages'] as List? ?? [])
          if (raw['groupAdmission'] == null)
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
