import 'dart:math';

import 'package:flutter/material.dart';

import '../auth/staff_auth_controller.dart';
import '../strings.dart';

class CashbookPanel extends StatefulWidget {
  const CashbookPanel({super.key, required this.auth, required this.language});
  final StaffAuthController auth;
  final UiLanguage language;
  @override
  State<CashbookPanel> createState() => _CashbookPanelState();
}

class _CashbookPanelState extends State<CashbookPanel> {
  static const green = Color(0xff183e35);
  late DateTime from, to;
  Map<String, dynamic>? data;
  String? error;
  bool busy = false;
  int page = 0, epoch = 0;
  final selected = <String>{};
  String l(String zh, String en, String tw, String th) =>
      [zh, en, tw, th][widget.language.index];
  String money(dynamic n) => '¥ ${((n as num? ?? 0) / 100).toStringAsFixed(2)}';
  String kind(String k) => switch (k) {
    'income' => l('零星收入', 'Income', '零星收入', 'รายรับ'),
    'expense' => l('备用金支出', 'Petty cash expense', '備用金支出', 'รายจ่ายเงินสำรอง'),
    _ => l('员工垫款', 'Staff advance', '員工墊款', 'พนักงานสำรองจ่าย'),
  };
  String status(String k) => switch (k) {
    'confirmed' => l('已确认', 'Confirmed', '已確認', 'ยืนยันแล้ว'),
    'reimbursed' => l('已报销', 'Reimbursed', '已報銷', 'คืนเงินแล้ว'),
    'void' => l('已作废', 'Void', '已作廢', 'ยกเลิกแล้ว'),
    _ => l('待确认', 'Pending', '待確認', 'รอยืนยัน'),
  };
  List<Map<String, dynamic>> get rows => (data?['entries'] as List? ?? [])
      .map((e) => Map<String, dynamic>.from(e as Map))
      .toList();
  bool get admin => data?['canReview'] == 1 || data?['canReview'] == true;
  @override
  void initState() {
    super.initState();
    setRange(false);
    load();
  }

  void setRange(bool week) {
    final n = DateTime.now().subtract(const Duration(hours: 6));
    from = DateTime(n.year, n.month, n.day, 6);
    if (week) from = from.subtract(Duration(days: n.weekday - 1));
    to = DateTime(n.year, n.month, n.day, 6).add(const Duration(days: 1));
    page = 0;
    selected.clear();
  }

  @override
  void dispose() {
    epoch++;
    super.dispose();
  }

  Future<bool> load([Map<String, dynamic>? action]) async {
    final id = ++epoch;
    setState(() => busy = true);
    try {
      final result = await widget.auth.cashbook({
        'from': from.toUtc().toIso8601String(),
        'to': to.toUtc().toIso8601String(),
        if (action == null) 'page': page,
        'action': 'context',
        ...?action,
      });
      if (!mounted || id != epoch) return false;
      setState(() {
        data = result;
        error = null;
        selected.clear();
        if (action != null) page = 0;
      });
      return true;
    } catch (_) {
      if (mounted && id == epoch)
        setState(
          () => error = l(
            '未能完成，请重试核对结果',
            'Could not finish. Retry to check.',
            '未能完成，請重試核對結果',
            'ไม่สำเร็จ กรุณาลองตรวจสอบอีกครั้ง',
          ),
        );
      return false;
    } finally {
      if (mounted && id == epoch) setState(() => busy = false);
    }
  }

