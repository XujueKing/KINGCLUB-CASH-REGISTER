import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import '../auth/staff_auth_controller.dart';
import '../strings.dart';
import 'voucher_report_panel.dart';

/// A complete report snapshot; changing sections never fetches another endpoint.
class BusinessReportPanel extends StatefulWidget {
  const BusinessReportPanel({
    super.key,
    required this.auth,
    required this.language,
  });
  final StaffAuthController auth;
  final UiLanguage language;
  @override
  State<BusinessReportPanel> createState() => _BusinessReportPanelState();
}

class _BusinessReportPanelState extends State<BusinessReportPanel> {
  static const ink = Color(0xFF183E35),
      muted = Color(0xFF748078),
      gold = Color(0xFFC7AA70),
      paper = Color(0xFFF5F4EF);
  late DateTime from, to;
  Map<String, dynamic>? data;
  int section = 0, generation = 0, slot = -1;
  bool busy = false, failed = false, byAmount = false;
  late String loadedScope;
  String l(String zh, String en, String tw, String th) =>
      [zh, en, tw, th][widget.language.index];
  String get scope =>
      '${widget.auth.session?.base}|${widget.auth.session?.storeRef}|${widget.auth.session?.employeeRef}|${widget.auth.session?.permissions.join(',')}';
  DateTime get today {
    final d = DateTime.now().toUtc().add(const Duration(hours: 2));
    return DateTime(d.year, d.month, d.day);
  }

  String day(DateTime d) => d.toIso8601String().substring(0, 10);
  String money(dynamic n) => n == null
      ? '—'
      : '¥ ${(n as num) / 100 < 0 ? '-' : ''}${(n.abs() / 100).toStringAsFixed(2)}';
  String numText(dynamic n) => n == null ? '—' : '$n';
  List<Map<String, dynamic>> rows(String key) => (data?[key] as List? ?? [])
      .map((r) => Map<String, dynamic>.from(r as Map))
      .toList();
  Map<String, dynamic> summary(int period) =>
      rows('summaries')
          .firstWhere((s) => s['period'] == period, orElse: () => {});
  Map<String, dynamic> get s => summary(0);
  String name(dynamic names) {
    if (names is! Map) return '—';
    return '${names[['zh-CN', 'en', 'zh-TW', 'th'][widget.language.index]] ?? names['zh-CN'] ?? names.values.firstOrNull ?? '—'}';
  }

  String channel(String c) => switch (c) {
    'wechat' => l('微信', 'WeChat', '微信', 'WeChat'),
    'alipay' => l('支付宝', 'Alipay', '支付寶', 'Alipay'),
    'cash' => l('现金', 'Cash', '現金', 'เงินสด'),
    'bank_code' => l('银行码', 'Bank QR', '銀行碼', 'QR ธนาคาร'),
    'pos' => l('POS 刷卡', 'POS card', 'POS 刷卡', 'บัตร POS'),
    'store_balance' => l('本店储值本金', 'Store principal', '本店儲值本金', 'เงินเติมร้าน'),
    'platform_cash' => l(
      '平台现金余额',
      'Platform balance',
      '平台現金餘額',
      'ยอดแพลตฟอร์ม',
    ),
    'platform_subsidy' => l('平台补贴', 'Platform subsidy', '平台補貼', 'เงินอุดหนุน'),
    'member_balance' => l('会员余额', 'Member balance', '會員餘額', 'ยอดสมาชิก'),
    'douyin' => l('抖音', 'Douyin', '抖音', 'Douyin'),
    'meituan' => l('美团', 'Meituan', '美團', 'Meituan'),
    _ => l('其他 / 旧记录', 'Other / legacy', '其他 / 舊記錄', 'อื่น ๆ / เก่า'),
  };
  @override
  void initState() {
    super.initState();
    from = to = today;
    loadedScope = scope;
    widget.auth.addListener(authChanged);
    unawaited(load());
  }

  void authChanged() {
    if (scope == loadedScope) return;
    loadedScope = scope;
    generation++;
    data = null;
    if (mounted) unawaited(load());
  }

  @override
  void dispose() {
    generation++;
    widget.auth.removeListener(authChanged);
    super.dispose();
  }

  Future<void> load() async {
    final request = ++generation, identity = scope;
    setState(() {
      busy = true;
      failed = false;
    });
    try {
      final report = await widget.auth.readBusinessReport(
        from: day(from),
        to: day(to),
      );
      if (!mounted || request != generation || scope != identity) return;
      setState(() {
        data = report;
        slot = -1;
      });
    } catch (_) {
      if (mounted && request == generation) setState(() => failed = true);
    } finally {
      if (mounted && request == generation) setState(() => busy = false);
    }
  }

