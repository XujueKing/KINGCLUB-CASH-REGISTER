import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import '../auth/staff_auth_controller.dart';
import '../network/cashier_realtime_client.dart';
import '../strings.dart';

class ReservationsPanel extends StatefulWidget {
  const ReservationsPanel({
    super.key,
    required this.auth,
    required this.language,
    this.enableRealtime = true,
  });
  final StaffAuthController auth;
  final UiLanguage language;
  final bool enableRealtime;
  @override
  State<ReservationsPanel> createState() => _ReservationsPanelState();
}

class _ReservationsPanelState extends State<ReservationsPanel> {
  static const green = Color(0xff183e35), paper = Color(0xfff5f4ef);
  late DateTime day;
  Map<String, dynamic>? data;
  final selected = <String>{};
  String? focus, error;
  String filter = 'all';
  bool busy = false;
  int epoch = 0, revision = 0;
  CashierRealtimeClient? realtime;
  Timer? debounce;
  late String scope;
  String get identity =>
      '${widget.auth.session?.base}|${widget.auth.session?.storeRef}|${widget.auth.session?.employeeRef}';
  String l(String zh, String en, String tw, String th) =>
      [zh, en, tw, th][widget.language.index];
  bool get canEdit =>
      widget.auth.session?.permissions.contains('table.open') == true;
  List<Map<String, dynamic>> get rows =>
      (data?['reservations'] as List? ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList()
        ..sort((a, b) => '${a['startsAt']}'.compareTo('${b['startsAt']}'));
  Map<String, dynamic> get range => {
    'from': day.add(const Duration(hours: 6)).toUtc().toIso8601String(),
    'to': day.add(const Duration(days: 1, hours: 6)).toUtc().toIso8601String(),
  };
  @override
  void initState() {
    super.initState();
    final now = DateTime.now().subtract(const Duration(hours: 6));
    day = DateTime(now.year, now.month, now.day);
    scope = identity;
    widget.auth.addListener(authChanged);
    connect();
    unawaited(load());
  }

  void connect() {
    if (!widget.enableRealtime) return;
    if (identical(realtime?.session, widget.auth.session)) return;
    realtime?.removeListener(changed);
    realtime?.dispose();
    revision = 0;
    final session = widget.auth.session;
    realtime = session == null ? null : CashierRealtimeClient(session);
    realtime?.addListener(changed);
    realtime?.start();
  }

  void authChanged() {
    if (!mounted) return;
    if (identity != scope) {
      epoch++;
      scope = identity;
      setState(() {
        data = null;
        focus = null;
        selected.clear();
        busy = false;
      });
      unawaited(load());
    }
    connect();
  }

  void changed() {
    if (realtime?.revision == revision) return;
    revision = realtime?.revision ?? 0;
    debounce?.cancel();
    debounce = Timer(const Duration(milliseconds: 400), () {
      if (mounted && !busy) unawaited(load());
    });
  }

  @override
  void dispose() {
    epoch++;
    widget.auth.removeListener(authChanged);
    debounce?.cancel();
    realtime?.removeListener(changed);
    realtime?.dispose();
    super.dispose();
  }

  Future<bool> load([Map<String, dynamic>? action]) async {
    final token = ++epoch;
    if (action != null) setState(() => busy = true);
    try {
      final page = await widget.auth.reservations({
        ...range,
        ...?action,
        'action': action?['action'] ?? 'context',
      });
      if (!mounted || token != epoch) return false;
      setState(() {
        data = page;
        error = null;
        selected.removeWhere((r) => !rows.any((e) => e['ref'] == r));
      });
      return true;
    } catch (e) {
      if (mounted && token == epoch) {
        setState(
          () => error = l(
            '未能完成，请重试；未收到结果不代表操作失败',
            'Could not finish. Retry to check the result.',
            '未能完成，請重試；未收到結果不代表失敗',
            'ทำรายการไม่สำเร็จ กรุณาลองอีกครั้ง',
          ),
        );
      }
      return false;
    } finally {
      if (mounted && token == epoch) setState(() => busy = false);
    }
  }

  String time(dynamic value) {
    final d = DateTime.tryParse('$value')?.toLocal();
    return d == null
        ? '—'
        : '${d.month}/${d.day} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }

  String status(Map<String, dynamic> r) => switch (r['status']) {
    'waiting' => l('待安排', 'Waiting', '待安排', 'รอจัดที่นั่ง'),
    'notified' => l('已通知', 'Notified', '已通知', 'แจ้งแล้ว'),
    'reserved' => l('已安排', 'Assigned', '已安排', 'จัดแล้ว'),
    'arrived' => l('已到店', 'Arrived', '已到店', 'มาถึงแล้ว'),
    'cancelled' => l('已取消', 'Cancelled', '已取消', 'ยกเลิกแล้ว'),
    _ => l('已结束', 'Ended', '已結束', 'สิ้นสุด'),
  };
  Widget button(
    String title,
    VoidCallback? tap, {
    IconData? icon,
    bool primary = false,
  }) => SizedBox(
    height: 52,
    child: primary
        ? FilledButton(
            onPressed: tap,
            style: FilledButton.styleFrom(backgroundColor: green),
            child: Text(title),
          )
        : OutlinedButton(
            onPressed: tap,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 20),
                  const SizedBox(width: 8),
                ],
                Flexible(child: Text(title, textAlign: TextAlign.center)),
              ],
            ),
          ),
  );
  Future<void> datePicker() async {
    final d = await showDatePicker(
      context: context,
      initialDate: day,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 366)),
    );
    if (d != null && mounted) {
      setState(() {
        day = d;
        selected.clear();
        focus = null;
        data = null;
      });
      await load();
    }
  }

  Future<void> create() async {
    final name = TextEditingController(),
        phone = TextEditingController(),
        note = TextEditingController();
    int count = 2, hour = 19, duration = 3;
    bool aa = false, saving = false;
    String? warning;
    final b = List.generate(16, (_) => Random.secure().nextInt(256));
    b[6] = (b[6] & 15) | 64;
    b[8] = (b[8] & 63) | 128;
    final hex = b.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
    final ref =
        '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialog) => StatefulBuilder(
        builder: (context, update) => Dialog(
          child: SizedBox(
            width: 720,
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            l(
                              '电话预约',
                              'Telephone booking',
                              '電話預約',
                              'จองทางโทรศัพท์',
                            ),
                            style: const TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        IconButton(
                          onPressed: saving
                              ? null
                              : () => Navigator.pop(dialog),
                          icon: const Icon(Icons.close),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: name,
                            decoration: InputDecoration(
                              labelText: l('称呼', 'Guest name', '稱呼', 'ชื่อ'),
                            ),
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: TextField(
                            controller: phone,
                            keyboardType: TextInputType.phone,
                            decoration: InputDecoration(
                              labelText: l('联系电话', 'Phone', '聯絡電話', 'โทรศัพท์'),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    Wrap(
                      spacing: 12,
                      children: [
                        ChoiceChip(
                          label: Text(
                            l('整桌预约', 'Whole table', '整桌預約', 'ทั้งโต๊ะ'),
                          ),
                          selected: !aa,
                          onSelected: saving
                              ? null
                              : (_) => update(() => aa = false),
                        ),
                        ChoiceChip(
                          label: Text(
                            l(
                              'AA 拼桌报名',
                              'AA shared table',
                              'AA 拼桌報名',
                              'แชร์โต๊ะ AA',
                            ),
                          ),
                          selected: aa,
                          onSelected: saving
                              ? null
                              : (_) => update(() => aa = true),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Text(l('人数', 'Guests', '人數', 'จำนวน')),
                        IconButton(
                          onPressed: !saving && count > 1
                              ? () => update(() => count--)
                              : null,
                          icon: const Icon(Icons.remove_circle_outline),
                        ),
                        Text(
                          '$count',
                          style: const TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        IconButton(
                          onPressed: !saving && count < 100
                              ? () => update(() => count++)
                              : null,
                          icon: const Icon(Icons.add_circle_outline),
                        ),
                        const Spacer(),
                        Text('${day.month}/${day.day}'),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text(l('到店时间', 'Arrival time', '到店時間', 'เวลามาถึง')),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: List.generate(12, (i) {
                        final h = (i + 16) % 24;
                        return ChoiceChip(
                          label: Text('${h.toString().padLeft(2, '0')}:00'),
                          selected: hour == h,
                          onSelected: saving
                              ? null
                              : (_) => update(() => hour = h),
                        );
                      }),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 12,
                      children: [
                        for (final v in [2, 3, 4, 6])
                          ChoiceChip(
                            label: Text(
                              '$v ${l('小时', 'hours', '小時', 'ชั่วโมง')}',
                            ),
                            selected: duration == v,
                            onSelected: saving
                                ? null
                                : (_) => update(() => duration = v),
                          ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: note,
                      maxLength: 300,
                      decoration: InputDecoration(
                        labelText: l(
                          '备注（选填）',
                          'Note (optional)',
                          '備註（選填）',
                          'หมายเหตุ',
                        ),
                      ),
                    ),
                    if (warning != null)
                      Text(warning!, style: const TextStyle(color: Colors.red)),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: button(
                        l(
                          '保存报名，稍后排位',
                          'Save · arrange later',
                          '儲存報名，稍後排位',
                          'บันทึกและจัดที่นั่งภายหลัง',
                        ),
                        saving
                            ? null
                            : () async {
                                if (name.text.trim().isEmpty ||
                                    !RegExp(r'^[+0-9 ()-]{5,32}$')
                                        .hasMatch(phone.text.trim())) {
                                  update(
                                    () => warning = l(
                                      '请填写称呼和有效联系电话',
                                      'Enter name and phone',
                                      '請填寫稱呼和有效電話',
                                      'กรุณาระบุชื่อและโทรศัพท์',
                                    ),
                                  );
                                  return;
                                }
                                final start = day.add(
                                  Duration(days: hour < 6 ? 1 : 0, hours: hour),
                                );
                                update(() => saving = true);
                                final ok = await load({
                                  'action': 'create',
                                  'reservationRef': ref,
                                  'guestName': name.text.trim(),
                                  'phone': phone.text.trim(),
                                  'partySize': count,
                                  'mode': aa ? 'aa' : 'table',
                                  'startsAt': start.toUtc().toIso8601String(),
                                  'endsAt': start
                                      .add(Duration(hours: duration))
                                      .toUtc()
                                      .toIso8601String(),
                                  'note': note.text.trim(),
                                  'source': 'cashier',
                                });
                                if (!context.mounted) return;
                                if (ok) {
                                  Navigator.pop(dialog);
                                } else {
                                  update(() {
                                    saving = false;
                                    warning = error;
                                  });
                                }
                              },
                        primary: true,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    name.dispose();
    phone.dispose();
    note.dispose();
  }

  Future<void> assign(Map<String, dynamic> row) async {
    final refs = selected.isEmpty ? [row['ref']] : selected.toList();
    final target = await showDialog<String>(
      context: context,
      builder: (dialog) => Dialog(
        child: SizedBox(
          width: 740,
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        l('安排位置', 'Arrange seats', '安排位置', 'จัดที่นั่ง'),
                        style: const TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.pop(dialog),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                Flexible(
                  child: SingleChildScrollView(
                    child: Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        for (final t in data?['tables'] ?? [])
                          SizedBox(
                            width: 144,
                            height: 80,
                            child: OutlinedButton(
                              onPressed: () => Navigator.pop(
                                dialog,
                                t['tableRef'] as String,
                              ),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Text(
                                    '${t['tableName']}',
                                    style: const TextStyle(
                                      fontSize: 24,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  Text(
                                    '${t['capacity']} ${l('人', 'seats', '人', 'ที่นั่ง')}',
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  l(
                    '同一时段的 AA 报名可多选，一起安排',
                    'Select AA requests for the same time to seat together',
                    '同時段 AA 報名可多選，一起安排',
                    'เลือก AA ช่วงเวลาเดียวกันเพื่อจัดร่วมโต๊ะ',
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (target != null &&
        mounted &&
        await load({'action': 'assign', 'refs': refs, 'tableRef': target})) {
      setState(() => selected.clear());
    }
  }

  @override
  Widget build(BuildContext context) {
    final all = rows;
    final list = all
        .where(
          (r) =>
              filter == 'all' ||
              filter == 'aa' && r['mode'] == 'aa' ||
              filter == r['status'],
        )
        .toList();
    final detail = all.where((r) => r['ref'] == focus).firstOrNull;
    return ColoredBox(
      color: paper,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  l('预约', 'Reservations', '預約', 'การจอง'),
                  style: const TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.bold,
                    color: green,
                  ),
                ),
                const SizedBox(width: 24),
                button(
                  '${day.year}/${day.month}/${day.day}',
                  busy ? null : datePicker,
                  icon: Icons.calendar_month,
                ),
                const Spacer(),
                button(
                  l('电话预约', 'Telephone booking', '電話預約', 'จองทางโทรศัพท์'),
                  busy || !canEdit ? null : create,
                  icon: Icons.add,
                  primary: true,
                ),
              ],
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 10,
              children: [
                for (final pair in [
                  ('all', l('全部', 'All', '全部', 'ทั้งหมด')),
                  ('waiting', l('待安排', 'Waiting', '待安排', 'รอจัด')),
                  ('aa', l('AA 拼桌', 'AA sharing', 'AA 拼桌', 'AA')),
                  ('reserved', l('已安排', 'Assigned', '已安排', 'จัดแล้ว')),
                  ('arrived', l('已到店', 'Arrived', '已到店', 'มาถึง')),
                ])
                  ChoiceChip(
                    label: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      child: Text(pair.$2),
                    ),
                    selected: filter == pair.$1,
                    onSelected: (_) => setState(() => filter = pair.$1),
                  ),
              ],
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
                    onPressed: busy ? null : () => load(),
                    child: Text(l('重试', 'Retry', '重試', 'ลองอีกครั้ง')),
                  ),
                ],
              ),
            const SizedBox(height: 16),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    flex: 6,
                    child: data == null
                        ? const Center(child: CircularProgressIndicator())
                        : list.isEmpty
                        ? Center(
                            child: Text(
                              l(
                                '当天暂无预约',
                                'No bookings for this day',
                                '當天暫無預約',
                                'ไม่มีการจองในวันนี้',
                              ),
                            ),
                          )
                        : ListView.separated(
                            itemCount: list.length,
                            separatorBuilder: (_, _) =>
                                const SizedBox(height: 10),
                            itemBuilder: (context, i) {
                              final r = list[i];
                              final aa = r['mode'] == 'aa',
                                  active = r['ref'] == focus;
                              return Material(
                                color: active
                                    ? const Color(0xffe3ece6)
                                    : Colors.white,
                                borderRadius: BorderRadius.circular(14),
                                child: InkWell(
                                  onTap: () => setState(
                                    () => focus = r['ref'] as String,
                                  ),
                                  borderRadius: BorderRadius.circular(14),
                                  child: Padding(
                                    padding: const EdgeInsets.all(16),
                                    child: Row(
                                      children: [
                                        if (aa &&
                                            r['source'] != 'app' &&
                                            [
                                              'waiting',
                                              'notified',
                                              'reserved',
                                            ].contains(r['status']))
                                          Checkbox(
                                            value: selected.contains(r['ref']),
                                            onChanged: busy
                                                ? null
                                                : (v) => setState(() {
                                                    focus = r['ref'] as String;
                                                    v == true
                                                        ? selected.add(
                                                            r['ref'] as String,
                                                          )
                                                        : selected.remove(
                                                            r['ref'],
                                                          );
                                                  }),
                                          ),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                '${r['guestName']}  ·  ${r['partySize']} ${l('人', 'people', '人', 'คน')}',
                                                style: const TextStyle(
                                                  fontSize: 20,
                                                  fontWeight: FontWeight.bold,
                                                ),
                                              ),
                                              const SizedBox(height: 8),
                                              Text(
                                                '${time(r['startsAt'])}   ${aa ? 'AA' : l('整桌', 'Table', '整桌', 'ทั้งโต๊ะ')}   ${r['source'] == 'app' ? 'APP' : l('电话 / 客服', 'Phone / support', '電話 / 客服', 'โทรศัพท์')}',
                                              ),
                                            ],
                                          ),
                                        ),
                                        Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.end,
                                          children: [
                                            Text(
                                              status(r),
                                              style: const TextStyle(
                                                color: green,
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                            const SizedBox(height: 8),
                                            Text('${r['tableName'] ?? '—'}'),
                                          ],
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                  const SizedBox(width: 20),
                  Expanded(
                    flex: 4,
                    child: Container(
                      padding: const EdgeInsets.all(24),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: detail == null
                          ? Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(
                                    Icons.event_seat_outlined,
                                    size: 56,
                                    color: green,
                                  ),
                                  const SizedBox(height: 16),
                                  Text(
                                    l(
                                      '选择预约，查看并安排位置',
                                      'Select a booking to arrange seats',
                                      '選擇預約，查看並安排位置',
                                      'เลือกการจองเพื่อจัดที่นั่ง',
                                    ),
                                  ),
                                ],
                              ),
                            )
                          : Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '${detail['guestName']}',
                                  style: const TextStyle(
                                    fontSize: 26,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const SizedBox(height: 10),
                                Text(
                                  '${status(detail)}  ·  ${detail['partySize']} ${l('人', 'people', '人', 'คน')}  ·  ${detail['tableName'] ?? '—'}',
                                  style: const TextStyle(fontSize: 18),
                                ),
                                const Divider(height: 32),
                                Expanded(
                                  child: SingleChildScrollView(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          '${time(detail['startsAt'])} — ${time(detail['endsAt'])}',
                                          style: const TextStyle(fontSize: 18),
                                        ),
                                        const SizedBox(height: 18),
                                        Text(
                                          detail['source'] == 'app'
                                              ? l(
                                                  '已付款 ${detail['paidCount']} 人 / 容量 ${detail['partySize']} 人',
                                                  'Paid ${detail['paidCount']} / capacity ${detail['partySize']}',
                                                  '已付款 ${detail['paidCount']} 人 / 容量 ${detail['partySize']} 人',
                                                  'ชำระแล้ว ${detail['paidCount']} / ${detail['partySize']}',
                                                )
                                              : l(
                                                  '未付款 · 报名不等于买单',
                                                  'Unpaid · registration only',
                                                  '未付款 · 報名不等於付款',
                                                  'ยังไม่ชำระเงิน',
                                                ),
                                          style: const TextStyle(
                                            fontSize: 20,
                                            color: green,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                        const SizedBox(height: 18),
                                        if (detail['phone'] != null)
                                          SelectableText(
                                            '${detail['phone']}',
                                            style: const TextStyle(
                                              fontSize: 26,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                        if (detail['note'] != null)
                                          Text('${detail['note']}'),
                                        if (detail['notifiedAt'] != null)
                                          Padding(
                                            padding: const EdgeInsets.only(
                                              top: 12,
                                            ),
                                            child: Text(
                                              l(
                                                '已记录电话通知',
                                                'Phone notification recorded',
                                                '已記錄電話通知',
                                                'บันทึกการแจ้งทางโทรศัพท์แล้ว',
                                              ),
                                            ),
                                          ),
                                        for (final m in detail['members'] ?? [])
                                          Padding(
                                            padding: const EdgeInsets.symmetric(
                                              vertical: 8,
                                            ),
                                            child: Row(
                                              children: [
                                                Expanded(
                                                  child: Text(
                                                    '${m['userAccount']}',
                                                  ),
                                                ),
                                                Text(
                                                  m['status'] == 'paid'
                                                      ? l(
                                                          '已付款',
                                                          'Paid',
                                                          '已付款',
                                                          'ชำระแล้ว',
                                                        )
                                                      : l(
                                                          '未完成付款',
                                                          'Payment incomplete',
                                                          '未完成付款',
                                                          'ยังไม่ชำระ',
                                                        ),
                                                ),
                                              ],
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                ),
                                if ([
                                  'waiting',
                                  'notified',
                                  'reserved',
                                ].contains(detail['status'])) ...[
                                  if (selected.isNotEmpty)
                                    Padding(
                                      padding: const EdgeInsets.only(bottom: 8),
                                      child: Text(
                                        l(
                                          '已选 ${selected.length} 组 AA 报名',
                                          '${selected.length} AA requests selected',
                                          '已選 ${selected.length} 組 AA 報名',
                                          'เลือกแล้ว ${selected.length} กลุ่ม',
                                        ),
                                      ),
                                    ),
                                  SizedBox(
                                    width: double.infinity,
                                    child: button(
                                      l(
                                        '安排位置',
                                        'Arrange seats',
                                        '安排位置',
                                        'จัดที่นั่ง',
                                      ),
                                      busy || !canEdit
                                          ? null
                                          : () => assign(detail),
                                      primary: true,
                                    ),
                                  ),
                                  if (detail['source'] != 'app') ...[
                                    const SizedBox(height: 10),
                                    SizedBox(
                                      width: double.infinity,
                                      child: button(
                                        l(
                                          '已电话通知付款加入',
                                          'Called guest to pay and join',
                                          '已電話通知付款加入',
                                          'โทรแจ้งให้ชำระและเข้าร่วมแล้ว',
                                        ),
                                        busy || !canEdit
                                            ? null
                                            : () => load({
                                                'action': 'notified',
                                                'reservationRef': detail['ref'],
                                              }),
                                      ),
                                    ),
                                    const SizedBox(height: 10),
                                    Row(
                                      children: [
                                        Expanded(
                                          child: button(
                                            l(
                                              '取消预约',
                                              'Cancel',
                                              '取消預約',
                                              'ยกเลิก',
                                            ),
                                            busy || !canEdit
                                                ? null
                                                : () async {
                                                    final yes = await showDialog<bool>(
                                                      context: context,
                                                      builder: (c) => AlertDialog(
                                                        title: Text(
                                                          l(
                                                            '取消这条预约？',
                                                            'Cancel this booking?',
                                                            '取消這條預約？',
                                                            'ยกเลิกการจองนี้?',
                                                          ),
                                                        ),
                                                        actions: [
                                                          TextButton(
                                                            onPressed: () =>
                                                                Navigator.pop(
                                                                  c,
                                                                  false,
                                                                ),
                                                            child: Text(
                                                              l(
                                                                '返回',
                                                                'Back',
                                                                '返回',
                                                                'กลับ',
                                                              ),
                                                            ),
                                                          ),
                                                          TextButton(
                                                            onPressed: () =>
                                                                Navigator.pop(
                                                                  c,
                                                                  true,
                                                                ),
                                                            child: Text(
                                                              l(
                                                                '取消预约',
                                                                'Cancel booking',
                                                                '取消預約',
                                                                'ยกเลิกการจอง',
                                                              ),
                                                            ),
                                                          ),
                                                        ],
                                                      ),
                                                    );
                                                    if (yes == true) {
                                                      await load({
                                                        'action': 'cancel',
                                                        'reservationRef':
                                                            detail['ref'],
                                                      });
                                                    }
                                                  },
                                          ),
                                        ),
                                        const SizedBox(width: 10),
                                        Expanded(
                                          child: button(
                                            l(
                                              '已到店',
                                              'Arrived',
                                              '已到店',
                                              'มาถึงแล้ว',
                                            ),
                                            busy ||
                                                    !canEdit ||
                                                    detail['tableRef'] == null
                                                ? null
                                                : () => load({
                                                    'action': 'arrived',
                                                    'reservationRef':
                                                        detail['ref'],
                                                  }),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ],
                              ],
                            ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
