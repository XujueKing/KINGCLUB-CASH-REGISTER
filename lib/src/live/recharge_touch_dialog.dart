import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../auth/staff_auth_controller.dart';
import '../auth/session_vault.dart';
import '../hardware/scanner_input.dart';
import '../strings.dart';
import 'provider_payment.dart';

String rechargeText(UiLanguage l, String zh, String en, String tw, String th) =>
    switch (l) {
      UiLanguage.zh => zh,
      UiLanguage.en => en,
      UiLanguage.tw => tw,
      UiLanguage.th => th,
    };
String rechargeMoney(Object? value) =>
    ((int.tryParse('$value') ?? 0) / 100).toStringAsFixed(2);

class RechargeTouchDialog extends StatefulWidget {
  const RechargeTouchDialog({
    super.key,
    required this.auth,
    required this.language,
    required this.member,
    required this.campaigns,
    required this.newRequestId,
    this.storage,
  });
  final StaffAuthController auth;
  final UiLanguage language;
  final Map<String, dynamic> member;
  final List<Map<String, dynamic>> campaigns;
  final String Function() newRequestId;
  final SecretStorage? storage;
  @override
  State<RechargeTouchDialog> createState() => _RechargeTouchDialogState();
}

class _RechargeTouchDialogState extends State<RechargeTouchDialog> {
  late final storage = widget.storage ?? PlatformSecretStorage();
  late final original = widget.auth.session!;
  late final storageKey =
      'cash-recharge-v1:${original.base}:${original.storeRef}:${original.employeeRef}:${widget.member['userAccount']}';
  String amount = '0', error = '';
  Map<String, dynamic>? offer, pendingCash, paymentRow;
  bool storageReady = false;
  bool busy = true;
  String t(String zh, String en, String tw, String th) =>
      rechargeText(widget.language, zh, en, tw, th);
  int get cents => ((double.tryParse(amount) ?? 0) * 100).round();
  int get gift => int.tryParse('${offer?['giftCents']}') ?? 0;
  bool get valid => storageReady && cents > 0 && cents <= 100000000;
  bool get current {
    final s = widget.auth.session;
    return s != null &&
        s.base == original.base &&
        s.storeRef == original.storeRef &&
        s.employeeRef == original.employeeRef &&
        s.deviceId == original.deviceId;
  }

  Map<String, dynamic> get selection => {
    'targetAccount': widget.member['userAccount'],
    if (offer != null) ...{
      'campaignRef': offer!['campaignRef'],
      'campaignRevision': offer!['revision'],
    } else
      'principalCents': cents,
  };
  @override
  void initState() {
    super.initState();
    widget.auth.addListener(authChanged);
    unawaited(restore());
  }

  void authChanged() {
    if (mounted && !widget.auth.busy && !current) Navigator.pop(context);
  }

  @override
  void dispose() {
    widget.auth.removeListener(authChanged);
    super.dispose();
  }

  Future<void> restore() async {
    try {
      final raw = await storage.read(storageKey);
      if (!mounted) return;
      if (raw != null) {
        final saved = Map<String, dynamic>.from(jsonDecode(raw));
        if (saved['mode'] == 'provider') {
          paymentRow = Map<String, dynamic>.from(saved['row']);
          amount = rechargeMoney(paymentRow!['principalCents']);
        } else {
          pendingCash = saved;
          amount = rechargeMoney(saved['displayPrincipalCents']);
        }
      }
      storageReady = true;
    } catch (_) {
      error = t(
        '无法读取收款记录，请重新打开',
        'Cannot read collection record. Reopen.',
        '無法讀取收款記錄，請重新開啟',
        'อ่านบันทึกรับเงินไม่ได้ กรุณาเปิดใหม่',
      );
    }
    if (mounted) setState(() => busy = false);
  }

  void digit(String key) {
    if (busy || pendingCash != null || paymentRow != null) return;
    setState(() {
      offer = null;
      error = '';
      if (key == 'C') {
        amount = '0';
        return;
      }
      if (key == '⌫') {
        amount = amount.length > 1
            ? amount.substring(0, amount.length - 1)
            : '0';
        return;
      }
      if (key == '.') {
        if (!amount.contains('.')) amount += '.';
        return;
      }
      if (amount.contains('.') && amount.split('.').last.length >= 2) return;
      if (amount.replaceAll('.', '').length >= 9) return;
      amount = amount == '0' ? key : amount + key;
    });
  }

