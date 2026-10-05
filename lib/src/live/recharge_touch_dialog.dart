import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../scan_icon.dart';

import '../auth/staff_auth_controller.dart';
import '../auth/session_vault.dart';
import '../hardware/scanner_input.dart';
import '../network/ccsop_client.dart';
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
      if (mounted) {
        error = t(
          '请重新打开核对原充值',
          'Reopen to check original recharge',
          '請重新開啟核對原充值',
          'เปิดใหม่เพื่อตรวจสอบรายการเติมเงินเดิม',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> cash({bool bank = false}) async {
    if (busy ||
        !current ||
        !storageReady ||
        paymentRow != null ||
        (!valid && pendingCash == null)) {
      return;
    }
    setState(() => busy = true);
    try {
      Map<String, dynamic> params() => {...pendingCash!}
        ..remove('displayPrincipalCents')
        ..remove('displayGiftCents');
      if (pendingCash != null) {
        final result = await widget.auth.storeMembers({
          'action': 'cashLookup',
          ...params(),
        });
        if (result['state'] == 'credited') {
          await storage.delete(storageKey);
          if (mounted && current) Navigator.pop(context, true);
          return;
        }
        if (result['state'] != 'not_found') {
          throw StateError('Receipt unresolved');
        }
        bank = pendingCash!['channel'] == 'bank_code';
      }
      final settings = bank
          ? await widget.auth.storeMembers({'action': 'receiptAccounts'})
          : null;
      final accounts = List<String>.from(
        settings?['receiptSettings']?['accounts'] ?? const [],
      );
      if (!mounted || !current) return;
      final done = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => RechargeOfflineReceiptDialog(
          language: widget.language,
          bank: bank,
          amountCents: pendingCash?['displayPrincipalCents'] ?? cents,
          accounts: accounts,
          account: pendingCash?['receivingAccount'] ?? '',
          confirm: (code, account) async {
            if (!current) throw const CcsopFailure('SESSION_REQUIRED');
            pendingCash ??= {
              ...selection,
              'requestId': widget.newRequestId(),
              'channel': bank ? 'bank_code' : 'cash',
              if (bank) 'receivingAccount': account,
              'displayPrincipalCents': cents,
              'displayGiftCents': gift,
            };
            if (bank) pendingCash!['receivingAccount'] = account;
            // Save only original scope. Raw employee QR remains in memory.
            await storage.write(storageKey, jsonEncode(pendingCash));
            if (!current) throw const CcsopFailure('SESSION_REQUIRED');
            var result = await widget.auth.storeMembers({
              'action': 'cashLookup',
              ...params(),
            });
            if (result['state'] == 'not_found') {
              result = await widget.auth.storeMembers({
                'action': 'cashConfirm',
                ...params(),
                'identityCode': code,
              });
            }
            if (result['state'] != 'credited') {
              throw StateError('Receipt unresolved');
            }
            await storage.delete(storageKey);
          },
        ),
      );
      if (done == true && mounted && current) Navigator.pop(context, true);
    } catch (_) {
      if (mounted) {
        setState(
          () => error = t(
            '请重新打开核对原收款',
            'Reopen to check the original receipt.',
            '請重新開啟核對原收款',
            'กรุณาเปิดใหม่เพื่อตรวจสอบรายการเดิม',
          ),
        );
      }
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
                          icon: const ScanIcon(),
                          label: Text(
                            rechargeText(
                              l,
                              '微信支付宝付款',
                              'WeChat / Alipay',
                              '微信支付寶付款',
                              'WeChat / Alipay',
                            ),
                            style: const TextStyle(
                              fontSize: 19,
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
                              : () => cash(),
                          icon: const Icon(Icons.payments_outlined),
                          label: Text(
                            pendingCash == null
                                ? t('现金收款', 'Cash', '現金收款', 'รับเงินสด')
                                : t(
                                    '核对收款',
                                    'Check receipt',
                                    '核對收款',
                                    'ตรวจสอบการรับเงิน',
                                  ),
                            style: const TextStyle(
                              fontSize: 19,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      flex: 3,
                      child: SizedBox(
                        height: 60,
                        child: OutlinedButton.icon(
                          key: const ValueKey('recharge-bank-pay'),
                          onPressed:
                              busy ||
                                  !valid ||
                                  pendingCash != null ||
                                  paymentRow != null ||
                                  !original.permissions.contains('payment.cash')
                              ? null
                              : () => cash(bank: true),
                          icon: const Icon(Icons.account_balance_outlined),
                          label: Text(
                            t(
                              '扫银行码支付',
                              'Bank QR payment',
                              '掃銀行碼支付',
                              'ชำระผ่าน QR ธนาคาร',
                            ),
                            style: const TextStyle(
                              fontSize: 19,
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

/// The employee scan attests an offline receipt; it does not debit a member.
class RechargeOfflineReceiptDialog extends StatefulWidget {
  const RechargeOfflineReceiptDialog({
    super.key,
    required this.language,
    required this.bank,
    required this.amountCents,
    required this.account,
    required this.accounts,
    required this.confirm,
  });
  final UiLanguage language;
  final bool bank;
  final List<String> accounts;
  final int amountCents;
  final String account;
  final Future<void> Function(String code, String account) confirm;
  @override
  State<RechargeOfflineReceiptDialog> createState() =>
      _RechargeOfflineReceiptDialogState();
}

class _RechargeOfflineReceiptDialogState
    extends State<RechargeOfflineReceiptDialog> {
  late String account = widget.accounts.contains(widget.account)
      ? widget.account
      : (widget.accounts.length == 1 ? widget.accounts.single : '');
  StreamSubscription<String>? subscription;
  bool busy = false, submitted = false;
  String? failureCode;
  bool get ready => !widget.bank || widget.accounts.contains(account);
  String failureMessage(String code) => switch (code) {
    'RECEIPT_ACCOUNT_REQUIRED' => t(
      '请先选择收款码，再扫员工会员码',
      'Select a payment QR option before scanning your staff code.',
      '請先選擇收款碼，再掃員工會員碼',
      'เลือกช่องทางรับเงินก่อนสแกนรหัสพนักงาน',
    ),
    'EMPLOYEE_CODE_FORMAT' || 'RECHARGE_EMPLOYEE_SCAN_REQUIRED' => t(
      '请出示收银员 KING APP 的会员码，不是付款码',
      'Scan the cashier’s KING member code, not a payment code.',
      '請出示收銀員 KING APP 的會員碼，不是付款碼',
      'สแกนรหัสสมาชิก KING ของพนักงาน ไม่ใช่รหัสชำระเงิน',
    ),
    'RECHARGE_EMPLOYEE_SCAN_MISMATCH' => t(
      '扫码会员与当前登录收银员不一致，请扫收银员本人的会员码',
      'This member is not the signed-in cashier. Scan the cashier’s own member code.',
      '掃碼會員與目前登入收銀員不一致，請掃收銀員本人的會員碼',
      'สมาชิกนี้ไม่ใช่พนักงานที่เข้าสู่ระบบ กรุณาสแกนรหัสของพนักงานเอง',
    ),
    'CASHIER_MEMBER_IDENTITY_INVALID' || 'MEMBER_QR_INVALID' => t(
      '会员码已失效，请在 KING APP 重新打开会员码后再扫',
      'Member code expired. Reopen the member code in KING APP and scan again.',
      '會員碼已失效，請在 KING APP 重新打開會員碼後再掃',
      'รหัสสมาชิกหมดอายุ เปิดรหัสใน KING APP ใหม่แล้วสแกนอีกครั้ง',
    ),
    'CASHIER_PERMISSION_DENIED' || 'CASHIER_STORE_FORBIDDEN' => t(
      '当前收银员没有本店收款权限，请由有权限的员工登录操作',
      'The signed-in cashier lacks receipt permission for this store.',
      '目前收銀員沒有本店收款權限，請由有權限的員工登入操作',
      'พนักงานที่เข้าสู่ระบบไม่มีสิทธิ์รับเงินสำหรับร้านนี้',
    ),
    'SESSION_REQUIRED' || 'SESSION_EXPIRED' || 'AUTH_SESSION_EXPIRED' => t(
      '收银员登录已失效，请重新登录后核对本笔充值',
      'Cashier session expired. Sign in again and check this recharge.',
      '收銀員登入已失效，請重新登入後核對本筆充值',
      'การเข้าสู่ระบบหมดอายุ เข้าสู่ระบบใหม่แล้วตรวจสอบรายการนี้',
    ),
    'RECHARGE_RECEIVING_ACCOUNT_UNAVAILABLE' => t(
      '所选收款码已停用，请取消后重新选择已配置的收款码',
      'This payment QR option is unavailable. Cancel and select a configured option again.',
      '所選收款碼已停用，請取消後重新選擇已配置的收款碼',
      'ช่องทางรับเงินนี้ใช้ไม่ได้ ยกเลิกแล้วเลือกช่องทางใหม่',
    ),
    _ => t(
      '暂未取得入账结果，请取消后重新打开核对本笔充值',
      'Receipt result unavailable. Cancel and reopen to check this recharge.',
      '暫未取得入帳結果，請取消後重新打開核對本筆充值',
      'ยังไม่ได้รับผลการบันทึกเงิน ยกเลิกแล้วเปิดใหม่เพื่อตรวจสอบรายการนี้',
    ),
  };
  String t(String zh, String en, String tw, String th) =>
      rechargeText(widget.language, zh, en, tw, th);
  @override
  void initState() {
    super.initState();
    subscription = ScannerInput.codes.listen((value) {
      if (mounted && ModalRoute.of(context)?.isCurrent == true) {
        unawaited(scan(value));
      }
    });
  }

  Future<void> scan(String value) async {
    if (busy || !mounted) return;
    if (widget.bank && widget.accounts.isEmpty) return;
    if (!ready) {
      setState(() => failureCode = 'RECEIPT_ACCOUNT_REQUIRED');
      return;
    }
    if (!RegExp(r'^KC:M:[0-9A-F]{32}$').hasMatch(value.trim())) {
      setState(() => failureCode = 'EMPLOYEE_CODE_FORMAT');
      return;
    }
    setState(() {
      busy = true;
      failureCode = null;
      submitted = true;
    });
    try {
      await widget.confirm(value.trim(), account);
      if (mounted) Navigator.pop(context, true);
    } catch (error) {
      // Only a bounded error identifier, never the employee QR or receipt data.
      if (error is CcsopFailure &&
          RegExp(r'^[A-Z][A-Z0-9_]{0,79}$').hasMatch(error.code)) {
        debugPrint('KING receipt confirmation rejected: ${error.code}');
      }
      if (mounted) {
        setState(() {
          busy = false;
          failureCode = error is CcsopFailure
              ? error.code
              : 'RECEIPT_UNCONFIRMED';
        });
      }
    }
  }

  @override
  void dispose() {
    subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: AlertDialog(
      title: Text(
        widget.bank
            ? t(
                '银行码收款确认',
                'Confirm bank receipt',
                '銀行碼收款確認',
                'ยืนยันรับเงินผ่านธนาคาร',
              )
            : t('现金收款确认', 'Confirm cash received', '現金收款確認', 'ยืนยันรับเงินสด'),
      ),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '¥ ${rechargeMoney(widget.amountCents)}',
              style: const TextStyle(fontSize: 36, fontWeight: FontWeight.bold),
            ),
            if (widget.bank) ...[
              const SizedBox(height: 16),
              if (widget.accounts.isEmpty)
                Text(
                  t(
                    '请先到设置中配置收款码',
                    'Configure payment QR options in Settings first.',
                    '請先到設定中配置收款碼',
                    'ตั้งค่า QR รับเงินก่อน',
                  ),
                )
              else
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 180),
                  child: SingleChildScrollView(
                    child: Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        for (final name in widget.accounts)
                          ChoiceChip(
                            label: Text(name),
                            selected: account == name,
                            onSelected: busy || submitted
                                ? null
                                : (_) => setState(() {
                                    account = name;
                                    failureCode = null;
                                  }),
                          ),
                      ],
                    ),
                  ),
                ),
            ],
            if (ready) ...[
              const SizedBox(height: 20),
              const ScanIcon(size: 54),
              const SizedBox(height: 12),
              Text(
                t(
                  '确认已收款后，收银员扫自己的会员码',
                  'After receiving payment, scan your own staff member code.',
                  '確認已收款後，收銀員掃自己的會員碼',
                  'รับเงินแล้ว ให้พนักงานสแกนรหัสสมาชิกของตน',
                ),
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                t('等待员工扫码', 'Ready to scan', '等待員工掃碼', 'พร้อมสแกนรหัสพนักงาน'),
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            if (busy)
              const Padding(
                padding: EdgeInsets.all(12),
                child: CircularProgressIndicator(),
              ),
            if (failureCode != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  failureMessage(failureCode!),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: busy ? null : () => Navigator.pop(context, false),
          child: Text(t('取消', 'Cancel', '取消', 'ยกเลิก')),
        ),
      ],
    ),
  );
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
      if (mounted && foreground && ModalRoute.of(context)?.isCurrent == true) {
        unawaited(pay(value));
      }
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
    if (!foreground) {
      timer?.cancel();
    } else if (row != null) {
      unawaited(check());
    }
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
            const ScanIcon(size: 72),
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
