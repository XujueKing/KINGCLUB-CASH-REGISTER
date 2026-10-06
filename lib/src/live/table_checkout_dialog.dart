import '../hardware/paid_receipt_printer.dart';
import 'table_discount_dialog.dart';
import '../hardware/receipt_document_renderer.dart';
import '../hardware/receipt_print_identity.dart';

import 'dart:async';

import 'payment_availability.dart';

import 'dart:math';

import 'package:flutter/material.dart';

import '../auth/staff_auth_controller.dart';
import '../strings.dart';
import '../network/ccsop_client.dart';
import 'table_checkout_command.dart';
import 'table_checkout_result.dart';
import 'table_snapshot.dart';
import 'checkout_scan.dart';
import 'recharge_touch_dialog.dart';
import '../scan_icon.dart';
import '../hardware/scanner_input.dart';

class TableCheckoutDialog extends StatefulWidget {
  const TableCheckoutDialog({
    super.key,
    required this.auth,
    required this.tableRef,
    required this.sessionRef,
    required this.language,
    this.originalRequestId,
    this.paidCents = 0,
    this.seatSessions = const [],
    this.scannerEvents,
  });
  final StaffAuthController auth;
  final String tableRef, sessionRef;
  final UiLanguage language;
  final int paidCents;
  final List<Map<String, String>> seatSessions;
  final Stream<String>? scannerEvents;

  /// Recovery entry must remain bound to the selected durable original request.
  final String? originalRequestId;
  @override
  State<TableCheckoutDialog> createState() => _TableCheckoutDialogState();
}