  Future<void> dates() async {
    final v = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
      initialDateRange: DateTimeRange(
        start: DateTime(from.year, from.month, from.day),
        end: to.subtract(const Duration(days: 1)),
      ),
    );
    if (v == null || !mounted) return;
    setState(() {
      from = DateTime(v.start.year, v.start.month, v.start.day, 6);
      to = DateTime(
        v.end.year,
        v.end.month,
        v.end.day,
        6,
      ).add(const Duration(days: 1));
      page = 0;
    });
    await load();
  }

  Future<void> review(String action) async {
    final refs = rows
        .where(
          (r) =>
              selected.contains(r['ref']) &&
              r['status'] == 'pending' &&
              (action == 'void' ||
                  (action == 'reimburse') == (r['kind'] == 'advance')),
        )
        .map((r) => r['ref'])
        .toList();
    if (refs.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(
          action == 'reimburse'
              ? l(
                  '确认已完成报销',
                  'Confirm reimbursement paid',
                  '確認已完成報銷',
                  'ยืนยันว่าคืนเงินแล้ว',
                )
              : action == 'void'
              ? l(
                  '作废所选记录',
                  'Void selected entries',
                  '作廢所選記錄',
                  'ยกเลิกรายการที่เลือก',
                )
              : l('确认所选收支', 'Confirm entries', '確認所選收支', 'ยืนยันรายการ'),
        ),
        content: Text(
          action == 'reimburse'
              ? l(
                  '请确认已经把垫款退还给员工。这一步只登记报销，不会自动转账。',
                  'Confirm the staff member has been repaid. This records reimbursement only.',
                  '請確認已經把墊款退還給員工。這一步只登記報銷，不會自動轉帳。',
                  'โปรดยืนยันว่าได้คืนเงินพนักงานแล้ว ขั้นตอนนี้บันทึกเท่านั้น',
                )
              : l(
                  '确认后保留登记人和审核记录。',
                  'The recorder and reviewer will be retained.',
                  '確認後保留登記人和審核記錄。',
                  'เก็บข้อมูลผู้บันทึกและผู้ยืนยัน',
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: Text(l('取消', 'Cancel', '取消', 'ยกเลิก')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: Text(l('确认', 'Confirm', '確認', 'ยืนยัน')),
          ),
        ],
      ),
    );
    if (ok == true && mounted) await load({'action': action, 'refs': refs});
  }

  Future<void> add(String type) async {
    final saved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _CashbookEntry(
        auth: widget.auth,
        language: widget.language,
        type: type,
        title: kind(type),
        from: from,
        to: to,
      ),
    );
    if (saved == true && mounted) {
      setState(() => setRange(false));
      await load();
    }
  }

  String date(dynamic value) {
    final d = DateTime.tryParse('$value')?.toLocal();
    return d == null
        ? '—'
        : '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final summary = data?['summary'] as Map? ?? {};
    return ColoredBox(
      color: const Color(0xfff5f4ef),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text(
                  l('流水账', 'Cashbook', '流水帳', 'บัญชีรายวัน'),
                  style: const TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                for (final k in ['income', 'expense', 'advance'])
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(left: 10),
                      child: FilledButton.icon(
                        onPressed: busy ? null : () => add(k),
                        icon: const Icon(Icons.add, size: 20),
                        label: Text(
                          kind(k),
                          textAlign: TextAlign.center,
                          maxLines: 2,
                        ),
                        style: FilledButton.styleFrom(
                          backgroundColor: green,
                          minimumSize: const Size(110, 50),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                for (final option in [false, true])
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: OutlinedButton(
                      onPressed: busy
                          ? null
                          : () {
                              setState(() => setRange(option));
                              load();
                            },
                      child: Text(
                        option
                            ? l('本周', 'This week', '本週', 'สัปดาห์นี้')
                            : l('今日', 'Today', '今日', 'วันนี้'),
                      ),
                    ),
                  ),
                OutlinedButton.icon(
                  onPressed: busy ? null : dates,
                  icon: const Icon(Icons.calendar_month_outlined),
                  label: Text(
                    '${from.month}/${from.day} — ${to.subtract(const Duration(days: 1)).month}/${to.subtract(const Duration(days: 1)).day}',
                  ),
                ),
                const Spacer(),
                IconButton(
                  onPressed: busy ? null : () => load(),
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                for (final item in [
                  ('incomeCents', l('零星收入', 'Income', '零星收入', 'รายรับ')),
                  (
                    'expenseCents',
                    l('备用金支出', 'Petty cash spent', '備用金支出', 'รายจ่าย'),
                  ),
                  (
                    'advanceCents',
                    l('待报销', 'To reimburse', '待報銷', 'รอคืนเงิน'),
                  ),
                  (
                    'reimbursedCents',
                    l('已报销', 'Reimbursed', '已報銷', 'คืนเงินแล้ว'),
                  ),
                ])
                  Expanded(
                    child: Container(
                      margin: const EdgeInsets.only(right: 10),
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            item.$2,
                            style: const TextStyle(color: Colors.black54),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            money(summary[item.$1]),
                            style: const TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            if (error != null)
              Text(error!, style: const TextStyle(color: Colors.red)),
            Expanded(
              child: data == null
                  ? Center(
                      child: busy
                          ? const CircularProgressIndicator()
                          : Text(
                              l('暂无记录', 'No entries', '暫無記錄', 'ไม่มีรายการ'),
                            ),
                    )
                  : rows.isEmpty
                  ? Center(
                      child: Text(
                        l(
                          '这个时段还没有流水，点击上方按钮登记',
                          'No entries in this period',
                          '這個時段還沒有流水，點擊上方按鈕登記',
                          'ยังไม่มีรายการในช่วงนี้',
                        ),
                      ),
                    )
                  : LayoutBuilder(
                      builder: (context, c) => SingleChildScrollView(
                        child: SizedBox(
                          width: c.maxWidth,
                          child: DataTable(
                            dataTextStyle: const TextStyle(
                              fontSize: 13,
                              color: Colors.black87,
                            ),
                            headingTextStyle: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: Colors.black87,
                            ),
                            showCheckboxColumn: admin,
                            columnSpacing: 12,
                            horizontalMargin: 12,
                            dataRowMinHeight: 62,
                            dataRowMaxHeight: 80,
                            headingRowColor: const WidgetStatePropertyAll(
                              Color(0xffe7ece8),
                            ),
                            columns: [
                              for (final v in [
                                l(
                                  '日期 / 类型',
                                  'Date / type',
                                  '日期 / 類型',
                                  'วันที่ / ประเภท',
                                ),
                                l(
                                  '事由 / 经办人',
                                  'Purpose / person',
                                  '事由 / 經辦人',
                                  'เหตุผล / ผู้ดำเนินการ',
                                ),
                                l('收入', 'In', '收入', 'รับ'),
                                l(
                                  '支出 / 垫款',
                                  'Out / advance',
                                  '支出 / 墊款',
                                  'จ่าย / สำรอง',
                                ),
                                l('状态', 'Status', '狀態', 'สถานะ'),
                              ])
                                DataColumn(label: Flexible(child: Text(v))),
                            ],
                            rows: [
                              for (final r in rows)
                                DataRow(
                                  selected: selected.contains(r['ref']),
                                  onSelectChanged:
                                      admin && r['status'] == 'pending'
                                      ? (v) => setState(() {
                                          if (v == true) {
                                            selected.add(r['ref']);
                                          } else {
                                            selected.remove(r['ref']);
                                          }
                                        })
                                      : null,
                                  cells: [
                                    DataCell(
                                      Column(
                                        mainAxisAlignment:
                                            MainAxisAlignment.center,
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            date(r['createdAt']),
                                            style: const TextStyle(
                                              fontSize: 12,
                                            ),
                                          ),
                                          Text(kind('${r['kind']}')),
                                        ],
                                      ),
                                    ),
                                    DataCell(
                                      SizedBox(
                                        width: c.maxWidth * .25,
                                        child: Column(
                                          mainAxisAlignment:
                                              MainAxisAlignment.center,
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              '${r['note']}',
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                            Text(
                                              '${r['person']}',
                                              style: const TextStyle(
                                                fontSize: 12,
                                                color: Colors.black54,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      onTap: () => showDialog<void>(
                                        context: context,
                                        builder: (ctx) => AlertDialog(
                                          title: Text('${r['note']}'),
                                          content: SelectableText(
                                            '${r['person']}\n${r['voucher']}\n${r['ref']}\n${r['createdName'] ?? r['createdBy']}\n${r['reviewedName'] ?? ''} ${date(r['reviewedAt'])}',
                                          ),
                                          actions: [
                                            TextButton(
                                              onPressed: () =>
                                                  Navigator.pop(ctx),
                                              child: Text(
                                                l('关闭', 'Close', '關閉', 'ปิด'),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                    DataCell(
                                      Text(
                                        r['kind'] == 'income'
                                            ? money(r['amountCents'])
                                            : '—',
                                      ),
                                    ),
                                    DataCell(
                                      Text(
                                        r['kind'] != 'income'
                                            ? money(r['amountCents'])
                                            : '—',
                                      ),
                                    ),
                                    DataCell(
                                      Text(
                                        status('${r['status']}'),
                                        style: TextStyle(
                                          color: r['status'] == 'pending'
                                              ? Colors.deepOrange
                                              : green,
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
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(
                    l(
                      '独立收支登记 · 不含订单收款',
                      'Separate register · excludes order receipts',
                      '獨立收支登記 · 不含訂單收款',
                      'บันทึกแยก ไม่รวมรับเงินคำสั่งซื้อ',
                    ),
                    style: const TextStyle(fontSize: 12, color: Colors.black54),
                  ),
                ),
                if (admin) ...[
                  TextButton(
                    onPressed: busy || selected.isEmpty
                        ? null
                        : () => review('void'),
                    child: Text(l('作废', 'Void', '作廢', 'ยกเลิก')),
                  ),
                  const SizedBox(width: 6),
                  OutlinedButton(
                    onPressed:
                        busy ||
                            !rows.any(
                              (r) =>
                                  selected.contains(r['ref']) &&
                                  r['kind'] != 'advance',
                            )
                        ? null
                        : () => review('confirm'),
                    child: Text(l('确认收支', 'Confirm', '確認收支', 'ยืนยัน')),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed:
                        busy ||
                            !rows.any(
                              (r) =>
                                  selected.contains(r['ref']) &&
                                  r['kind'] == 'advance',
                            )
                        ? null
                        : () => review('reimburse'),
                    child: Text(
                      l('确认已报销', 'Mark reimbursed', '確認已報銷', 'ยืนยันคืนเงิน'),
                    ),
                  ),
                ],
                IconButton(
                  onPressed: busy || page == 0
                      ? null
                      : () {
                          setState(() => page--);
                          load();
                        },
                  icon: const Icon(Icons.chevron_left),
                ),
                Text('${page + 1}'),
                IconButton(
                  onPressed:
                      busy || (page + 1) * 50 >= (data?['total'] as num? ?? 0)
                      ? null
                      : () {
                          setState(() => page++);
                          load();
                        },
                  icon: const Icon(Icons.chevron_right),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _CashbookEntry extends StatefulWidget {
  const _CashbookEntry({
    required this.auth,
    required this.language,
    required this.type,
    required this.title,
    required this.from,
    required this.to,
  });
  final StaffAuthController auth;
  final UiLanguage language;
  final String type, title;
  final DateTime from, to;
  @override
  State<_CashbookEntry> createState() => _CashbookEntryState();
}

class _CashbookEntryState extends State<_CashbookEntry> {
  final note = TextEditingController(),
      person = TextEditingController(),
      voucher = TextEditingController();
  String amount = '', method = 'cash';
  bool busy = false;
  String? error;
  Map<String, dynamic>? request;
  late final String requestId;
  String l(String a, String b, String c, String d) =>
      [a, b, c, d][widget.language.index];
  @override
  void initState() {
    super.initState();
    final random = Random.secure();
    final b = List.generate(16, (_) => random.nextInt(256));
    b[6] = (b[6] & 15) | 64;
    b[8] = (b[8] & 63) | 128;
    final h = b.map((n) => n.toRadixString(16).padLeft(2, '0')).join();
    requestId =
        '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
  }

  @override
  void dispose() {
    note.dispose();
    person.dispose();
    voucher.dispose();
    super.dispose();
  }

  Future<void> save() async {
    final cents = ((double.tryParse(amount) ?? 0) * 100).round();
    if (request == null &&
        (cents <= 0 ||
            cents > 100000000 ||
            note.text.trim().isEmpty ||
            person.text.trim().isEmpty)) {
      setState(
        () => error = l(
          '请填写金额、事由和经办人',
          'Enter amount, purpose and person',
          '請填寫金額、事由和經辦人',
          'กรอกจำนวนเงิน เหตุผล และผู้ดำเนินการ',
        ),
      );
      return;
    }
    request ??= {
      'action': 'create',
      'requestId': requestId,
      'kind': widget.type,
      'amountCents': cents,
      'note': note.text.trim(),
      'person': person.text.trim(),
      'method': method,
      'voucher': voucher.text.trim(),
      'from': widget.from.toUtc().toIso8601String(),
      'to': widget.to.toUtc().toIso8601String(),
    };
    setState(() => busy = true);
    try {
      await widget.auth.cashbook(request!);
      if (mounted) Navigator.pop(context, true);
    } catch (_) {
      if (mounted)
        setState(
          () => error = l(
            '未确认保存结果，请点击重试核对',
            'Retry to check the original entry',
            '未確認保存結果，請點擊重試核對',
            'ลองอีกครั้งเพื่อตรวจสอบรายการเดิม',
          ),
        );
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  void key(String k) {
    if (request != null || busy) return;
    setState(() {
      if (k == '⌫') {
        if (amount.isNotEmpty) amount = amount.substring(0, amount.length - 1);
      } else if (k == '.') {
        if (!amount.contains('.')) amount = amount.isEmpty ? '0.' : '$amount.';
      } else if (amount.length < 10 &&
          (!amount.contains('.') || amount.split('.')[1].length < 2)) {
        amount += k;
      }
    });
  }

  @override
  Widget build(BuildContext context) => Dialog(
    child: SizedBox(
      width: 740,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text(
                  widget.title,
                  style: const TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                IconButton(
                  onPressed: busy ? null : () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    children: [
                      TextField(
                        controller: note,
                        enabled: request == null,
                        maxLength: 200,
                        decoration: InputDecoration(
                          labelText: l('事由', 'Purpose', '事由', 'เหตุผล'),
                          border: const OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: person,
                        enabled: request == null,
                        maxLength: 64,
                        decoration: InputDecoration(
                          labelText: widget.type == 'advance'
                              ? l('垫款人', 'Paid by', '墊款人', 'ผู้สำรองจ่าย')
                              : l('经办人', 'Handled by', '經辦人', 'ผู้ดำเนินการ'),
                          border: const OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 10),
                      DropdownButtonFormField<String>(
                        initialValue: method,
                        decoration: InputDecoration(
                          labelText: l('收支方式', 'Method', '收支方式', 'วิธี'),
                          border: const OutlineInputBorder(),
                        ),
                        items: [
                          for (final v in [
                            ('cash', l('现金', 'Cash', '現金', 'เงินสด')),
                            (
                              'bank',
                              l(
                                '银行 / 银行码',
                                'Bank / bank QR',
                                '銀行 / 銀行碼',
                                'ธนาคาร',
                              ),
                            ),
                            ('wechat', l('微信', 'WeChat', '微信', 'WeChat')),
                            ('alipay', l('支付宝', 'Alipay', '支付寶', 'Alipay')),
                            ('other', l('其它', 'Other', '其它', 'อื่น ๆ')),
                          ])
                            DropdownMenuItem(value: v.$1, child: Text(v.$2)),
                        ],
                        onChanged: request != null
                            ? null
                            : (v) => setState(() => method = v!),
                      ),
                      const SizedBox(height: 14),
                      TextField(
                        controller: voucher,
                        enabled: request == null,
                        maxLength: 100,
                        decoration: InputDecoration(
                          labelText: l(
                            '凭证备注（选填）',
                            'Voucher reference (optional)',
                            '憑證備註（選填）',
                            'หมายเหตุหลักฐาน (ไม่บังคับ)',
                          ),
                          border: const OutlineInputBorder(),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 24),
                SizedBox(
                  width: 280,
                  child: Column(
                    children: [
                      Container(
                        alignment: Alignment.centerRight,
                        padding: const EdgeInsets.all(18),
                        decoration: BoxDecoration(
                          color: const Color(0xfff5f4ef),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          '¥ ${amount.isEmpty ? '0.00' : amount}',
                          style: const TextStyle(
                            fontSize: 30,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      GridView.count(
                        crossAxisCount: 3,
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        mainAxisSpacing: 8,
                        crossAxisSpacing: 8,
                        childAspectRatio: 1.6,
                        children: [
                          for (final k in [
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
                              onPressed: request != null || busy
                                  ? null
                                  : () => key(k),
                              child: Text(
                                k,
                                style: const TextStyle(fontSize: 24),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(error!, style: const TextStyle(color: Colors.red)),
              ),
            SizedBox(
              height: 54,
              child: FilledButton(
                onPressed: busy ? null : save,
                child: Text(
                  request == null
                      ? l('保存登记', 'Save entry', '保存登記', 'บันทึก')
                      : l('重试核对', 'Retry', '重試核對', 'ลองอีกครั้ง'),
                  style: const TextStyle(fontSize: 18),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
