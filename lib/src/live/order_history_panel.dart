import 'dart:async';
import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import '../../main.dart';
import '../auth/staff_auth_controller.dart';
import '../hardware/paid_receipt_printer.dart';
import '../hardware/receipt_document_renderer.dart';
import '../hardware/receipt_print_identity.dart';
import '../strings.dart';

/// History is a read-only snapshot. All twenty orders include their lines, so
/// selecting a row never starts another request or clears the detail pane.
class OrderHistoryPanel extends StatefulWidget {
  const OrderHistoryPanel({
    super.key,
    required this.auth,
    required this.language,
  });
  final StaffAuthController auth;
  final UiLanguage language;
  @override
  State<OrderHistoryPanel> createState() => _OrderHistoryPanelState();
}

class _OrderHistoryPanelState extends State<OrderHistoryPanel> {
  final search = TextEditingController();
  final rowsScroll = ScrollController();
  Timer? debounce;
  late DateTime from, to;
  String status = 'all', selected = '';
  Map<String, dynamic>? data;
  int page = 0, generation = 0;
  bool busy = false, printing = false;
  String? error;
  String get scope =>
      '${widget.auth.session?.base}|${widget.auth.session?.storeRef}|${widget.auth.session?.employeeRef}|${widget.auth.session?.permissions.join(',')}';
  late String loadedScope;
  String l(String zh, String en, String tw, String th) =>
      [zh, en, tw, th][widget.language.index];
  DateTime get today {
    final now = DateTime.now().toUtc().add(const Duration(hours: 2));
    return DateTime(now.year, now.month, now.day);
  }

  String day(DateTime value) => value.toIso8601String().substring(0, 10);
  String money(dynamic cents) =>
      '¥ ${((cents as num) / 100).toStringAsFixed(2)}';
  String time(dynamic value) => value == null
      ? '—'
      : DateTime.parse(value as String)
            .toUtc()
            .add(const Duration(hours: 8))
            .toIso8601String()
            .substring(0, 19)
            .replaceFirst('T', ' ');
  List<Map<String, dynamic>> get orders => (data?['orders'] as List? ?? [])
      .map((v) => Map<String, dynamic>.from(v as Map))
      .toList();
  Map<String, dynamic>? get current {
    for (final order in orders) {
      if (order['orderRef'] == selected) return order;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    from = to = today;
    loadedScope = scope;
    widget.auth.addListener(authChanged);
    unawaited(load());
  }

  void authChanged() {
    if (loadedScope == scope) return;
    loadedScope = scope;
    generation++;
    data = null;
    selected = '';
    if (mounted) unawaited(load());
  }

  @override
  void dispose() {
    generation++;
    debounce?.cancel();
    widget.auth.removeListener(authChanged);
    search.dispose();
    rowsScroll.dispose();
    super.dispose();
  }

  Future<void> load() async {
    final request = ++generation, identity = scope;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final result = await widget.auth.readOrderHistory(
        from: day(from),
        to: day(to),
        search: search.text.trim(),
        status: status,
        page: page,
      );
      if (!mounted || request != generation || scope != identity) return;
      setState(() {
        data = result;
        if (!orders.any((o) => o['orderRef'] == selected))
          selected = orders.isEmpty ? '' : orders.first['orderRef'] as String;
      });
      if (rowsScroll.hasClients) rowsScroll.jumpTo(0);
    } catch (_) {
      if (mounted && request == generation)
        setState(
          () => error = l(
            '订单未能读取，请重试',
            'Could not load orders. Retry.',
            '訂單未能讀取，請重試',
            'โหลดรายการไม่สำเร็จ โปรดลองอีกครั้ง',
          ),
        );
    } finally {
      if (mounted && request == generation) setState(() => busy = false);
    }
  }

  void changeDates(DateTime first, DateTime last) {
    debounce?.cancel();
    setState(() {
      from = first;
      to = last;
      page = 0;
    });
    unawaited(load());
  }