class _TableCheckoutDialogState extends State<TableCheckoutDialog>
    with WidgetsBindingObserver {
  final input = TextEditingController();
  StreamSubscription<String>? scanner;
  TableCheckoutQuote? quote;
  TableCheckoutCommand? command;
  TableCheckoutAdmission? admission;
  TableCheckoutResult? result;
  String? settledOwner;
  String? get currentOwner {
    final identity = widget.auth.session;
    if (identity == null || !identity.expiresAt.isAfter(DateTime.now()))
      return null;
    return '${identity.base}|${identity.storeRef}|${identity.employeeRef}|${widget.tableRef}|${widget.sessionRef}';
  }

  bool get keepSettlement =>
      result?.settled == true &&
      settledOwner != null &&
      settledOwner == currentOwner;
  String choice = 'wechat', message = '';
  String printStatus = '';
  bool printing = false;
  final printedCheckouts = <String>{};
  bool foreground = true, busy = false, ready = false;
  bool cancelled = false;
  bool replaceCash = false;
  bool cancellationNeedsQuery = false, confirmationOpen = false;
  int epoch = 0;
  Route<dynamic>? unpaidPrintRoute;
  Timer? recoveryTimer;
  Timer? expiry;
  Timer? authorityExpiry;
  Stopwatch? freshness;
  String t(String key) => tr(widget.language, key);
  String get channel => ['platform_cash', 'store_balance'].contains(choice)
      ? 'member_balance'
      : choice;
  bool get barcodePayment =>
      ['wechat', 'alipay', 'member_balance'].contains(channel);
  bool scanBusy = false;
  String text(String zh, String en, String tw, String th) =>
      [zh, en, tw, th][widget.language.index];
  String get scanPrompt => [
    '请出示付款码，扫码即可付款',
    'Scan the customer payment code to pay',
    '請出示付款碼，掃碼即可付款',
    'สแกนรหัสชำระเงินของลูกค้าเพื่อชำระเงิน',
  ][widget.language.index];
  String? get account => channel == 'member_balance' ? choice : null;
  List<String> get choices =>
      [
            'wechat',
            'alipay',
            'store_balance',
            'cash',
            'bank_code',
            'pos',
            'platform_cash',
          ]
          .where(
            (value) =>
                (value != 'alipay' || alipayDirectEnabled) &&
                widget.auth.session?.permissions.contains(
                      'payment.${['platform_cash', 'store_balance'].contains(value)
                          ? 'balance'
                          : ['pos', 'bank_code'].contains(value)
                          ? 'cash'
                          : value}',
                    ) ==
                    true,
          )
          .toList();
  String label(String value) => value == 'bank_code'
      ? text('银行码收款', 'Bank QR receipt', '銀行碼收款', 'รับเงินผ่าน QR ธนาคาร')
      : t(
          value == 'cash'
              ? 'receiptCash'
              : ['platform_cash', 'store_balance'].contains(value)
              ? 'balance_$value'
              : 'provider_$value',
        );
  Future<void> printSettledReceipt(TableCheckoutResult settled) async {
    if (!settled.settled || !printedCheckouts.add(settled.checkoutRef)) return;
    setState(() {
      printing = true;
      printStatus = 'checkoutPrinting';
    });
    final auth = widget.auth;
    final identity = auth.session;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final language = widget.language;
    final status = await printPaidTableReceipt(
      auth: auth,
      checkoutRef: settled.checkoutRef,
      tableRef: widget.tableRef,
      sessionRef: widget.sessionRef,
      language: widget.language,
      // Closing the paid dialog must not cancel its receipt output.
      stillCurrent: () =>
          identity != null &&
          auth.session?.storeRef == identity.storeRef &&
          auth.session?.employeeRef == identity.employeeRef &&
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed,
    );
    if (status != 'checkoutPrintSent' && messenger?.mounted == true) {
      messenger!.showSnackBar(SnackBar(content: Text(tr(language, status))));
    }
    if (mounted)
      setState(() {
        printing = false;
        printStatus = status;
      });
  }

  Future<void> openReceipt() async {
    final settled = result;
    if (busy || printing || !foreground || settled?.settled != true) return;
    setState(() {
      printing = true;
      printStatus = 'checkoutPrinting';
    });
    final status = await printPaidTableReceipt(
      auth: widget.auth,
      checkoutRef: settled!.checkoutRef,
      tableRef: widget.tableRef,
      sessionRef: widget.sessionRef,
      language: widget.language,
      reprint: true,
      stillCurrent: () =>
          mounted && foreground && result?.checkoutRef == settled.checkoutRef,
    );
    if (mounted)
      setState(() {
        printing = false;
        printStatus = status;
      });
  }

  bool current(int e) => mounted && foreground && epoch == e;
  bool get fresh =>
      quote != null &&
      freshness != null &&
      freshness!.elapsed < const Duration(seconds: 30);
  @override
  void initState() {
    super.initState();
    foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    widget.auth.addListener(authChanged);
    WidgetsBinding.instance.addObserver(this);
    scanner = (widget.scannerEvents ?? ScannerInput.codes).listen(
      (code) => unawaited(scan(code)),
    );
    if (foreground) unawaited(load());
  }

  Future<void> scan(String raw) async {
    if (!mounted ||
        !foreground ||
        busy ||
        scanBusy ||
        confirmationOpen ||
        ModalRoute.of(context)?.isCurrent != true ||
        !ready ||
        result?.settled == true)
      return;
    final code = raw.trim();
    final detected = checkoutScanChannel(
      code,
      platformBalance: choice == 'platform_cash',
    );
    if (detected == null) {
      setState(
        () => message = text(
          '请出示微信或会员付款码；会员身份码不能扣款',
          'Show a WeChat or member payment code. Identity codes cannot debit funds.',
          '請出示微信或會員付款碼；會員身分碼不能扣款',
          'กรุณาแสดงรหัสชำระเงิน รหัสประจำตัวสมาชิกใช้หักเงินไม่ได้',
        ),
      );
      return;
    }
    if (detected == 'alipay' && !alipayDirectEnabled) {
      setState(
        () => message = text(
          '支付宝请使用银行码收款',
          'Use Bank QR receipt for Alipay',
          '支付寶請使用銀行碼收款',
          'สำหรับ Alipay กรุณาใช้การรับเงินผ่าน QR ธนาคาร',
        ),
      );
      return;
    }
    if (!choices.contains(detected)) {
      setState(
        () => message = text(
          '当前员工没有此收款权限',
          'Payment permission required',
          '目前員工沒有此收款權限',
          'ไม่มีสิทธิ์รับเงินวิธีนี้',
        ),
      );
      return;
    }
    if (command != null && detected != choice) {
      setState(
        () => message = text(
          '请先取消本次收款，再更换付款方式',
          'Cancel this collection before changing payment method',
          '請先取消本次收款，再更換付款方式',
          'ยกเลิกการรับเงินครั้งนี้ก่อนเปลี่ยนวิธี',
        ),
      );
      return;
    }
    scanBusy = true;
    try {
      if (command == null &&
          (choice != detected ||
              detected == 'store_balance' ||
              detected == 'platform_cash')) {
        setState(() {
          choice = detected;
          freshness = null;
        });
        await readQuote(paymentCode: channel == 'member_balance' ? code : null);
        if (!mounted || !fresh) return;
      }
      if (command == null) await startCollection();
      if (!mounted || admission?.paymentStatus != 'prepared') return;
      input.text = code;
      await collect();
    } finally {
      scanBusy = false;
    }
  }

  Future<void> selectMethod(String value) async {
    if (busy || scanBusy || command != null || choice == value) return;
    setState(() {
      choice = value;
      freshness = null;
      input.clear();
    });
    await readQuote();
  }

  Future<void> offlineReceipt() async {
    if (busy || !ready || !['cash', 'bank_code'].contains(channel)) return;
    final bank = channel == 'bank_code';
    final expectedDue = command?.totalCents ?? quote?.totalCents;
    final received = bank ? expectedDue : cashCents(input.text);
    if (received == null ||
        received < (command?.totalCents ?? quote?.totalCents ?? 1)) {
      setState(
        () => message = text(
          '实收金额不能小于应收',
          'Received amount is below amount due',
          '實收金額不能小於應收',
          'ยอดรับน้อยกว่ายอดที่ต้องชำระ',
        ),
      );
      return;
    }
    Map<String, dynamic>? settings;
    setState(() {
      busy = true;
      message = '';
    });
    try {
      if (bank)
        settings = await widget.auth.storeMembers({
          'action': 'receiptAccounts',
        });
    } catch (_) {
      if (mounted)
        setState(
          () => message = text(
            '收款码设置读取失败，请重试',
            'Could not load payment QR settings',
            '收款碼設定讀取失敗，請重試',
            'อ่านการตั้งค่า QR ไม่สำเร็จ',
          ),
        );
      return;
    } finally {
      if (mounted) setState(() => busy = false);
    }
    if (!mounted) return;
    final accounts =
        ((settings?['receiptSettings'] as Map?)?['accounts'] as List? ??
                const [])
            .whereType<String>()
            .toList();
    if (bank && accounts.isEmpty) {
      setState(
        () => message = text(
          '请先在设置中配置银行收款码',
          'Configure receiving QR accounts in Settings first',
          '請先在設定中配置銀行收款碼',
          'กรุณาตั้งค่าบัญชี QR ก่อน',
        ),
      );
      return;
    }
    confirmationOpen = true;
    try {
      await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => RechargeOfflineReceiptDialog(
          language: widget.language,
          bank: bank,
          amountCents: command?.totalCents ?? quote!.totalCents,
          accounts: accounts,
          account: '',
          confirm: (code, selected) async {
            if (command == null) await startCollection();
            if (!mounted ||
                admission?.paymentStatus != 'prepared' ||
                command?.totalCents != expectedDue)
              throw const CcsopFailure('RECEIPT_UNCONFIRMED');
            input.text = formatCents(received);
            await collect(
              employeeCode: code,
              receivingAccount: bank ? selected : null,
            );
          },
        ),
      );
    } finally {
      confirmationOpen = false;
    }
    if (mounted && result?.settled == true) Navigator.of(context).pop(true);
  }

  void authChanged() {
    invalidate();
    // Restore the original durable request after the session refresh finishes.
    // Merely clearing the dialog here left a blank checkout until a manual tap.
    if (foreground && !widget.auth.busy && widget.auth.session != null) {
      unawaited(load());
    }
  }

  String get billReadFailure => [
    '账单暂未读取，请重试',
    'Could not load the bill. Please retry.',
    '????????????',
    '??????????????????? ????????????????',
  ][widget.language.index];

  void invalidate() {
    final keep = keepSettlement;
    epoch++;
    final printRoute = unpaidPrintRoute;
    unpaidPrintRoute = null;
    if (printRoute != null && printRoute.isActive && mounted) {
      Navigator.of(context).removeRoute(printRoute);
    }
    recoveryTimer?.cancel();
    expiry?.cancel();
    authorityExpiry?.cancel();
    freshness?.stop();
    freshness = null;
    input.clear();
    if (mounted) {
      setState(() {
        if (!keep) {
          quote = null;
          command = null;
          admission = null;
          result = null;
          settledOwner = null;
        }
        ready = false;
        busy = false;
        confirmationOpen = false;
        cancelled = false;
        cancellationNeedsQuery = false;
        message = '';
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
  void didUpdateWidget(covariant TableCheckoutDialog old) {
    super.didUpdateWidget(old);
    if (old.auth != widget.auth ||
        old.tableRef != widget.tableRef ||
        old.sessionRef != widget.sessionRef ||
        old.originalRequestId != widget.originalRequestId) {
      old.auth.removeListener(authChanged);
      widget.auth.addListener(authChanged);
      authChanged();
    }
  }

  @override
  void dispose() {
    epoch++;
    recoveryTimer?.cancel();
    expiry?.cancel();
    authorityExpiry?.cancel();
    freshness?.stop();
    scanner?.cancel();
    input.dispose();
    widget.auth.removeListener(authChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> load() async {
    if (!foreground || busy) return;
    if (keepSettlement) {
      // A refreshed login does not undo a verified payment or reopen collection.
      authorityExpiry?.cancel();
      authorityExpiry = Timer(
        widget.auth.session!.expiresAt.difference(DateTime.now()),
        invalidate,
      );
      return;
    }
    final e = epoch;
    setState(() => busy = true);
    try {
      final identity = widget.auth.session;
      final remaining = identity?.expiresAt.difference(DateTime.now());
      if (remaining == null || remaining <= Duration.zero) {
        throw const FormatException();
      }
      authorityExpiry?.cancel();
      authorityExpiry = Timer(remaining, invalidate);
      final pending = <TableCheckoutCommand>[];
      for (final c in [
        'wechat',
        'alipay',
        'cash',
        'bank_code',
        'pos',
        'member_balance',
      ]) {
        if (widget.auth.session?.permissions.contains(
              'payment.${c == 'member_balance'
                  ? 'balance'
                  : ['pos', 'bank_code'].contains(c)
                  ? 'cash'
                  : c}',
            ) ==
            true) {
          pending.addAll(await widget.auth.pendingTableCheckouts(c));
          if (!current(e)) return;
        }
      }
      final matches = pending
          .where(
            (p) =>
                p.tableRef == widget.tableRef &&
                p.sessionRef == widget.sessionRef,
          )
          .toList();
      if (matches.length > 1 || choices.isEmpty) throw const FormatException();
      if (widget.originalRequestId != null &&
          (matches.length != 1 ||
              matches.single.requestId != widget.originalRequestId)) {
        throw const FormatException();
      }
      if (current(e)) {
        setState(() {
          command = matches.isEmpty ? null : matches.single;
          choice = command == null
              ? (choices.contains(choice) ? choice : choices.first)
              : command!.accountType ?? command!.channel;
          ready = true;
          message = '';
        });
      }
    } catch (_) {
      if (current(e)) setState(() => message = billReadFailure);
    } finally {
      if (current(e)) setState(() => busy = false);
    }
    if (current(e) && ready) {
      if (command == null) {
        await readQuote();
      } else {
        await resumePayment();
      }
    }
  }

  Future<void> resumePayment() async {
    if (!mounted ||
        busy ||
        !foreground ||
        command == null ||
        cancelled ||
        result?.settled == true)
      return;
    await queryAdmission();
    if (!mounted || !foreground) return;
    if (admission?.paymentStatus == 'closed') {
      await cancelOriginal(queryOnly: true);
    }
    if (!cancelled &&
        admission?.observed == true &&
        admission?.paymentStatus != 'prepared') {
      await collect(recover: true);
    }
    if (mounted &&
        !cancelled &&
        result?.settled != true &&
        admission?.paymentStatus != 'prepared') {
      recoveryTimer?.cancel();
      recoveryTimer = Timer(
        const Duration(seconds: 3),
        () => unawaited(resumePayment()),
      );
    }
  }

  Future<void> dismissCheckout() async {
    if (busy || printing) return;
    if (command != null &&
        admission?.paymentStatus == 'prepared' &&
        result?.settled != true) {
      await cancelOriginal();
    }
    if (result?.canCloseUnpaid == true) await collect(close: true);
    if (mounted) Navigator.of(context).pop(result?.settled == true);
  }

  Future<void> readQuote({String? paymentCode}) async {
    if (!ready || busy || !foreground || command != null) return;
    final e = epoch;
    expiry?.cancel();
    final watch = Stopwatch()..start();
    setState(() {
      busy = true;
      freshness = null;
      message = '';
    });
    try {
      final next = await widget.auth.quoteTableCheckout(
        tableRef: widget.tableRef,
        sessionRef: widget.sessionRef,
        channel: channel,
        accountType: account,
        paymentCode: paymentCode,
        seatSessions: widget.seatSessions,
      );
      if (!current(e)) return;
      final remaining = const Duration(seconds: 30) - watch.elapsed;
      if (remaining <= Duration.zero) throw const FormatException();
      setState(() {
        quote = next;
        if (paymentCode != null) choice = next.accountType!;
        freshness = watch;
      });
      expiry = Timer(remaining, () {
        if (current(e)) {
          // Keep the displayed bill; freshness still gates every payment.
          setState(() {});
        }
      });
    } catch (error) {
      // Log only a bounded error identifier, never request or payment data.
      final failureCode = error is CcsopFailure
          ? error.code
          : error.runtimeType.toString();
      if (RegExp(r'^[A-Za-z0-9_]{1,100}$').hasMatch(failureCode)) {
        debugPrint('cashier_checkout_quote: $failureCode');
      }
      if (current(e)) {
        if (error is CcsopFailure &&
            error.code == 'CASHIER_TABLE_CHECKOUT_SCOPE_CHANGED') {
          setState(() {
            quote = null;
            message = [
              '?????????????????????',
              'This table session has ended or changed. Return to tables.',
              '?????????????????????',
              '????????????????????????????? ???????????????????',
            ][widget.language.index];
          });
          // Do not leave an old-business-day payment dialog above the new table.
          if (ModalRoute.of(context)?.isCurrent == true) {
            unawaited(Navigator.of(context).maybePop());
          }
        } else {
          setState(
            () => message =
                error is CcsopFailure &&
                    error.code == 'CASHIER_TABLE_CHECKOUT_NOT_ENABLED'
                ? t('tableCheckoutUnavailable')
                : billReadFailure,
          );
        }
      }
    } finally {
      if (current(e)) setState(() => busy = false);
    }
  }

  String newRequest() {
    final random = Random.secure(),
        bytes = List.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 15) | 64;
    bytes[8] = (bytes[8] & 63) | 128;
    final s = bytes.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
    return '${s.substring(0, 8)}-${s.substring(8, 12)}-${s.substring(12, 16)}-${s.substring(16, 20)}-${s.substring(20)}';
  }

  Future<bool> confirmAction(
    String title,
    String notice,
    TableCheckoutCommand original,
  ) async {
    final e = epoch;
    setState(() {
      busy = true;
      confirmationOpen = true;
    });
    try {
      final accepted = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(t(title)),
          content: Text(
            '${label(original.accountType ?? original.channel)} / CNY ${formatCents(original.totalCents)}\n${t(notice)}',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(t('cancel')),
            ),
            FilledButton(
              key: const ValueKey('table-checkout-confirm-action'),
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(t('confirm')),
            ),
          ],
        ),
      );
      return current(e) && accepted == true;
    } finally {
      if (current(e)) {
        setState(() {
          busy = false;
          confirmationOpen = false;
        });
      }
    }
  }

  Future<void> prepare({bool retry = false}) async {
    if (!foreground ||
        busy ||
        cancelled ||
        cancellationNeedsQuery ||
        (retry ? command == null : !fresh || command != null)) {
      return;
    }
    final identity = widget.auth.session, e = epoch, watch = freshness;
    if (identity == null) return;
    final original = retry
        ? command!
        : TableCheckoutCommand.fromQuote(
            identity,
            quote!,
            requestId: newRequest(),
          );
    setState(() {
      command = original;
      busy = true;
      message = '';
    });
    try {
      final next = await widget.auth.prepareTableCheckout(
        original,
        confirmed: true,
        stillCurrent: () =>
            current(e) &&
            (retry ||
                watch != null && watch.elapsed < const Duration(seconds: 30)),
      );
      if (current(e)) setState(() => admission = next);
    } catch (_) {
      if (!current(e)) return;
      // Preparation may commit before its response is lost. Query the SAME
      // request once; this never prepares again or sends a payment code.
      try {
        final observed = await widget.auth.lookupTableCheckout(original);
        if (current(e)) {
          setState(() {
            admission = observed;
            message = observed.observed ? '' : t('tableCheckoutMissing');
          });
        }
      } catch (_) {
        if (current(e)) setState(() => message = t('tableCheckoutReview'));
      }
    } finally {
      if (current(e)) setState(() => busy = false);
    }
  }

  Future<void> queryAdmission() async {
    final original = command;
    if (!foreground || busy || original == null || cancelled) return;
    final e = epoch;
    setState(() {
      busy = true;
      admission = null;
      message = '';
    });
    input.clear();
    try {
      final next = await widget.auth.lookupTableCheckout(original);
      if (current(e)) {
        setState(() {
          admission = next;
          cancellationNeedsQuery = false;
          if (!next.observed) message = t('tableCheckoutMissing');
        });
      }
    } catch (_) {
      if (current(e)) setState(() => message = t('tableCheckoutReview'));
    } finally {
      if (current(e)) setState(() => busy = false);
    }
  }

  int cashCents(String value) {
    if (!RegExp(r'^(0|[1-9][0-9]{0,6})(\.[0-9]{1,2})?$').hasMatch(value)) {
      throw const FormatException();
    }
    final parts = value.split('.');
    return int.parse(parts[0]) * 100 +
        (parts.length == 1 ? 0 : int.parse(parts[1].padRight(2, '0')));
  }

  Future<void> cancelOriginal({bool queryOnly = false}) async {
    final original = command;
    if (!foreground ||
        busy ||
        original == null ||
        cancelled ||
        result?.settled == true ||
        (!queryOnly && admission?.paymentStatus != 'prepared')) {
      return;
    }
    final e = epoch;
    if (!current(e)) return;
    input.clear();
    setState(() {
      busy = true;
      admission = null;
      cancellationNeedsQuery = true;
      message = '';
    });
    try {
      final next = queryOnly
          ? await widget.auth.lookupTableCancellation(
              original,
              stillCurrent: () => current(e),
            )
          : await widget.auth.cancelTableCheckout(
              original,
              confirmed: true,
              stillCurrent: () => current(e),
            );
      if (!current(e)) return;
      setState(() {
        cancelled = next.cancelled;
        message = t(
          next.cancelled
              ? 'tableCheckoutCancelled'
              : 'tableCheckoutNotCancelled',
        );
      });
    } catch (_) {
      if (current(e)) setState(() => message = t('tableCheckoutReview'));
    } finally {
      if (current(e)) setState(() => busy = false);
    }
  }

  Future<void> collect({
    String? employeeCode,
    String? receivingAccount,
    bool recover = false,
    bool close = false,
  }) async {
    final original = command;
    if (!foreground ||
        busy ||
        cancelled ||
        original == null ||
        (admission?.observed != true &&
            !(close &&
                result?.canCloseUnpaid == true &&
                result!.matches(original)))) {
      return;
    }
    final e = epoch, text = input.text;
    Object? collectionError;
    if (!recover &&
        !close &&
        original.channel == 'pos' &&
        !await confirmAction(
          'tableCheckoutCollect',
          original.channel == 'pos'
              ? 'checkoutPosConsent'
              : 'tableCheckoutCollectConsent',
          original,
        )) {
      return;
    }
    if (!current(e)) return;
    input.clear();
    setState(() {
      busy = true;
      message = '';
      admission = null;
    });
    try {
      final next = close
          ? await widget.auth.closeTableProvider(
              original,
              stillCurrent: () => current(e),
            )
          : recover
          ? await widget.auth.recoverTableCheckout(
              original,
              stillCurrent: () => current(e),
            )
          : await widget.auth.collectTableCheckout(
              original,
              confirmed: true,
              stillCurrent: () => current(e),
              payerCode: ['cash', 'bank_code'].contains(original.channel)
                  ? null
                  : text,
              employeeIdentityCode: employeeCode,
              receivingAccount: receivingAccount,
              cashReceivedCents:
                  ['cash', 'bank_code'].contains(original.channel)
                  ? cashCents(text)
                  : null,
            );
      if (current(e)) {
        setState(() {
          result = next;
          if (next.settled) settledOwner = currentOwner;
          cancelled = next.closedUnpaid;
          message = t('tableCheckout_${next.state}');
        });
        if (next.settled) {
          unawaited(printSettledReceipt(next));
          if (employeeCode == null) Navigator.of(context).pop(true);
        }
      }
    } catch (error) {
      collectionError = error;
      // A failed send must be classified by the server's original request.
      // Restore scanning only when it is still prepared; never retry this code.
      if (current(e)) {
        try {
          final latest = await widget.auth.lookupTableCheckout(original);
          if (current(e)) setState(() => admission = latest);
        } catch (_) {
          // Keep recovery-only controls when the original state is unavailable.
        }
      }
      final soldOut =
          error is CcsopFailure &&
          [
            'ORDERING_OUT_OF_STOCK',
            'ORDERING_POSTPAY_OUT_OF_STOCK',
          ].contains(error.code);
      final postpayShortage =
          error is CcsopFailure &&
          error.code == 'ORDERING_POSTPAY_OUT_OF_STOCK';
      if (current(e)) {
        setState(
          () => message =
              error is CcsopFailure &&
                  error.code == 'CASHIER_TABLE_ORDER_EXPIRED'
              ? [
                  '订单已超时，未扣款。请取消本次收款后重新下单。',
                  'Order expired; no charge. Cancel this collection and place a new order.',
                  '訂單已逾時，未扣款。請取消本次收款後重新下單。',
                  'คำสั่งซื้อหมดเวลา ยังไม่เรียกเก็บเงิน โปรดยกเลิกการรับชำระนี้แล้วสั่งใหม่',
                ][widget.language.index]
              : t(
                  soldOut
                      ? (original.channel == 'cash'
                            ? (postpayShortage
                                  ? 'postpayCashStockUnavailable'
                                  : 'cashStockUnavailable')
                            : (postpayShortage
                                  ? 'postpayStockUnavailable'
                                  : 'paymentStockUnavailable'))
                      : 'tableCheckoutReview',
                ),
        );
      }
    } finally {
      if (current(e)) setState(() => busy = false);
    }
    if (employeeCode != null && result?.settled != true) {
      if (collectionError is CcsopFailure) throw collectionError;
      throw const CcsopFailure('RECEIPT_UNCONFIRMED');
    }
    if (current(e) &&
        !cancelled &&
        result?.settled != true &&
        admission?.paymentStatus != 'prepared') {
      recoveryTimer?.cancel();
      recoveryTimer = Timer(
        const Duration(seconds: 3),
        () => unawaited(resumePayment()),
      );
    }
  }

  Future<void> discount({bool waive = false}) async {
    if (busy || !foreground || command != null) return;
    await readQuote();
    if (!mounted || !fresh || quote == null) return;
    final changed = await showDialog<Map<String, dynamic>>(
      context: context,
      barrierDismissible: false,
      builder: (_) => TableDiscountDialog(
        auth: widget.auth,
        quote: quote!,
        language: widget.language,
        requestId: newRequest(),
        waive: waive,
      ),
    );
    if (!mounted) return;
    if (changed != null && changed['totalCents'] == 0) {
      Navigator.of(context).pop(true);
      return;
    }
    quote = null;
    freshness = null;
    await readQuote();
  }

  Future<void> printUnpaid() async {
    if (busy || printing || !foreground || command != null) return;
    await readQuote();
    final q = quote, identity = widget.auth.session, generation = epoch;
    if (!mounted || !fresh || q == null || identity == null) return;
    setState(() {
      printing = true;
      message = t('checkoutPrinting');
    });
    final status = await printReceiptPlan(
      plan: ReceiptRasterPlan.unpaid(
        q,
        caption: await readReceiptCaption(
          widget.auth,
          q.tableRef,
          q.sessionRef,
        ),
        language: widget.language,
        widthDots: 576,
      ),
      printIdentity: ReceiptPrintIdentity.unpaid(
        base: identity.base.toString(),
        storeRef: q.storeRef,
        fingerprint: q.fingerprint,
      ),
      current: () =>
          current(generation) && identical(identity, widget.auth.session),
      reprint: true,
    );
    if (mounted)
      setState(() {
        printing = false;
        message = t(
          status == 'checkoutPrintSent' ? status : 'receiptPrinterUnavailable',
        );
      });
  }

  Future<void> startCollection() async {
    if (busy || !foreground || !ready || command != null) return;
    if (!fresh) await readQuote();
    if (!mounted || !fresh || busy) return;
    await prepare();
    if (!mounted || admission?.paymentStatus != 'prepared') return;
    if (channel == 'cash') {
      input.clear();
      replaceCash = false;
    }
  }

  Widget amount(String title, int? cents, {bool prominent = false}) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(title, style: const TextStyle(fontSize: 14, color: Colors.black54)),
      const SizedBox(height: 8),
      Text(
        cents == null ? '—' : '￥ ${formatCents(cents)}',
        style: TextStyle(
          fontSize: prominent ? 32 : 24,
          fontWeight: FontWeight.w700,
          color: prominent ? const Color(0xffbd3039) : null,
        ),
      ),
    ],
  );

  Widget cashPad() => Column(
    children: [
      Row(
        children: [
          Expanded(
            child: TextField(
              key: const ValueKey('cash-amount-input'),
              controller: input,
              readOnly: true,
              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
              decoration: InputDecoration(labelText: t('cashReceived')),
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 170,
            height: 56,
            child: OutlinedButton(
              onPressed: busy
                  ? null
                  : () => setState(() {
                      input.text = formatCents(
                        command?.totalCents ?? quote!.totalCents,
                      );
                      replaceCash = true;
                    }),
              child: Text(t('checkoutExactCash')),
            ),
          ),
        ],
      ),
      const SizedBox(height: 12),
      for (final row in const [
        ['1', '2', '3'],
        ['4', '5', '6'],
        ['7', '8', '9'],
        ['.', '0', '⌫'],
      ])
        Row(
          children: [
            for (final digit in row)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(3),
                  child: OutlinedButton(
                    onPressed: busy
                        ? null
                        : () {
                            var value = input.text;
                            if (digit == '⌫') {
                              input.text = value.isEmpty
                                  ? ''
                                  : value.substring(0, value.length - 1);
                              replaceCash = false;
                            } else {
                              if (replaceCash) value = '';
                              if (digit == '.') {
                                if (!value.contains('.')) {
                                  input.text = value.isEmpty ? '0.' : '$value.';
                                }
                              } else if (!(value.contains('.') &&
                                  value.split('.').last.length >= 2)) {
                                final next =
                                    (value == '0' ? '' : value) + digit;
                                if (RegExp(r'^\d{1,7}(\.\d{0,2})?$')
                                    .hasMatch(next)) {
                                  input.text = next;
                                }
                              }
                              replaceCash = false;
                            }
                            setState(() {});
                          },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(digit, style: const TextStyle(fontSize: 22)),
                    ),
                  ),
                ),
              ),
          ],
        ),
    ],
  );

  Widget methodButton(String value, IconData icon) {
    final selected = value == 'scan' ? barcodePayment : choice == value;
    return SizedBox(
      height: 58,
      child: OutlinedButton.icon(
        key: ValueKey('checkout-method-$value'),
        onPressed: busy || command != null
            ? null
            : () => selectMethod(
                value == 'scan'
                    ? choices.firstWhere(
                        (v) => [
                          'wechat',
                          'alipay',
                          'store_balance',
                          'platform_cash',
                        ].contains(v),
                      )
                    : value,
              ),
        style: OutlinedButton.styleFrom(
          foregroundColor: selected ? const Color(0xff202020) : Colors.black54,
          backgroundColor: selected ? const Color(0xffffe6a3) : Colors.white,
          side: BorderSide(
            color: selected ? const Color(0xffdbad38) : const Color(0xffdedede),
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12),
        ),
        icon: value == 'scan' ? const ScanIcon(size: 24) : Icon(icon, size: 24),
        label: Text(
          value == 'scan'
              ? text('扫码付款', 'Scan to pay', '掃碼付款', 'สแกนชำระเงิน')
              : label(value),
          style: const TextStyle(fontSize: 17),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final q = quote, original = command;
    final originalDue = original?.totalCents ?? q?.totalCents;
    final due = result?.settled == true ? 0 : originalDue;
    final paid =
        widget.paidCents + (result?.settled == true ? originalDue ?? 0 : 0);
    final canReceive =
        ready &&
        originalDue != null &&
        !cancelled &&
        (original == null || admission?.paymentStatus == 'prepared') &&
        !cancellationNeedsQuery;
    final icons = <String, IconData>{
      'wechat': Icons.chat_bubble_outline,
      'alipay': Icons.qr_code,
      'store_balance': Icons.credit_card,
      'platform_cash': Icons.account_balance_wallet_outlined,
      'cash': Icons.payments_outlined,
      'bank_code': Icons.account_balance_outlined,
      'pos': Icons.credit_card_outlined,
    };
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      child: SizedBox(
        width: 1080,
        height: 660,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      t('tableCheckoutTitle'),
                      style: const TextStyle(
                        fontSize: 25,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('checkout-close'),
                    constraints: const BoxConstraints(
                      minWidth: 48,
                      minHeight: 48,
                    ),
                    onPressed: busy || printing ? null : dismissCheckout,
                    icon: const Icon(Icons.close, size: 28),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                      width: 285,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            text(
                              '本次结账明细',
                              'Items to settle',
                              '本次結帳明細',
                              'รายการที่ชำระ',
                            ),
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Expanded(
                            child: q == null
                                ? const SizedBox.shrink()
                                : ListView.separated(
                                    key: const ValueKey(
                                      'table-checkout-bill-lines',
                                    ),
                                    itemCount: q.lines.length,
                                    separatorBuilder: (_, __) =>
                                        const Divider(height: 16),
                                    itemBuilder: (_, i) {
                                      final line = q.lines[i];
                                      return Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            line.name(widget.language),
                                            style: const TextStyle(
                                              fontSize: 17,
                                              fontWeight: FontWeight.w500,
                                            ),
                                          ),
                                          const SizedBox(height: 6),
                                          Row(
                                            children: [
                                              Expanded(
                                                child: Text(
                                                  '${line.specification(widget.language)} × ${line.quantity}',
                                                  style: const TextStyle(
                                                    color: Colors.black54,
                                                  ),
                                                ),
                                              ),
                                              Text(
                                                '¥ ${formatCents(line.quantity * line.priceCents)}',
                                                style: const TextStyle(
                                                  fontSize: 17,
                                                  fontWeight: FontWeight.w600,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ],
                                      );
                                    },
                                  ),
                          ),
                          SizedBox(
                            height: 48,
                            child: OutlinedButton.icon(
                              onPressed:
                                  busy ||
                                      printing ||
                                      original != null ||
                                      q == null
                                  ? null
                                  : printUnpaid,
                              icon: const Icon(Icons.print_outlined),
                              label: Text(t('checkoutUnpaidTicket')),
                            ),
                          ),
                          if (widget.seatSessions.isEmpty &&
                              widget.auth.session?.permissions.contains(
                                    'orders.create',
                                  ) ==
                                  true) ...[
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                Expanded(
                                  child: SizedBox(
                                    height: 48,
                                    child: OutlinedButton(
                                      onPressed:
                                          busy || original != null || q == null
                                          ? null
                                          : () => discount(),
                                      child: Text(t('checkoutDiscount')),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: SizedBox(
                                    height: 48,
                                    child: OutlinedButton(
                                      onPressed:
                                          busy || original != null || q == null
                                          ? null
                                          : () => discount(waive: true),
                                      child: Text(t('checkoutWaive')),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                          const SizedBox(height: 8),
                          SizedBox(
                            height: 48,
                            child: Tooltip(
                              message: text(
                                '平台券与本店券的核销及结算规则尚未开放',
                                'Platform and store coupon redemption is not enabled yet',
                                '平台券與本店券的核銷及結算規則尚未開放',
                                'ยังไม่เปิดใช้กฎการแลกและชำระคูปอง',
                              ),
                              child: OutlinedButton.icon(
                                onPressed: null,
                                icon: const Icon(Icons.local_offer_outlined),
                                label: Text(
                                  text(
                                    '优惠券 · 待开通',
                                    'Coupons · Not enabled',
                                    '優惠券 · 待開通',
                                    'คูปอง · ยังไม่เปิดใช้',
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const VerticalDivider(width: 32),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Container(
                            key: const ValueKey('checkout-amount-summary'),
                            padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
                            decoration: BoxDecoration(
                              color: const Color(0xfff6f5f2),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        '${t('checkoutTotal')}  ${due == null ? '—' : '¥ ${formatCents(due + paid)}'}',
                                        style: const TextStyle(
                                          fontSize: 15,
                                          color: Colors.black54,
                                        ),
                                      ),
                                      const SizedBox(height: 8),
                                      Text(
                                        '${t('checkoutPaid')}  ¥ ${formatCents(paid)}',
                                        style: const TextStyle(
                                          fontSize: 15,
                                          color: Colors.black54,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                amount(t('checkoutDue'), due, prominent: true),
                              ],
                            ),
                          ),
                          const SizedBox(height: 12),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              if (choices.any(
                                (v) => [
                                  'wechat',
                                  'alipay',
                                  'store_balance',
                                  'platform_cash',
                                ].contains(v),
                              ))
                                methodButton('scan', Icons.qr_code_scanner),
                              for (final value in choices.where(
                                (v) => ['cash', 'bank_code', 'pos'].contains(v),
                              ))
                                methodButton(value, icons[value]!),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Expanded(
                            child: SingleChildScrollView(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  if (result?.settled == true) ...[
                                    const Icon(
                                      Icons.check_circle,
                                      color: Color(0xff168657),
                                      size: 64,
                                    ),
                                    Text(
                                      t('checkoutSuccess'),
                                      textAlign: TextAlign.center,
                                    ),
                                    TextButton(
                                      key: const ValueKey(
                                        'checkout-settled-receipt',
                                      ),
                                      onPressed: printing ? null : openReceipt,
                                      child: Text(t('receiptReprint')),
                                    ),
                                  ] else if (canReceive &&
                                      channel == 'cash') ...[
                                    cashPad(),
                                  ] else if (canReceive &&
                                      channel == 'bank_code') ...[
                                    const SizedBox(height: 36),
                                    const Icon(
                                      Icons.account_balance_outlined,
                                      size: 58,
                                    ),
                                    const SizedBox(height: 20),
                                    Text(
                                      text(
                                        '银行码收款',
                                        'Bank QR receipt',
                                        '銀行碼收款',
                                        'รับเงินผ่าน QR ธนาคาร',
                                      ),
                                      textAlign: TextAlign.center,
                                      style: const TextStyle(
                                        fontSize: 24,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    const SizedBox(height: 16),
                                    Text(
                                      text(
                                        '顾客扫门店收款码付款后，\n选择收款账户，员工扫码确认到账',
                                        'After the customer pays your store QR,\nselect the account and scan the cashier code.',
                                        '顧客掃門店收款碼付款後，\n選擇收款帳戶，員工掃碼確認到帳',
                                        'เมื่อลูกค้าชำระ QR ของร้านแล้ว\nเลือกบัญชีและสแกนรหัสพนักงาน',
                                      ),
                                      textAlign: TextAlign.center,
                                      style: const TextStyle(
                                        fontSize: 18,
                                        height: 1.6,
                                        color: Colors.black54,
                                      ),
                                    ),
                                  ] else if (canReceive &&
                                      channel == 'pos') ...[
                                    const SizedBox(height: 24),
                                    const Icon(
                                      Icons.credit_card_outlined,
                                      size: 58,
                                    ),
                                    const SizedBox(height: 16),
                                    Text(
                                      text(
                                        '独立 POS 刷卡',
                                        'Independent POS terminal',
                                        '獨立 POS 刷卡',
                                        'เครื่อง POS แยก',
                                      ),
                                      textAlign: TextAlign.center,
                                      style: const TextStyle(
                                        fontSize: 24,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    const SizedBox(height: 12),
                                    Text(
                                      text(
                                        '刷卡成功后，填写凭证号并确认收款',
                                        'After a successful card payment, enter its reference and confirm.',
                                        '刷卡成功後，填寫憑證號並確認收款',
                                        'เมื่อชำระสำเร็จ กรอกเลขอ้างอิงและยืนยันรับเงิน',
                                      ),
                                      textAlign: TextAlign.center,
                                      style: const TextStyle(
                                        fontSize: 17,
                                        color: Colors.black54,
                                      ),
                                    ),
                                    const SizedBox(height: 24),
                                    TextField(
                                      controller: input,
                                      decoration: InputDecoration(
                                        labelText: t('checkoutPosReference'),
                                      ),
                                    ),
                                  ] else if (canReceive) ...[
                                    const SizedBox(height: 24),
                                    const Center(child: ScanIcon(size: 88)),
                                    const SizedBox(height: 18),
                                    Text(
                                      text(
                                        '出示付款码，扫码即付',
                                        'Show a payment code to pay',
                                        '出示付款碼，掃碼即付',
                                        'แสดงรหัสชำระเงินแล้วสแกน',
                                      ),
                                      textAlign: TextAlign.center,
                                      style: const TextStyle(
                                        fontSize: 25,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    const SizedBox(height: 12),
                                    Text(
                                      text(
                                        '微信 · 支付宝 · KING 付款码\n余额按顾客授权账户扣款',
                                        'WeChat · Alipay · KING payment code\nUses the account authorized by the customer',
                                        '微信 · 支付寶 · KING 付款碼\n餘額按顧客授權帳戶扣款',
                                        'WeChat · Alipay · รหัสชำระเงิน KING\nหักจากบัญชีที่ลูกค้าอนุญาต',
                                      ),
                                      textAlign: TextAlign.center,
                                      style: const TextStyle(
                                        fontSize: 17,
                                        height: 1.6,
                                        color: Colors.black54,
                                      ),
                                    ),
                                  ] else if (!busy) ...[
                                    Text(
                                      message.isEmpty
                                          ? t('tableCheckoutReview')
                                          : message,
                                      textAlign: TextAlign.center,
                                    ),
                                    SizedBox(
                                      height: 52,
                                      child: OutlinedButton(
                                        onPressed: ready && original != null
                                            ? resumePayment
                                            : load,
                                        child: Text(t('ordersRefresh')),
                                      ),
                                    ),
                                  ],
                                  if (busy && !confirmationOpen)
                                    const Padding(
                                      padding: EdgeInsets.all(12),
                                      child: Center(
                                        child: SizedBox(
                                          width: 22,
                                          height: 22,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                          ),
                                        ),
                                      ),
                                    ),
                                  if (message.isNotEmpty && canReceive)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 12),
                                      child: Text(
                                        message,
                                        textAlign: TextAlign.center,
                                        style: TextStyle(
                                          color: Theme.of(context)
                                              .colorScheme
                                              .error,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                          if (canReceive &&
                              [
                                'cash',
                                'bank_code',
                                'pos',
                              ].contains(channel)) ...[
                            const SizedBox(height: 12),
                            SizedBox(
                              height: 60,
                              width: double.infinity,
                              child: FilledButton(
                                key: const ValueKey('checkout-confirm-receipt'),
                                style: FilledButton.styleFrom(
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  textStyle: const TextStyle(
                                    fontSize: 21,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                onPressed: busy
                                    ? null
                                    : () async {
                                        if (channel != 'pos') {
                                          await offlineReceipt();
                                          return;
                                        }
                                        final reference = input.text;
                                        if (command == null)
                                          await startCollection();
                                        input.text = reference;
                                        await collect();
                                      },
                                child: Text(
                                  text(
                                    '确认收款',
                                    'Confirm receipt',
                                    '確認收款',
                                    'ยืนยันรับเงิน',
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
