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
        backgroundColor: const Color(0xfffafbf8),
        child: SizedBox(
          width: 640,
          height: MediaQuery.sizeOf(context).height * 0.8,
          child: VoucherWorkspacePanel(
            auth: auth,
            language: language,
            tableName: tableName,
            tableRef: tableRef,
            sessionRef: sessionRef,
            onClose: () => Navigator.pop(context),
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
    this.onClose,
  });
  final StaffAuthController auth;
  final UiLanguage language;
  final String? tableName, tableRef, sessionRef;
  final Stream<String>? scannerEvents;
  final VoidCallback? onClose;
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
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(32, 20, 20, 18),
        child: Row(
          children: [
            Text(
              localized('核券', 'Redeem', '核券', 'ใช้คูปอง'),
              style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w700),
            ),
            if (widget.tableName != null) ...[
              const SizedBox(width: 16),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 180),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xffe8efea),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    widget.tableName!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ],
            const Spacer(),
            if (widget.onClose != null)
              IconButton(
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                onPressed: widget.onClose,
                icon: const Icon(Icons.close, size: 26),
              ),
          ],
        ),
      ),
      const Divider(height: 1, thickness: 1, indent: 32, endIndent: 32),
      Expanded(
        child: channel != 'wine' && result == null
            ? Column(
                children: [
                  Expanded(
                    child: Center(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 28,
                          vertical: 24,
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const ScanIcon(size: 88, color: Color(0xff234c3f)),
                            const SizedBox(height: 28),
                            Text(
                              busy
                                  ? t('voucherReading')
                                  : localized(
                                      '请出示券码或取酒码',
                                      'Present a voucher or pickup code',
                                      '請出示券碼或取酒碼',
                                      'แสดงรหัสคูปองหรือรับเครื่องดื่ม',
                                    ),
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontSize: 23,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 16),
                            Text(
                              localized(
                                '将顾客的团购券、KING 券或取酒码对准扫码器\n系统自动识别类型，请核对后完成操作',
                                'Scan the guest’s voucher or wine pickup code.\nThe code type is identified automatically; review to continue.',
                                '將顧客的團購券、KING 券或取酒碼對準掃碼器\n系統自動識別類型，請核對後完成操作',
                                'สแกนคูปองหรือรหัสรับเครื่องดื่มของลูกค้า\nระบบจะแยกประเภทรหัสอัตโนมัติ โปรดตรวจสอบก่อนดำเนินการ',
                              ),
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontSize: 16,
                                height: 1.9,
                                color: Color(0xff6b7871),
                              ),
                            ),
                            if (message != null) ...[
                              const SizedBox(height: 16),
                              Text(t(message!), textAlign: TextAlign.center),
                            ],
                            if (message == 'voucherChooseChannel') ...[
                              const SizedBox(height: 16),
                              channelChoices(),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                  channelMarks(),
                ],
              )
            : channel == 'wine'
            ? WinePickupPanel(
                key: ValueKey(
                  'wine/${widget.tableRef}/${widget.sessionRef}/${widget.auth.session?.employeeRef}',
                ),
                auth: widget.auth,
                language: widget.language,
                tableRef: widget.tableRef,
                sessionRef: widget.sessionRef,
                scannerEvents: wineCodes.stream,
                initialCode: wineInitialCode,
                fillHeight: true,
                onDone: widget.onClose,
              )
            : details(),
      ),
    ],
  );

  Widget channelChoices() => Wrap(
    spacing: 12,
    runSpacing: 12,
    alignment: WrapAlignment.center,
    children: [
      for (final item in ['douyin', 'meituan', 'king'])
        OutlinedButton(
          style: OutlinedButton.styleFrom(minimumSize: const Size(100, 48)),
          onPressed: () => setState(() => channel = item),
          child: Text(t('voucherChannel_$item')),
        ),
    ],
  );

  Widget channelMarks() {
    const ink = Color(0xff7a8680);
    Widget mark(Widget icon, String label) => Expanded(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(height: 32, child: Center(child: icon)),
          const SizedBox(height: 8),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, color: ink),
          ),
        ],
      ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 0, 28, 26),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Divider(height: 1, thickness: 1, color: Color(0xffe3e8e3)),
          const SizedBox(height: 22),
          Row(
            children: [
              mark(
                const Icon(Icons.tiktok, size: 29, color: ink),
                localized('抖音', 'Douyin', '抖音', 'Douyin'),
              ),
              mark(
                const Text(
                  '美团',
                  style: TextStyle(
                    fontSize: 21,
                    fontWeight: FontWeight.w800,
                    color: ink,
                  ),
                ),
                localized('美团', 'Meituan', '美團', 'Meituan'),
              ),
              mark(
                Image.asset(
                  'assets/brand/kingclub-gold.png',
                  width: 54,
                  height: 30,
                  color: ink,
                  colorBlendMode: BlendMode.srcIn,
                  fit: BoxFit.contain,
                ),
                localized(
                  '平台优惠券',
                  'Platform coupons',
                  '平台優惠券',
                  'คูปองแพลตฟอร์ม',
                ),
              ),
              mark(
                Image.asset(
                  'assets/brand/kingclub-gold.png',
                  width: 54,
                  height: 30,
                  color: ink,
                  colorBlendMode: BlendMode.srcIn,
                  fit: BoxFit.contain,
                ),
                localized(
                  '本店会员卡',
                  'Store member card',
                  '本店會員卡',
                  'บัตรสมาชิกร้าน',
                ),
              ),
              mark(
                const Icon(Icons.wine_bar_outlined, size: 30, color: ink),
                localized('取酒', 'Wine pickup', '取酒', 'รับเครื่องดื่ม'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget details() => ListView(
    padding: const EdgeInsets.all(24),
    children: [
      if (message == 'voucherChooseChannel') channelChoices(),
      if (busy) Text(t('voucherReading'), textAlign: TextAlign.center),
      if (message != null)
        Padding(
          padding: const EdgeInsets.only(top: 16),
          child: Text(t(message!), textAlign: TextAlign.center),
        ),
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