  Future<void> chooseDates() async {
    final range = await showDateRangePicker(
      context: context,
      builder: (context, child) => Center(
        child: SizedBox(
          width: 720,
          height: 650,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Localizations.override(
              context: context,
              locale: switch (widget.language) {
                UiLanguage.zh => const Locale('zh', 'CN'),
                UiLanguage.tw => const Locale('zh', 'TW'),
                UiLanguage.en => const Locale('en'),
                UiLanguage.th => const Locale('th'),
              },
              delegates: GlobalMaterialLocalizations.delegates,
              child: child,
            ),
          ),
        ),
      ),
      saveText: l('确定', 'Apply', '確定', 'ยืนยัน'),
      firstDate: DateTime(2020),
      lastDate: today,
      initialDateRange: DateTimeRange(start: from, end: to),
      initialEntryMode: DatePickerEntryMode.calendarOnly,
      helpText: l(
        '选择营业日期（最多93天）',
        'Business dates (up to 93 days)',
        '選擇營業日期（最多93天）',
        'วันที่ทำการ (ไม่เกิน 93 วัน)',
      ),
    );
    if (range == null || !mounted) return;
    if (range.end.difference(range.start).inDays > 92) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            l(
              '一次最多查询93天',
              'Select up to 93 days',
              '一次最多查詢93天',
              'เลือกได้ไม่เกิน 93 วัน',
            ),
          ),
        ),
      );
      return;
    }
    changeDates(range.start, range.end);
  }

  String statusText(Map<String, dynamic> o) {
    if ((o['refundCents'] as num) > 0)
      return o['refundCents'] == o['paidCents']
          ? l('已退款', 'Refunded', '已退款', 'คืนเงินแล้ว')
          : l('部分退款', 'Part refunded', '部分退款', 'คืนบางส่วน');
    return filterText(o['status'] as String);
  }

  String filterText(String value) => switch (value) {
    'pending' => l('未付款', 'Unpaid', '未付款', 'ยังไม่ชำระ'),
    'paid' => l('已付款', 'Paid', '已付款', 'ชำระแล้ว'),
    'expired' => l('已关闭', 'Closed', '已關閉', 'ปิดแล้ว'),
    'waived' => l('已免单', 'Complimentary', '已免單', 'ฟรี'),
    'refunded' => l('有退款', 'Refunds', '有退款', 'มีการคืนเงิน'),
    _ => l('全部状态', 'All statuses', '全部狀態', 'ทุกสถานะ'),
  };
  Color statusColor(Map<String, dynamic> o) => (o['refundCents'] as num) > 0
      ? const Color(0xFF8E5273)
      : o['status'] == 'pending'
      ? const Color(0xFFC74D32)
      : o['status'] == 'paid'
      ? forest
      : const Color(0xFF777B77);
  String method(String value) => switch (value) {
    'wechat' => l('微信支付', 'WeChat Pay', '微信支付', 'WeChat Pay'),
    'alipay' => l('支付宝', 'Alipay', '支付寶', 'Alipay'),
    'cash' => l('现金', 'Cash', '現金', 'เงินสด'),
    'bank_code' => l('银行码收款', 'Bank QR', '銀行碼收款', 'QR ธนาคาร'),
    'pos' => l('POS刷卡', 'POS card', 'POS刷卡', 'บัตร POS'),
    'store_balance' => l('本店储值卡', 'Store balance', '本店儲值卡', 'ยอดร้านค้า'),
    'platform_cash' => l(
      '平台现金余额',
      'Platform balance',
      '平台現金餘額',
      'ยอดแพลตฟอร์ม',
    ),
    'member_balance' => l('会员余额', 'Member balance', '會員餘額', 'ยอดสมาชิก'),
    '' => '—',
    _ => l('原交易记录', 'Recorded payment', '原交易記錄', 'ตามรายการชำระ'),
  };
  String localized(dynamic values) {
    final map = values as Map;
    return (map[['zh-CN', 'en', 'zh-TW', 'th'][widget.language.index]] ??
            map['zh-CN'] ??
            '')
        .toString();
  }

  Future<void> printOrder() async {
    final order = current, identity = widget.auth.session;
    if (order == null || identity == null || busy || printing) return;
    setState(() => printing = true);
    try {
      final plan = ReceiptRasterPlan.orderHistory(
        language: widget.language,
        caption: ReceiptCaption(
          storeName: data!['storeName'] as String,
          tableName: order['tableName'] as String,
          partySize: order['partySize'] as int,
        ),
        orderRef: order['orderRef'] as String,
        createdAt: DateTime.parse(order['createdAt'] as String),
        status: statusText(order),
        paymentMethod: method(order['paymentMethod'] as String),
        totalCents: order['totalCents'] as int,
        paidCents: order['paidCents'] as int,
        dueCents: order['dueCents'] as int,
        refundCents: order['refundCents'] as int,
        items: [
          for (final item in order['items'] as List)
            (
              name: localized(item['snapshot']['names']),
              specification: localized(item['snapshot']['specifications']),
              quantity: item['quantity'] as int,
              priceCents: item['priceCents'] as int,
            ),
        ],
      );
      final hash = await Sha256().hash(
        utf8.encode('history:${order['orderRef']}'),
      );
      final result = await printReceiptPlan(
        plan: plan,
        printIdentity: ReceiptPrintIdentity.unpaid(
          base: identity.base.toString(),
          storeRef: identity.storeRef,
          fingerprint: hash.bytes
              .map((b) => b.toRadixString(16).padLeft(2, '0'))
              .join(),
        ),
        current: () =>
            mounted &&
            widget.auth.session?.storeRef == identity.storeRef &&
            widget.auth.session?.employeeRef == identity.employeeRef,
        reprint: true,
      );
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(tr(widget.language, result))));
    } catch (_) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr(widget.language, 'checkoutPrintFailed'))),
        );
    } finally {
      if (mounted) setState(() => printing = false);
    }
  }

  Widget dateButton(String text, bool active, VoidCallback action) => Padding(
    padding: const EdgeInsets.only(right: 8),
    child: OutlinedButton(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(78, 46),
        backgroundColor: active ? forest : Colors.white,
        foregroundColor: active ? Colors.white : ink,
        side: BorderSide(color: active ? forest : const Color(0xFFDADDD7)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      onPressed: action,
      child: Text(text),
    ),
  );
  Widget badge(Map<String, dynamic> order) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: BoxDecoration(
      color: statusColor(order).withValues(alpha: .09),
      borderRadius: BorderRadius.circular(7),
    ),
    child: Text(
      statusText(order),
      style: TextStyle(
        color: statusColor(order),
        fontSize: 13,
        fontWeight: FontWeight.w600,
      ),
    ),
  );
  Widget cell(String text, int flex, {bool right = false, TextStyle? style}) =>
      Expanded(
        flex: flex,
        child: Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: right ? TextAlign.right : TextAlign.left,
          style: style,
        ),
      );
  @override
  Widget build(BuildContext context) {
    final order = current;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      l('订单', 'Orders', '訂單', 'คำสั่งซื้อ'),
                      style: const TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w700,
                        color: ink,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Text(
                      l('历史查询', 'Order history', '歷史查詢', 'ประวัติคำสั่งซื้อ'),
                      style: const TextStyle(fontSize: 13, color: Colors.grey),
                    ),
                    const Spacer(),
                    if (busy)
                      const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    dateButton(
                      l('今日', 'Today', '今日', 'วันนี้'),
                      day(from) == day(today) && from == to,
                      () => changeDates(today, today),
                    ),
                    dateButton(
                      l('昨日', 'Yesterday', '昨日', 'เมื่อวาน'),
                      day(from) ==
                              day(today.subtract(const Duration(days: 1))) &&
                          from == to,
                      () => changeDates(
                        today.subtract(const Duration(days: 1)),
                        today.subtract(const Duration(days: 1)),
                      ),
                    ),
                    dateButton(
                      l('自选日期', 'Dates', '自選日期', 'เลือกวันที่'),
                      !(from == to &&
                          (day(from) == day(today) ||
                              day(from) ==
                                  day(
                                    today.subtract(const Duration(days: 1)),
                                  ))),
                      chooseDates,
                    ),
                    const Spacer(),
                    DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        value: status,
                        items: [
                          for (final s in [
                            'all',
                            'pending',
                            'paid',
                            'expired',
                            'waived',
                            'refunded',
                          ])
                            DropdownMenuItem(
                              value: s,
                              child: Text(
                                filterText(s),
                                style: const TextStyle(fontSize: 14),
                              ),
                            ),
                        ],
                        onChanged: (s) {
                          if (s == null) return;
                          debounce?.cancel();
                          setState(() {
                            status = s;
                            page = 0;
                          });
                          unawaited(load());
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                SizedBox(
                  height: 48,
                  child: TextField(
                    controller: search,
                    maxLength: 64,
                    decoration: InputDecoration(
                      counterText: '',
                      hintText: l(
                        '搜索订单号 / 桌号',
                        'Search order / table',
                        '搜尋訂單號 / 桌號',
                        'ค้นหาเลขคำสั่งซื้อ / โต๊ะ',
                      ),
                      prefixIcon: const Icon(Icons.search, size: 22),
                      suffixIcon: IconButton(
                        onPressed: () {
                          search.clear();
                          page = 0;
                          debounce?.cancel();
                          unawaited(load());
                        },
                        icon: const Icon(Icons.close, size: 18),
                      ),
                      filled: true,
                      fillColor: Colors.white,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide.none,
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14,
                      ),
                    ),
                    onChanged: (_) {
                      debounce?.cancel();
                      debounce = Timer(const Duration(milliseconds: 350), () {
                        page = 0;
                        unawaited(load());
                      });
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    '${day(from)} 06:00 — ${day(to.add(const Duration(days: 1)))} 06:00',
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFF858B83),
                    ),
                  ),
                ),
                if (error != null)
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          error!,
                          style: const TextStyle(color: Colors.red),
                        ),
                      ),
                      TextButton(
                        onPressed: load,
                        child: Text(l('重试', 'Retry', '重試', 'ลองอีกครั้ง')),
                      ),
                    ],
                  ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFFE9EBE5),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      cell(l('桌号', 'Table', '桌號', 'โต๊ะ'), 2),
                      cell(
                        l(
                          '订单 / 下单时间',
                          'Order / time',
                          '訂單 / 下單時間',
                          'คำสั่งซื้อ / เวลา',
                        ),
                        5,
                      ),
                      cell(l('金额', 'Total', '金額', 'ยอด'), 3, right: true),
                      cell(l('已付', 'Paid', '已付', 'ชำระแล้ว'), 3, right: true),
                      const SizedBox(width: 16),
                      cell(l('状态', 'Status', '狀態', 'สถานะ'), 3, right: true),
                    ],
                  ),
                ),
                const SizedBox(height: 4),
                Expanded(
                  child: orders.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.receipt_long_outlined,
                                size: 46,
                                color: Color(0xFFB7BDB5),
                              ),
                              const SizedBox(height: 14),
                              Text(
                                busy
                                    ? l(
                                        '正在读取订单',
                                        'Loading orders',
                                        '正在讀取訂單',
                                        'กำลังโหลด',
                                      )
                                    : l(
                                        '该时段没有符合条件的订单',
                                        'No matching orders',
                                        '該時段沒有符合條件的訂單',
                                        'ไม่มีคำสั่งซื้อที่ตรงกัน',
                                      ),
                                style: const TextStyle(color: Colors.grey),
                              ),
                            ],
                          ),
                        )
                      : AbsorbPointer(
                          absorbing: busy || error != null,
                          child: ListView.builder(
                            controller: rowsScroll,
                            itemCount: orders.length,
                            itemBuilder: (context, index) {
                              final o = orders[index],
                                  active = o['orderRef'] == selected;
                              return Padding(
                                padding: const EdgeInsets.only(bottom: 5),
                                child: Material(
                                  color: active
                                      ? const Color(0xFFE3EAE1)
                                      : Colors.white,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(9),
                                    side: BorderSide(
                                      color: active
                                          ? forest
                                          : const Color(0xFFE5E7E0),
                                      width: active ? 1.4 : 1,
                                    ),
                                  ),
                                  child: InkWell(
                                    borderRadius: BorderRadius.circular(9),
                                    onTap: () => setState(
                                      () => selected = o['orderRef'] as String,
                                    ),
                                    child: SizedBox(
                                      height: 72,
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 14,
                                        ),
                                        child: Row(
                                          children: [
                                            cell(
                                              o['tableName'] as String,
                                              2,
                                              style: const TextStyle(
                                                fontSize: 18,
                                                fontWeight: FontWeight.w700,
                                                color: ink,
                                              ),
                                            ),
                                            Expanded(
                                              flex: 5,
                                              child: Column(
                                                mainAxisAlignment:
                                                    MainAxisAlignment.center,
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: [
                                                  Text(
                                                    o['orderRef'] as String,
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: const TextStyle(
                                                      fontSize: 13,
                                                      fontWeight:
                                                          FontWeight.w500,
                                                    ),
                                                  ),
                                                  const SizedBox(height: 6),
                                                  Text(
                                                    time(o['createdAt']),
                                                    style: const TextStyle(
                                                      fontSize: 11,
                                                      color: Colors.grey,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                            cell(
                                              money(o['totalCents']),
                                              3,
                                              right: true,
                                              style: const TextStyle(
                                                fontSize: 15,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                            cell(
                                              money(o['paidCents']),
                                              3,
                                              right: true,
                                              style: const TextStyle(
                                                fontSize: 14,
                                                color: Color(0xFF6B766C),
                                              ),
                                            ),
                                            const SizedBox(width: 16),
                                            Expanded(
                                              flex: 3,
                                              child: Align(
                                                alignment:
                                                    Alignment.centerRight,
                                                child: badge(o),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${l('共', 'Total', '共', 'ทั้งหมด')} ${data?['totalCount'] ?? 0} ${l('笔', 'orders', '筆', 'รายการ')}  ·  ${l('订单金额', 'Order total', '訂單金額', 'ยอดคำสั่งซื้อ')} ${money(data?['totalCents'] ?? 0)}',
                        style: const TextStyle(
                          fontSize: 13,
                          color: Color(0xFF667267),
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: busy || page == 0
                          ? null
                          : () {
                              page--;
                              unawaited(load());
                            },
                      icon: const Icon(Icons.chevron_left),
                      constraints: const BoxConstraints(
                        minWidth: 48,
                        minHeight: 48,
                      ),
                    ),
                    Text(
                      '${page + 1} / ${(((data?['totalCount'] as int? ?? 0) + 19) ~/ 20).clamp(1, 10001)}',
                    ),
                    IconButton(
                      onPressed:
                          busy ||
                              (page + 1) * 20 >=
                                  (data?['totalCount'] as int? ?? 0)
                          ? null
                          : () {
                              page++;
                              unawaited(load());
                            },
                      icon: const Icon(Icons.chevron_right),
                      constraints: const BoxConstraints(
                        minWidth: 48,
                        minHeight: 48,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        Container(width: 1, color: const Color(0xFFD9DDD4)),
        SizedBox(
          width: 370,
          child: ColoredBox(
            color: Colors.white,
            child: order == null
                ? Center(
                    child: Text(
                      l(
                        '选择订单查看明细',
                        'Select an order',
                        '選擇訂單查看明細',
                        'เลือกคำสั่งซื้อ',
                      ),
                      style: const TextStyle(color: Colors.grey),
                    ),
                  )
                : detail(order),
          ),
        ),
      ],
    );
  }

  Widget section(String title) => Padding(
    padding: const EdgeInsets.only(top: 20, bottom: 12),
    child: Text(
      title,
      style: const TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.w700,
        color: ink,
      ),
    ),
  );
  Widget pair(String key, String value, {bool strong = false}) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          key,
          style: const TextStyle(fontSize: 13, color: Color(0xFF80877E)),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            value,
            textAlign: TextAlign.right,
            style: TextStyle(
              fontSize: strong ? 21 : 13,
              fontWeight: strong ? FontWeight.w700 : FontWeight.w500,
              color: ink,
            ),
          ),
        ),
      ],
    ),
  );
  Widget detail(Map<String, dynamic> o) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              decoration: BoxDecoration(
                color: forest,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                o['tableName'] as String,
                style: const TextStyle(
                  fontSize: 21,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Text(
              l('订单明细', 'Details', '訂單明細', 'รายละเอียด'),
              style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
            ),
            const Spacer(),
            badge(o),
          ],
        ),
      ),
      const Divider(height: 1),
      Expanded(
        child: SingleChildScrollView(
          key: ValueKey(selected),
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              section(l('商品信息', 'Items', '商品資訊', 'สินค้า')),
              for (final item in o['items'] as List)
                Container(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  decoration: const BoxDecoration(
                    border: Border(
                      bottom: BorderSide(color: Color(0xFFEAECE7)),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Text(
                              localized(item['snapshot']['names']),
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Text(
                            '× ${item['quantity']}',
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 5),
                      Text(
                        localized(item['snapshot']['specifications']),
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.grey,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Text(
                            '${l('单价', 'Unit', '單價', 'ราคาต่อหน่วย')} ${money(item['priceCents'])}',
                            style: const TextStyle(
                              fontSize: 12,
                              color: Colors.grey,
                            ),
                          ),
                          const Spacer(),
                          Text(
                            money(item['subtotalCents']),
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              section(l('付款信息', 'Payment', '付款資訊', 'การชำระเงิน')),
              pair(
                l('订单金额', 'Order total', '訂單金額', 'ยอดคำสั่งซื้อ'),
                money(o['totalCents']),
                strong: true,
              ),
              pair(l('已付', 'Paid', '已付', 'ชำระแล้ว'), money(o['paidCents'])),
              pair(l('未付', 'Unpaid', '未付', 'ยังไม่ชำระ'), money(o['dueCents'])),
              if ((o['refundCents'] as num) > 0)
                pair(
                  l('已退款', 'Refunded', '已退款', 'คืนแล้ว'),
                  money(o['refundCents']),
                ),
              pair(
                l('支付方式', 'Method', '支付方式', 'วิธีชำระ'),
                method(o['paymentMethod'] as String),
              ),
              if (o['paidAt'] != null)
                pair(
                  l('付款时间', 'Paid at', '付款時間', 'เวลาชำระ'),
                  time(o['paidAt']),
                ),
              section(
                l('订单信息', 'Order information', '訂單資訊', 'ข้อมูลคำสั่งซื้อ'),
              ),
              pair(
                l('订单号', 'Order', '訂單號', 'เลขคำสั่งซื้อ'),
                o['orderRef'] as String,
              ),
              pair(
                l('下单时间', 'Created', '下單時間', 'เวลาสั่ง'),
                time(o['createdAt']),
              ),
              pair(
                l('来源', 'Source', '來源', 'ที่มา'),
                o['origin'] == 'app'
                    ? l(
                        'APP / 扫码点单',
                        'APP / QR order',
                        'APP / 掃碼點單',
                        'APP / QR',
                      )
                    : l('收银台', 'Cashier', '收銀台', 'แคชเชียร์'),
              ),
              if ((o['cashierName'] as String).isNotEmpty)
                pair(
                  l('收银员', 'Staff', '收銀員', 'พนักงาน'),
                  o['cashierName'] as String,
                ),
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
      Container(
        padding: const EdgeInsets.all(16),
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: Color(0xFFE4E7DE))),
        ),
        child: SizedBox(
          width: double.infinity,
          height: 56,
          child: FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: forest,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            onPressed: busy || printing || error != null ? null : printOrder,
            icon: const Icon(Icons.print_outlined, size: 23),
            label: Text(
              printing
                  ? l('正在打印', 'Printing', '正在列印', 'กำลังพิมพ์')
                  : l('补打小票', 'Reprint receipt', '補印小票', 'พิมพ์ใบเสร็จซ้ำ'),
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
            ),
          ),
        ),
      ),
    ],
  );
}