  Future<void> scan() async {
    if (busy || !valid || !current || pendingCash != null) return;
    setState(() => busy = true);
    try {
      final done = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => RechargeScanDialog(
          auth: widget.auth,
          language: widget.language,
          selection: selection,
          principalCents: cents,
          newRequestId: widget.newRequestId,
          row: paymentRow,
          onPrepared: (row) async {
            paymentRow = row;
            await storage.write(
              storageKey,
              jsonEncode({'mode': 'provider', 'row': row}),
            );
          },
        ),
      );
      if (!mounted) return;
      if (done == true) {
        await storage.delete(storageKey);
        if (!mounted) return;
        Navigator.pop(context, true);
        return;
      }
    } catch (_) {
      if (mounted)
        error = t(
          '请重新打开核对原充值',
          'Reopen to check original recharge',
          '請重新開啟核對原充值',
          'เปิดใหม่เพื่อตรวจสอบรายการเติมเงินเดิม',
        );
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> cash() async {
    if (busy ||
        !current ||
        !storageReady ||
        paymentRow != null ||
        (!valid && pendingCash == null))
      return;
    if (pendingCash == null) {
      final yes = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(
            t('确认收到现金', 'Confirm cash received', '確認收到現金', 'ยืนยันรับเงินสด'),
          ),
          content: Text(
            '¥ ${rechargeMoney(cents)}',
            style: const TextStyle(fontSize: 36, fontWeight: FontWeight.bold),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(t('取消', 'Cancel', '取消', 'ยกเลิก')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(
                t('已收到现金', 'Cash received', '已收到現金', 'รับเงินสดแล้ว'),
              ),
            ),
          ],
        ),
      );
      if (yes != true || !mounted || !current) return;
      pendingCash = {
        ...selection,
        'requestId': widget.newRequestId(),
        'displayPrincipalCents': cents,
        'displayGiftCents': gift,
      };
    }
    setState(() => busy = true);
    try {
      await storage.write(storageKey, jsonEncode(pendingCash));
      if (!mounted || !current) return;
      final params = {...pendingCash!}
        ..remove('displayPrincipalCents')
        ..remove('displayGiftCents');
      var result = await widget.auth.storeMembers({
        'action': 'cashLookup',
        ...params,
      });
      if (result['state'] == 'not_found') {
        result = await widget.auth.storeMembers({
          'action': 'cashConfirm',
          ...params,
        });
      }
      if (result['state'] != 'credited') throw StateError('Cash not confirmed');
      await storage.delete(storageKey);
      if (mounted && current) Navigator.pop(context, true);
    } catch (_) {
      if (mounted)
        setState(
          () => error = t(
            '现金入账未确认，请核对原收款',
            'Cash credit unconfirmed. Check original receipt.',
            '現金入帳未確認，請核對原收款',
            'ยังไม่ยืนยันยอดเงินสด โปรดตรวจสอบรายการเดิม',
          ),
        );
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = widget.language;
    final shownGift =
        paymentRow?['giftCents'] ?? pendingCash?['displayGiftCents'] ?? gift;
    return PopScope(
      canPop: !busy,
      child: Dialog(
        child: SizedBox(
          width: 900,
          height: 610,
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        t('会员充值', 'Member recharge', '會員充值', 'เติมเงินสมาชิก'),
                        style: const TextStyle(
                          fontSize: 26,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    Text(
                      '${widget.member['nickname'] ?? ''}  ${widget.member['memberId'] ?? ''}',
                      style: const TextStyle(fontSize: 16),
                    ),
                    IconButton(
                      onPressed: busy
                          ? null
                          : () => Navigator.pop(context, false),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              t(
                                '充值金额',
                                'Recharge amount',
                                '充值金額',
                                'ยอดเติมเงิน',
                              ),
                              style: const TextStyle(fontSize: 18),
                            ),
                            const SizedBox(height: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 18,
                                vertical: 16,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xffedf2ef),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Text(
                                '¥ $amount',
                                key: const ValueKey('recharge-amount'),
                                style: const TextStyle(
                                  fontSize: 40,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              child: Text(
                                '${t('赠送', 'Gift', '贈送', 'โบนัส')} ¥ ${rechargeMoney(shownGift)}',
                                key: const ValueKey('recharge-gift'),
                                style: const TextStyle(
                                  fontSize: 19,
                                  color: Color(0xff99701e),
                                ),
                              ),
                            ),
                            Expanded(
                              child: widget.campaigns.isEmpty
                                  ? Align(
                                      alignment: Alignment.topLeft,
                                      child: Text(
                                        t(
                                          '输入金额即可充值；赠送档位可在充值设置中添加',
                                          'Enter an amount. Add offers in recharge settings.',
                                          '輸入金額即可充值；贈送檔位可在充值設定中新增',
                                          'กรอกยอดเติมเงิน ตั้งค่าโปรโมชั่นได้ในการตั้งค่า',
                                        ),
                                      ),
                                    )
                                  : GridView.builder(
                                      itemCount: widget.campaigns.length,
                                      gridDelegate:
                                          const SliverGridDelegateWithFixedCrossAxisCount(
                                            crossAxisCount: 2,
                                            mainAxisSpacing: 12,
                                            crossAxisSpacing: 12,
                                            mainAxisExtent: 108,
                                          ),
                                      itemBuilder: (_, i) {
                                        final c = widget.campaigns[i];
                                        final selected =
                                            offer?['campaignRef'] ==
                                            c['campaignRef'];
                                        return OutlinedButton(
                                          key: ValueKey('recharge-offer-$i'),
                                          onPressed:
                                              busy ||
                                                  pendingCash != null ||
                                                  paymentRow != null
                                              ? null
                                              : () => setState(() {
                                                  offer = c;
                                                  amount = rechargeMoney(
                                                    c['principalCents'],
                                                  );
                                                  error = '';
                                                }),
                                          style: OutlinedButton.styleFrom(
                                            backgroundColor: selected
                                                ? const Color(0xfffff2cc)
                                                : null,
                                            side: BorderSide(
                                              color: selected
                                                  ? const Color(0xffc59c39)
                                                  : const Color(0xffcbd4cf),
                                              width: selected ? 2 : 1,
                                            ),
                                            shape: RoundedRectangleBorder(
                                              borderRadius:
                                                  BorderRadius.circular(12),
                                            ),
                                          ),
                                          child: FittedBox(
                                            fit: BoxFit.scaleDown,
                                            child: Column(
                                            mainAxisAlignment:
                                                MainAxisAlignment.center,
                                            children: [
                                              Text(
                                                '${t('充', 'Pay', '充', 'เติม')} ${rechargeMoney(c['principalCents'])}',
                                                style: const TextStyle(
                                                  fontSize: 24,
                                                  fontWeight: FontWeight.bold,
                                                ),
                                              ),
                                              const SizedBox(height: 6),
                                              Text(
                                                '${t('送', 'Gift', '送', 'โบนัส')} ${rechargeMoney(c['giftCents'])}',
                                                style: const TextStyle(
                                                  fontSize: 18,
                                                ),
                                              ),
                                            ],
                                            ),
                                          ),
                                        );
                                      },
                                    ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 24),
                      SizedBox(
                        width: 330,
                        child: Column(
                          children: [
                            Expanded(
                              child: GridView.count(
                                physics: const NeverScrollableScrollPhysics(),
                                crossAxisCount: 3,
                                mainAxisSpacing: 10,
                                crossAxisSpacing: 10,
                                childAspectRatio: 1.35,
                                children: [
                                  for (final key in [
                                    '1',
                                    '2',
                                    '3',
                                    '4',
                                    '5',
                                    '6',
                                    '7',
                                    '8',
                                    '9',
                                    '.',
                                    '0',
                                    '⌫',
                                  ])
                                    OutlinedButton(
                                      key: ValueKey('recharge-key-$key'),
                                      onPressed:
                                          busy ||
                                              pendingCash != null ||
                                              paymentRow != null
                                          ? null
                                          : () => digit(key),
                                      style: OutlinedButton.styleFrom(
                                        backgroundColor: Colors.white,
                                        side: const BorderSide(
                                          color: Color(0xffd4dbd6),
                                        ),
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(
                                            12,
                                          ),
                                        ),
                                      ),
                                      child: Text(
                                        key,
                                        style: const TextStyle(
                                          fontSize: 30,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                            TextButton(
                              onPressed:
                                  busy ||
                                      pendingCash != null ||
                                      paymentRow != null
                                  ? null
                                  : () => digit('C'),
                              child: Text(
                                t(
                                  '清空金额',
                                  'Clear amount',
                                  '清空金額',
                                  'ล้างยอดเงิน',
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                if (error.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      error,
                      style: const TextStyle(color: Colors.red),
                    ),
                  ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: SizedBox(
                        height: 60,
                        child: FilledButton.icon(
                          key: const ValueKey('recharge-scan-pay'),
                          onPressed:
                              busy ||
                                  !valid ||
                                  pendingCash != null ||
                                  ![
                                    'payment.wechat',
                                    'payment.alipay',
                                  ].any(original.permissions.contains)
                              ? null
                              : scan,
                          icon: const Icon(Icons.qr_code_scanner),
                          label: Text(
                            rechargeText(
                              l,
                              '微信支付宝付款',
                              'WeChat / Alipay',
                              '微信支付寶付款',
                              'WeChat / Alipay',
                            ),
                            style: const TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      flex: 2,
                      child: SizedBox(
                        height: 60,
                        child: OutlinedButton.icon(
                          key: const ValueKey('recharge-cash-pay'),
                          onPressed:
                              busy ||
                                  (!valid && pendingCash == null) ||
                                  paymentRow != null ||
                                  !storageReady ||
                                  !original.permissions.contains('payment.cash')
                              ? null
                              : cash,
                          icon: const Icon(Icons.payments_outlined),
                          label: Text(
                            pendingCash == null
                                ? t('现金收款', 'Cash', '現金收款', 'รับเงินสด')
                                : t(
                                    '核对现金入账',
                                    'Check cash credit',
                                    '核對現金入帳',
                                    'ตรวจสอบยอดเงินสด',
                                  ),
                            style: const TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Payment code selects the channel before preparing the original recharge.
/// Raw codes stay in memory; collectRecharge journals only the original reference.
class RechargeScanDialog extends StatefulWidget {
  const RechargeScanDialog({
    super.key,
    required this.auth,
    required this.language,
    this.selection,
    this.principalCents,
    this.newRequestId,
    this.row,
    this.onPrepared,
  });
  final StaffAuthController auth;
  final UiLanguage language;
  final Map<String, dynamic>? selection, row;
  final int? principalCents;
  final String Function()? newRequestId;
  final Future<void> Function(Map<String, dynamic>)? onPrepared;
  @override
  State<RechargeScanDialog> createState() => _RechargeScanDialogState();
}

class _RechargeScanDialogState extends State<RechargeScanDialog>
    with WidgetsBindingObserver {
  Map<String, dynamic>? row;
  bool busy = false, canScan = true, foreground = true;
  String error = '';
  Timer? timer;
  StreamSubscription<String>? scans;
  final input = TextEditingController();
  late final original = widget.auth.session!;
  late final requestId = widget.newRequestId?.call();
  String t(String zh, String en, String tw, String th) =>
      rechargeText(widget.language, zh, en, tw, th);
  bool get current {
    final s = widget.auth.session;
    return s != null &&
        s.base == original.base &&
        s.storeRef == original.storeRef &&
        s.employeeRef == original.employeeRef &&
        s.deviceId == original.deviceId;
  }

  @override
  void initState() {
    super.initState();
    row = widget.row;
    WidgetsBinding.instance.addObserver(this);
    widget.auth.addListener(authChanged);
    scans = ScannerInput.codes.listen((value) {
      if (mounted && foreground && ModalRoute.of(context)?.isCurrent == true)
        unawaited(pay(value));
    });
    if (row != null) {
      canScan = false;
      unawaited(check());
    }
  }

  void authChanged() {
    if (mounted && !widget.auth.busy && !current) Navigator.pop(context, false);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    input.clear();
    if (!foreground)
      timer?.cancel();
    else if (row != null)
      unawaited(check());
  }

  @override
  void dispose() {
    scans?.cancel();
    timer?.cancel();
    input.dispose();
    widget.auth.removeListener(authChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> check() async {
    if (busy || !mounted || !foreground || row == null || !current) return;
    timer?.cancel();
    setState(() => busy = true);
    try {
      final pending = await widget.auth.pendingRecharges(row!['channel']);
      final commands = pending.where(
        (c) => c.rechargeRef == row!['rechargeRef'],
      );
      final r = commands.isNotEmpty
          ? await widget.auth.recoverRecharge(commands.first)
          : await widget.auth.queryRecharge(
              row!['rechargeRef'],
              channel: row!['channel'],
            );
      if (!mounted || !current) return;
      if (r.credited) {
        Navigator.pop(context, true);
        return;
      }
      canScan = r.state == 'not_sent';
      error = canScan
          ? ''
          : t(
              '正在确认付款结果',
              'Checking payment',
              '正在確認付款結果',
              'กำลังตรวจสอบการชำระเงิน',
            );
      if (!canScan) timer = Timer(const Duration(seconds: 3), check);
    } catch (_) {
      error = t(
        '暂未确认付款，请查询原记录',
        'Payment unconfirmed. Check original record.',
        '暫未確認付款，請查詢原記錄',
        'ยังไม่ยืนยันการชำระเงิน กรุณาตรวจสอบรายการเดิม',
      );
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> pay(String value) async {
    if (busy || !canScan || !foreground || !current) return;
    final channel = validProviderCode('wechat', value)
        ? 'wechat'
        : validProviderCode('alipay', value)
        ? 'alipay'
        : null;
    if (channel == null) return;
    input.clear();
    if (!original.permissions.contains('payment.$channel')) {
      setState(
        () => error = t(
          '当前员工没有此收款权限',
          'Collection permission required',
          '當前員工沒有此收款權限',
          'ไม่มีสิทธิ์รับเงินช่องทางนี้',
        ),
      );
      return;
    }
    if (row != null && row!['channel'] != channel) {
      setState(
        () => error = t(
          '请使用原充值单的付款方式',
          'Use the original payment channel',
          '請使用原充值單的付款方式',
          'กรุณาใช้ช่องทางชำระเงินเดิม',
        ),
      );
      return;
    }
    setState(() {
      busy = true;
      error = '';
    });
    try {
      row ??= await widget.auth.storeMembers({
        'action': 'prepare',
        ...widget.selection!,
        'requestId': requestId,
        'channel': channel,
      });
      await widget.onPrepared?.call(row!);
      if (!mounted || !foreground || !current) return;
      canScan = false;
      final pending = await widget.auth.pendingRecharges(channel);
      final commands = pending.where(
        (c) => c.rechargeRef == row!['rechargeRef'],
      );
      final result = commands.isNotEmpty
          ? await widget.auth.sendUnsentRecharge(
              commands.first,
              authCode: value,
              stillCurrent: () => mounted && foreground && current,
            )
          : await widget.auth.collectRecharge(
              rechargeRef: row!['rechargeRef'],
              channel: channel,
              principalCents: int.parse('${row!['principalCents']}'),
              authCode: value,
              stillCurrent: () => mounted && foreground && current,
            );
      if (result.credited && mounted && current) {
        Navigator.pop(context, true);
        return;
      }
    } catch (_) {
      error = t(
        '收款尚未完成，请检查原记录或门店支付配置',
        'Collection incomplete. Check original record or store payment settings.',
        '收款尚未完成，請檢查原記錄或門店支付設定',
        'รับเงินไม่สำเร็จ ตรวจสอบรายการเดิมหรือการตั้งค่าร้าน',
      );
    } finally {
      if (mounted) setState(() => busy = false);
    }
    if (mounted && row != null) await check();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: AlertDialog(
      title: Text(
        t('微信支付宝付款', 'WeChat / Alipay', '微信支付寶付款', 'WeChat / Alipay'),
      ),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '¥ ${rechargeMoney(row?['principalCents'] ?? widget.principalCents)}',
              style: const TextStyle(fontSize: 40, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 24),
            const Icon(Icons.qr_code_scanner, size: 72),
            const SizedBox(height: 16),
            Text(
              t(
                '请顾客出示微信或支付宝付款码',
                'Scan customer WeChat or Alipay payment code',
                '請顧客出示微信或支付寶付款碼',
                'สแกนรหัสชำระเงิน WeChat หรือ Alipay ของลูกค้า',
              ),
              style: const TextStyle(fontSize: 20),
            ),
            const SizedBox(height: 16),
            if (canScan)
              TextField(
                controller: input,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                autofillHints: null,
                decoration: InputDecoration(
                  labelText: t(
                    '付款码（也可直接扫码）',
                    'Payment code (or scan directly)',
                    '付款碼（也可直接掃碼）',
                    'รหัสชำระเงิน (หรือสแกนได้เลย)',
                  ),
                ),
                onSubmitted: pay,
                onChanged: (v) {
                  if (validProviderCode('wechat', v)) unawaited(pay(v));
                },
              ),
            if (error.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Text(error),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: busy ? null : () => Navigator.pop(context, false),
          child: Text(t('关闭', 'Close', '關閉', 'ปิด')),
        ),
        if (row != null)
          TextButton(
            onPressed: busy ? null : check,
            child: Text(
              t('查询付款', 'Check payment', '查詢付款', 'ตรวจสอบการชำระเงิน'),
            ),
          ),
      ],
    ),
  );
}