  void range(DateTime start, DateTime end) {
    setState(() {
      from = start;
      to = end;
    });
    unawaited(load());
  }

  Future<void> calendar() async {
    final selected = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: today,
      initialDateRange: DateTimeRange(start: from, end: to),
      initialEntryMode: DatePickerEntryMode.calendarOnly,
      helpText: l(
        '选择营业日期 · 最多 93 天',
        'Business dates · up to 93 days',
        '選擇營業日期 · 最多 93 天',
        'วันทำการ · สูงสุด 93 วัน',
      ),
      builder: (context, child) => Localizations.override(
        context: context,
        locale: [
          const Locale('zh', 'CN'),
          const Locale('en'),
          const Locale('zh', 'TW'),
          const Locale('th'),
        ][widget.language.index],
        delegates: GlobalMaterialLocalizations.delegates,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720, maxHeight: 620),
            child: child!,
          ),
        ),
      ),
    );
    if (!mounted || selected == null) return;
    if (selected.end.difference(selected.start).inDays > 92) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            l(
              '每次最多查询 93 天',
              'Select up to 93 days',
              '每次最多查詢 93 天',
              'เลือกได้สูงสุด 93 วัน',
            ),
          ),
        ),
      );
      return;
    }
    range(selected.start, selected.end);
  }

  Widget text(
    String value, {
    double size = 13,
    Color color = ink,
    FontWeight weight = FontWeight.normal,
    int lines = 1,
  }) => Text(
    value,
    maxLines: lines,
    overflow: TextOverflow.ellipsis,
    style: TextStyle(fontSize: size, color: color, fontWeight: weight),
  );
  Widget card(Widget child, {EdgeInsets padding = const EdgeInsets.all(18)}) =>
      Container(
        padding: padding,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFFE4E7E1)),
        ),
        child: child,
      );
  Widget heading(String title, {Widget? trailing}) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: Row(
      children: [
        Expanded(child: text(title, size: 17, weight: FontWeight.w700)),
        ?trailing,
      ],
    ),
  );
  Widget note(String value) => Padding(
    padding: const EdgeInsets.only(top: 10),
    child: text(value, size: 12, color: muted, lines: 4),
  );
  Widget empty() => Padding(
    padding: const EdgeInsets.symmetric(vertical: 30),
    child: Center(
      child: text(
        l(
          '这段时间暂无记录',
          'No records in this period',
          '這段時間暫無記錄',
          'ไม่มีรายการในช่วงนี้',
        ),
        color: muted,
      ),
    ),
  );
  Widget choice(String label, VoidCallback tap, bool selected) => Padding(
    padding: const EdgeInsets.only(right: 6),
    child: FilledButton.tonal(
      onPressed: tap,
      style: FilledButton.styleFrom(
        minimumSize: const Size(76, 46),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        backgroundColor: selected ? ink : Colors.white,
        foregroundColor: selected ? Colors.white : ink,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      child: Text(label),
    ),
  );
  String compare(String key) {
    final current = s[key], prior = summary(1)[key];
    if (current is! num || prior is! num || prior == 0) {
      return l('上期 —', 'Previous —', '上期 —', 'ช่วงก่อน —');
    }
    final pct = (current - prior) / prior.abs() * 100;
    return '${l('较上期', 'vs prior', '較上期', 'เทียบก่อน')} ${pct >= 0 ? '+' : ''}${pct.toStringAsFixed(1)}%';
  }

  Widget metric(
    String title,
    String value,
    IconData icon,
    String hint, {
    Color color = ink,
  }) => card(
    Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 19, color: color),
            const SizedBox(width: 8),
            Expanded(child: text(title, color: muted)),
          ],
        ),
        const SizedBox(height: 10),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: text(value, size: 28, weight: FontWeight.w700, color: color),
        ),
        const SizedBox(height: 6),
        text(hint, size: 11, color: muted),
      ],
    ),
    padding: const EdgeInsets.all(14),
  );
  Widget metrics() => LayoutBuilder(
    builder: (context, c) => GridView.count(
      crossAxisCount: c.maxWidth > 950 ? 6 : 3,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 10,
      crossAxisSpacing: 10,
      childAspectRatio: c.maxWidth / (c.maxWidth > 950 ? 6 : 3) / 130,
      children: [
        metric(
          l('商品净营业额', 'Net goods sales', '商品淨營業額', 'ยอดขายสินค้าสุทธิ'),
          money(s['netSalesCents']),
          Icons.payments_outlined,
          compare('netSalesCents'),
        ),
        metric(
          l('收款笔数', 'Collections', '收款筆數', 'จำนวนชำระ'),
          numText(s['collections']),
          Icons.receipt_long_outlined,
          '${l('客单价', 'Avg. bill', '客單價', 'เฉลี่ย')} ${money(s['averageCollectionCents'])}',
        ),
        metric(
          l('登记客流', 'Registered guests', '登記客流', 'ลูกค้าที่ลงทะเบียน'),
          numText(s['guests']),
          Icons.people_outline,
          compare('guests'),
        ),
        metric(
          l('开台次数', 'Table openings', '開台次數', 'จำนวนเปิดโต๊ะ'),
          numText(s['openings']),
          Icons.table_restaurant_outlined,
          compare('openings'),
        ),
        metric(
          l('商品成本', 'Goods cost', '商品成本', 'ต้นทุนสินค้า'),
          s['grossProfitCents'] == null
              ? l('待补成本', 'Incomplete', '待補成本', 'ข้อมูลไม่ครบ')
              : money(s['knownCostCents']),
          Icons.inventory_2_outlined,
          '${l('已知净成本', 'Known net cost', '已知淨成本', 'ต้นทุนที่ทราบ')} ${money(s['knownCostCents'])}',
        ),
        metric(
          l('商品毛利', 'Gross profit', '商品毛利', 'กำไรขั้นต้น'),
          money(s['grossProfitCents']),
          Icons.insights_outlined,
          s['grossProfitCents'] == null
              ? l('成本未齐，暂不计算', 'Awaiting full cost', '成本未齊，暫不計算', 'รอต้นทุนครบ')
              : l(
                  '未扣房租、人工等',
                  'Before rent and wages',
                  '未扣房租、人工等',
                  'ก่อนหักค่าเช่า ค่าแรง',
                ),
          color: const Color(0xFF986C27),
        ),
      ],
    ),
  );
  Widget trend() {
    final points = rows('trend')
      ..sort((a, b) => (a['index'] as num).compareTo(b['index'] as num));
    final values = points.map((p) => (p['cents'] as num).toDouble()).toList();
    final maximum = values.fold<double>(1, math.max),
        minimum = values.fold<double>(0, math.min),
        span = maximum - minimum;
    final selected = slot >= 0 && slot < points.length ? points[slot] : null;
    return card(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          heading(
            l('营业走势', 'Sales trend', '營業走勢', 'แนวโน้มยอดขาย'),
            trailing: text(
              selected == null
                  ? l(
                      '点击柱形看金额',
                      'Tap a bar for details',
                      '點擊柱形看金額',
                      'แตะแท่งดูยอด',
                    )
                  : '${selected['label']}   ${money(selected['cents'])}',
              color: muted,
            ),
          ),
          SizedBox(
            height: 160,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < points.length; i++)
                  Expanded(
                    child: Semantics(
                      label:
                          '${points[i]['label']} ${money(points[i]['cents'])}',
                      button: true,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => setState(() => slot = i),
                        child: Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: points.length > 35 ? 1 : 3,
                          ),
                          child: LayoutBuilder(
                            builder: (context, c) {
                              final value = values[i],
                                  zero = maximum / span * c.maxHeight,
                                  height = value.abs() / span * c.maxHeight;
                              return Stack(
                                children: [
                                  Positioned(
                                    top: zero.clamp(0, c.maxHeight - 1),
                                    left: 0,
                                    right: 0,
                                    child: Container(
                                      height: 1,
                                      color: const Color(0xFFDCE2DA),
                                    ),
                                  ),
                                  Positioned(
                                    top: value >= 0 ? zero - height : zero,
                                    left: 0,
                                    right: 0,
                                    height: math.max(height, 1),
                                    child: DecoratedBox(
                                      decoration: BoxDecoration(
                                        color: slot == i
                                            ? gold
                                            : value < 0
                                            ? const Color(0xFFC96B52)
                                            : ink.withValues(alpha: .78),
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                    ),
                                  ),
                                ],
                              );
                            },
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              if (points.isNotEmpty)
                text('${points.first['label']}', size: 11, color: muted),
              text(
                l(
                  '按付款 / 退款发生时间',
                  'By payment / refund time',
                  '按付款 / 退款發生時間',
                  'ตามเวลาชำระ / คืนเงิน',
                ),
                size: 11,
                color: muted,
              ),
              if (points.isNotEmpty)
                text('${points.last['label']}', size: 11, color: muted),
            ],
          ),
        ],
      ),
    );
  }

  Widget bars(
    String title,
    List<Map<String, dynamic>> items,
    String Function(Map<String, dynamic>) label, {
    String amountKey = 'cents',
  }) {
    final sorted = [...items]
      ..sort((a, b) => (b[amountKey] as num).compareTo(a[amountKey] as num));
    final max = sorted.fold<double>(
      1,
      (v, r) => math.max(v, (r[amountKey] as num).abs().toDouble()),
    );
    return card(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          heading(title),
          if (sorted.isEmpty) empty(),
          for (final r in sorted)
            Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: Column(
                children: [
                  Row(
                    children: [
                      Expanded(child: text(label(r))),
                      text(money(r[amountKey]), weight: FontWeight.w600),
                    ],
                  ),
                  const SizedBox(height: 7),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: (r[amountKey] as num).abs() / max,
                      minHeight: 7,
                      color: gold,
                      backgroundColor: paper,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget overview() => Column(
    children: [
      metrics(),
      if (data?['merchantSettlement'] is Map) ...[
        const SizedBox(height: 14),
        card(
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              heading(
                l(
                  '收款去向与平台结算',
                  'Collection and platform settlement',
                  '收款去向與平台結算',
                  'รับเงินและชำระแพลตฟอร์ม',
                ),
              ),
              Wrap(
                spacing: 28,
                runSpacing: 12,
                children: [
                  text(
                    '${l('门店直收', 'Store direct', '門店直收', 'ร้านรับตรง')}  ${money(data!['merchantSettlement']['directCollectedCents'])}',
                  ),
                  text(
                    '${l('平台应付', 'Platform payable', '平台應付', 'แพลตฟอร์มค้างจ่าย')}  ${money(data!['merchantSettlement']['originalDueCents'])}',
                  ),
                  text(
                    '${l('退款冲减', 'Refund reduction', '退款沖減', 'หักคืนเงิน')}  ${money(data!['merchantSettlement']['refundReductionCents'])}',
                  ),
                  text(
                    '${l('待结算', 'Pending settlement', '待結算', 'รอชำระ')}  ${money(data!['merchantSettlement']['pendingCents'])}',
                  ),
                ],
              ),
              if ((data!['merchantSettlement']['reviewOrders'] as num? ?? 0) >
                  0)
                note(
                  '${l('历史收款待核对', 'Historical collections to review', '歷史收款待核對', 'รายการเก่ารอตรวจสอบ')}：${data!['merchantSettlement']['reviewOrders']}',
                ),
            ],
          ),
        ),
      ],
      const SizedBox(height: 14),
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(flex: 3, child: trend()),
          const SizedBox(width: 14),
          Expanded(
            flex: 2,
            child: bars(
              l(
                '收入构成 · 退款前',
                'Income before refunds',
                '收入構成 · 退款前',
                'รายรับก่อนคืนเงิน',
              ),
              rows('channels'),
              (r) => channel('${r['channel']}'),
            ),
          ),
        ],
      ),
      const SizedBox(height: 14),
      card(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            heading(l('经营提示', 'At a glance', '經營提示', 'สรุปการดำเนินงาน')),
            Wrap(
              spacing: 32,
              runSpacing: 12,
              children: [
                text(
                  '${l('待付款', 'Unpaid', '待付款', 'ยังไม่ชำระ')}  ${data?['pendingOrders'] ?? 0}  ·  ${money(data?['pendingCents'])}',
                ),
                text(
                  '${l('退款', 'Refunds', '退款', 'คืนเงิน')}  ${s['refunds'] ?? 0}  ·  ${money(s['refundCents'])}',
                ),
                text(
                  '${l('免单', 'Waived bills', '免單', 'ยกเว้นบิล')}  ${data?['waivedOrders'] ?? 0}',
                ),
              ],
            ),
            note(
              l(
                '当前均为系统实际记录；未付款不计营业额，测试交易也会按原记录统计。',
                'Actual system records, including test transactions. Unpaid orders are excluded from sales.',
                '當前均為系統實際記錄；未付款不計營業額，測試交易也會按原記錄統計。',
                'สรุปจากรายการจริงรวมรายการทดสอบ ยอดค้างไม่รวมยอดขาย',
              ),
            ),
          ],
        ),
      ),
    ],
  );
  Widget table(
    List<String> headers,
    List<List<String>> cells, {
    List<int>? flex,
  }) => Column(
    children: [
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        decoration: BoxDecoration(
          color: paper,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            for (var i = 0; i < headers.length; i++)
              Expanded(
                flex: flex?[i] ?? 1,
                child: text(headers[i], color: muted, size: 12),
              ),
          ],
        ),
      ),
      if (cells.isEmpty) empty(),
      for (final row in cells)
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: Color(0xFFEEF0EB))),
          ),
          child: Row(
            children: [
              for (var i = 0; i < row.length; i++)
                Expanded(flex: flex?[i] ?? 1, child: text(row[i], lines: 2)),
            ],
          ),
        ),
    ],
  );
  Widget income() => Column(
    children: [
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: bars(
              l(
                '商品收入 · 退款前',
                'Goods income before refunds',
                '商品收入 · 退款前',
                'รายรับสินค้าก่อนคืนเงิน',
              ),
              rows('channels'),
              (r) => channel('${r['channel']}'),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: card(
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  heading(
                    l(
                      '收款与优惠',
                      'Payments & benefits',
                      '收款與優惠',
                      'การชำระและส่วนลด',
                    ),
                  ),
                  detail(
                    l('订单结算总额', 'Settled amount', '訂單結算總額', 'ยอดชำระรวม'),
                    money(s['settledCents']),
                  ),
                  detail(
                    l('储值赠送抵扣', 'Gift balance used', '儲值贈送抵扣', 'ใช้ยอดแถม'),
                    money(s['giftCents']),
                  ),
                  detail(
                    l('原单优惠', 'Order discounts', '原單優惠', 'ส่วนลดบิล'),
                    money(s['couponCents']),
                  ),
                  detail(
                    l('退款本金', 'Principal refunded', '退款本金', 'คืนเงินต้น'),
                    money(s['refundPrincipalCents']),
                  ),
                  detail(
                    l('商品净营业额', 'Net goods sales', '商品淨營業額', 'ยอดขายสุทธิ'),
                    money(s['netSalesCents']),
                  ),
                  note(
                    l(
                      '净营业额 = 结算总额 − 储值赠送抵扣 − 退款本金。充值、团购到账另列。',
                      'Net sales = settled − gift balance − principal refunds. Top-ups and voucher settlements are separate.',
                      '淨營業額 = 結算總額 − 儲值贈送抵扣 − 退款本金。充值、團購到帳另列。',
                      'ยอดสุทธิ = ชำระ − ยอดแถม − คืนเงินต้น แยกเงินเติมและคูปอง',
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
      const SizedBox(height: 14),
      card(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            heading(
              l(
                '充值到账 · 不重复计入营业额',
                'Top-ups · excluded from goods sales',
                '充值到帳 · 不重複計入營業額',
                'เงินเติม · ไม่รวมยอดขายซ้ำ',
              ),
            ),
            table(
              [
                l('方式', 'Method', '方式', 'วิธี'),
                l('笔数', 'Count', '筆數', 'จำนวน'),
                l('到账本金', 'Principal', '到帳本金', 'เงินต้น'),
                l('赠送金额', 'Gift credit', '贈送金額', 'ยอดแถม'),
              ],
              rows('recharge')
                  .map(
                    (r) => [
                      channel('${r['channel']}'),
                      '${r['transactions']}',
                      money(r['principalCents']),
                      money(r['giftCents']),
                    ],
                  )
                  .toList(),
            ),
          ],
        ),
      ),
      const SizedBox(height: 14),
      card(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            heading(
              l(
                '团购核销与结算',
                'Group-buy vouchers & settlements',
                '團購核銷與結算',
                'คูปองและการชำระ',
              ),
              trailing: OutlinedButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (context) => Dialog(
                    insetPadding: const EdgeInsets.all(24),
                    child: VoucherReportPanel(
                      auth: widget.auth,
                      language: widget.language,
                      onBack: () => Navigator.pop(context),
                    ),
                  ),
                ),
                child: Text(
                  l('核销明细', 'Voucher details', '核銷明細', 'รายละเอียดคูปอง'),
                ),
              ),
            ),
            table(
              [
                l('渠道', 'Channel', '渠道', 'ช่องทาง'),
                l('核销 / 撤销', 'Used / reversed', '核銷 / 撤銷', 'ใช้ / ยกเลิก'),
                l('已定应收', 'Assessed', '已定應收', 'ยอดประเมิน'),
                l('实际到账', 'Received', '實際到帳', 'รับจริง'),
                l('累计待结', 'Outstanding', '累計待結', 'คงค้าง'),
                l('未定价券', 'Unvalued', '未定價券', 'ยังไม่กำหนดราคา'),
              ],
              rows('vouchers')
                  .map(
                    (r) => [
                      channel('${r['provider']}'),
                      '${r['verified']} / ${r['reversed']}',
                      money(r['assessedCents']),
                      money(r['receivedCents']),
                      money(r['outstandingCents']),
                      '${r['unvalued']}',
                    ],
                  )
                  .toList(),
            ),
            note(
              l(
                '团购按平台结算日期统计；未定价不视为零收入，待结为截至所选末日的累计余额。',
                'Voucher contract dates apply. Unvalued vouchers are not zero revenue. Outstanding is cumulative through the end date.',
                '團購按平台結算日期統計；未定價不視為零收入，待結為截至所選末日的累計餘額。',
                'คูปองใช้วันที่ชำระของแพลตฟอร์ม ยอดค้างสะสมถึงวันสิ้นสุด รายการไม่ตีราคาไม่ใช่รายได้ศูนย์',
              ),
            ),
          ],
        ),
      ),
    ],
  );
  Widget detail(String label, String value) => Padding(
    padding: const EdgeInsets.only(bottom: 15),
    child: Row(
      children: [
        Expanded(child: text(label, color: muted)),
        text(value, weight: FontWeight.w600),
      ],
    ),
  );
  Widget products() {
    final allProducts = rows('products')
      ..sort(
        (a, b) => (b[byAmount ? 'cents' : 'quantity'] as num).compareTo(
          a[byAmount ? 'cents' : 'quantity'] as num,
        ),
      );
    final products = allProducts.take(30).toList();
    return Column(
      children: [
        card(
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              heading(
                l(
                  '热销排行 · 前 30 名',
                  'Best sellers · top 30',
                  '熱銷排行 · 前 30 名',
                  'ขายดี · 30 อันดับ',
                ),
                trailing: Row(
                  children: [
                    choice(
                      l('按销量', 'By units', '按銷量', 'ตามจำนวน'),
                      () => setState(() => byAmount = false),
                      !byAmount,
                    ),
                    choice(
                      l('按金额', 'By amount', '按金額', 'ตามยอด'),
                      () => setState(() => byAmount = true),
                      byAmount,
                    ),
                  ],
                ),
              ),
              table(
                [
                  l('排名', 'Rank', '排名', 'อันดับ'),
                  l('商品 / 规格', 'Product / size', '商品 / 規格', 'สินค้า / ขนาด'),
                  l('数量', 'Units', '數量', 'จำนวน'),
                  l('订单数', 'Orders', '訂單數', 'คำสั่งซื้อ'),
                  l('商品金额', 'Line amount', '商品金額', 'ยอดสินค้า'),
                ],
                [
                  for (var i = 0; i < products.length; i++)
                    [
                      '${i + 1}',
                      '${name(products[i]['names'])}\n${name(products[i]['specifications'])}',
                      '${products[i]['quantity']}',
                      '${products[i]['orders']}',
                      money(products[i]['cents']),
                    ],
                ],
                flex: [1, 5, 1, 1, 2],
              ),
              note(
                l(
                  '按已付款订单商品原始销量汇总，含后续退款商品；金额为成交单价 × 数量，整单优惠与退款在收入页单列。',
                  'Paid order lines before later returns; amount = unit price × quantity. Bill discounts and refunds are shown separately.',
                  '按已付款訂單商品原始銷量彙總，含後續退款商品；金額為成交單價 × 數量，整單優惠與退款在收入頁單列。',
                  'สรุปรายการที่ชำระก่อนการคืน ยอดคือราคาต่อหน่วย × จำนวน ส่วนลดทั้งบิลและคืนเงินแสดงแยก',
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        bars(
          l('分类销售金额', 'Category sales', '分類銷售金額', 'ยอดขายตามหมวด'),
          rows('categories'),
          (r) => name(r['names']),
        ),
      ],
    );
  }

  Widget traffic() => Column(
    children: [
      Row(
        children: [
          Expanded(
            child: metric(
              l('登记客流', 'Registered guests', '登記客流', 'ลูกค้าที่ลงทะเบียน'),
              numText(s['guests']),
              Icons.people_outline,
              compare('guests'),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: metric(
              l('开台次数', 'Table openings', '開台次數', 'เปิดโต๊ะ'),
              numText(s['openings']),
              Icons.table_restaurant_outlined,
              compare('openings'),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: metric(
              l(
                '吧台匿名场次',
                'Anonymous bar visits',
                '吧台匿名場次',
                'รอบบาร์ไม่ระบุชื่อ',
              ),
              numText(s['anonymousBarSessions']),
              Icons.event_seat_outlined,
              l(
                '单列，不推算人数',
                'Not estimated as people',
                '單列，不推算人數',
                'ไม่ประมาณจำนวนคน',
              ),
            ),
          ),
        ],
      ),
      const SizedBox(height: 14),
      card(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            heading(l('桌台营业额', 'Sales by table', '桌台營業額', 'ยอดขายรายโต๊ะ')),
            table(
              [
                l('桌台', 'Table', '桌台', 'โต๊ะ'),
                l('收款笔数', 'Collections', '收款筆數', 'จำนวนชำระ'),
                l('退款前收入', 'Before refunds', '退款前收入', 'ก่อนคืนเงิน'),
              ],
              (rows('tables')..sort(
                    (a, b) => (b['cents'] as num).compareTo(a['cents'] as num),
                  ))
                  .map(
                    (r) => [
                      '${r['name']}',
                      '${r['collections']}',
                      money(r['cents']),
                    ],
                  )
                  .toList(),
              flex: [3, 2, 2],
            ),
            note(
              l(
                '普通桌按开台人数，吧台按关联会员记录；同一人重复到店会重复计次。开台不含吧台，吧台座位合并统计收入。',
                'Table party size plus linked bar members; repeat visits count again. Openings exclude bar seats; bar revenue is consolidated.',
                '普通桌按開台人數，吧台按關聯會員記錄；同一人重複到店會重複計次。開台不含吧台，吧台座位合併統計收入。',
                'ใช้จำนวนคนเปิดโต๊ะและสมาชิกบาร์ การมาซ้ำอาจนับซ้ำ แยกบาร์จากการเปิดโต๊ะและรวมรายรับบาร์',
              ),
            ),
          ],
        ),
      ),
    ],
  );
  Widget costs() => card(
    Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        heading(
          l(
            '成本与商品毛利',
            'Cost & gross profit',
            '成本與商品毛利',
            'ต้นทุนและกำไรขั้นต้น',
          ),
        ),
        Row(
          children: [
            Expanded(
              child: metric(
                l('已知净成本', 'Known net cost', '已知淨成本', 'ต้นทุนสุทธิที่ทราบ'),
                money(s['knownCostCents']),
                Icons.inventory_2_outlined,
                l(
                  '原出库成本 − 实物退库成本',
                  'Original issues − stock returns',
                  '原出庫成本 − 實物退庫成本',
                  'ต้นทุนจ่ายออก − คืนคลัง',
                ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: metric(
                l('商品毛利', 'Gross profit', '商品毛利', 'กำไรขั้นต้น'),
                money(s['grossProfitCents']),
                Icons.insights_outlined,
                l(
                  '商品净营业额 − 商品净成本',
                  'Net goods sales − net cost',
                  '商品淨營業額 − 商品淨成本',
                  'ยอดขายสุทธิ − ต้นทุนสุทธิ',
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),
        detail(
          l(
            '缺少成本的出入库批次',
            'Movements missing cost',
            '缺少成本的出入庫批次',
            'รายการคลังที่ขาดต้นทุน',
          ),
          numText(s['unknownCostBatches']),
        ),
        detail(
          l(
            '尚未有出库记录的数量',
            'Units without stock issues',
            '尚未有出庫記錄的數量',
            'จำนวนที่ยังไม่มีรายการจ่ายออก',
          ),
          numText(s['unissuedUnits']),
        ),
        detail(
          l('免单订单数', 'Waived orders', '免單訂單數', 'บิลยกเว้น'),
          numText(data?['waivedOrders']),
        ),
        note(
          l(
            '采用原始库存批次成本，免单出库也计成本。采购成本或出库记录不完整时不计算毛利，避免把未知成本当成零。',
            'Uses original batch costs, including waived orders. Incomplete costs or stock issues leave gross profit unavailable.',
            '採用原始庫存批次成本，免單出庫也計成本。採購成本或出庫記錄不完整時不計算毛利，避免把未知成本當成零。',
            'ใช้ต้นทุนล็อตเดิมรวมรายการยกเว้น หากข้อมูลต้นทุนหรือจ่ายออกไม่ครบ จะไม่คำนวณกำไร',
          ),
        ),
        note(
          l(
            '这里是商品毛利，不是净利润；房租、人工、水电、支付手续费及独立团购履约尚未纳入该毛利。',
            'This is goods gross profit, not net profit: excludes rent, wages, utilities, payment fees and separate voucher fulfillment.',
            '這裡是商品毛利，不是淨利潤；房租、人工、水電、支付手續費及獨立團購履約尚未納入該毛利。',
            'เป็นกำไรขั้นต้นสินค้า ไม่ใช่กำไรสุทธิ ไม่รวมค่าเช่า ค่าแรง สาธารณูปโภค ค่าธรรมเนียมและการใช้คูปองแยก',
          ),
        ),
      ],
    ),
  );
  @override
  Widget build(BuildContext context) {
    final now = today,
        week = now.subtract(Duration(days: now.weekday - 1)),
        month = DateTime(now.year, now.month);
    final tabs = [
      l('总览', 'Overview', '總覽', 'ภาพรวม'),
      l('收入', 'Income', '收入', 'รายรับ'),
      l('商品', 'Products', '商品', 'สินค้า'),
      l('客流', 'Guests', '客流', 'ลูกค้า'),
      l('成本', 'Costs', '成本', 'ต้นทุน'),
    ];
    return ColoredBox(
      color: paper,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                text(
                  l('报表', 'Reports', '報表', 'รายงาน'),
                  size: 24,
                  weight: FontWeight.w700,
                ),
                const SizedBox(width: 20),
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        choice(
                          l('今日', 'Today', '今日', 'วันนี้'),
                          () => range(now, now),
                          from == now && to == now,
                        ),
                        choice(
                          l('昨日', 'Yesterday', '昨日', 'เมื่อวาน'),
                          () => range(
                            now.subtract(const Duration(days: 1)),
                            now.subtract(const Duration(days: 1)),
                          ),
                          from == now.subtract(const Duration(days: 1)) &&
                              from == to,
                        ),
                        choice(
                          l('本周', 'This week', '本週', 'สัปดาห์นี้'),
                          () => range(week, now),
                          from == week && to == now && from != to,
                        ),
                        choice(
                          l('本月', 'This month', '本月', 'เดือนนี้'),
                          () => range(month, now),
                          from == month && to == now && from != to,
                        ),
                        choice(
                          l('自选日期', 'Choose dates', '自選日期', 'เลือกวันที่'),
                          calendar,
                          false,
                        ),
                      ],
                    ),
                  ),
                ),
                if (busy)
                  const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                IconButton(
                  tooltip: l('更新报表', 'Update report', '更新報表', 'อัปเดตรายงาน'),
                  onPressed: busy ? null : load,
                  icon: const Icon(Icons.refresh, size: 21),
                ),
              ],
            ),
            const SizedBox(height: 9),
            text(
              '${day(from)} 06:00 → ${day(to.add(const Duration(days: 1)))} 06:00  ·  ${l('营业日 · 北京时间', 'Business day · China time', '營業日 · 北京時間', 'วันทำการ · เวลาจีน')}',
              size: 12,
              color: muted,
            ),
            if (data != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: text(
                  '${l('对比上期', 'Comparison', '對比上期', 'เทียบช่วงก่อน')}: ${data!['previousFrom']} — ${data!['previousTo']}${busy ? ' · ${l('正在更新，暂显上次结果', 'Updating; previous results shown', '正在更新，暫顯上次結果', 'กำลังอัปเดต แสดงข้อมูลก่อน')}' : ''}',
                  size: 11,
                  color: muted,
                ),
              ),
            if (data != null &&
                (data!['from'] != day(from) || data!['to'] != day(to)))
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: text(
                  '${l('当前显示上次结果', 'Showing previous results', '目前顯示上次結果', 'แสดงผลก่อนหน้า')}: ${data!['from']} — ${data!['to']}',
                  color: const Color(0xFF986C27),
                  size: 12,
                ),
              ),
            const SizedBox(height: 12),
            Row(
              children: [
                for (var i = 0; i < tabs.length; i++)
                  choice(
                    tabs[i],
                    () => setState(() => section = i),
                    section == i,
                  ),
              ],
            ),
            const SizedBox(height: 12),
            if (failed)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: text(
                        l(
                          '报表未能更新，请重试。',
                          'Could not update the report. Retry.',
                          '報表未能更新，請重試。',
                          'อัปเดตไม่สำเร็จ โปรดลองอีกครั้ง',
                        ),
                        color: Colors.red.shade700,
                      ),
                    ),
                    TextButton(
                      onPressed: load,
                      child: Text(l('重试', 'Retry', '重試', 'ลองใหม่')),
                    ),
                  ],
                ),
              ),
            Expanded(
              child: data == null
                  ? Center(
                      child: text(
                        busy
                            ? l(
                                '正在读取报表',
                                'Loading report',
                                '正在讀取報表',
                                'กำลังโหลดรายงาน',
                              )
                            : l('暂无报表', 'No report', '暫無報表', 'ไม่มีรายงาน'),
                        color: muted,
                      ),
                    )
                  : SingleChildScrollView(
                      key: ValueKey(section),
                      padding: const EdgeInsets.only(bottom: 12),
                      child: switch (section) {
                        0 => overview(),
                        1 => income(),
                        2 => products(),
                        3 => traffic(),
                        _ => costs(),
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
