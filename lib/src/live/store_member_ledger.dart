import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../strings.dart';
import 'recharge_touch_dialog.dart' show rechargeText;

String statementTime(Object? value) {
  final date = DateTime.tryParse('$value');
  if (date == null) return '—';
  final local = date.toUtc().add(const Duration(hours: 8));
  String two(int n) => n.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} ${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
}

class StoreMemberLedger extends StatelessWidget {
  const StoreMemberLedger({
    super.key,
    required this.language,
    required this.memberNumber,
    required this.rows,
    this.onMore,
    this.loading = false,
  });
  final UiLanguage language;
  final String memberNumber;
  final List<Map<String, dynamic>> rows;
  final VoidCallback? onMore;
  final bool loading;
  String t(String zh, String en, String tw, String th) =>
      rechargeText(language, zh, en, tw, th);
  String amount(Object? value, {bool hideZero = false}) {
    final cents = BigInt.tryParse('$value');
    if (cents == null) return '—';
    if (hideZero && cents == BigInt.zero) return '—';
    return '${cents ~/ BigInt.from(100)}.${(cents.abs() % BigInt.from(100)).toString().padLeft(2, '0')}';
  }

  String item(Object? value) => switch (value) {
    'recharge_principal' => t(
      '充值本金',
      'Recharge principal',
      '充值本金',
      'เงินต้นเติมเงิน',
    ),
    'recharge_gift' => t('赠送金额', 'Recharge gift', '贈送金額', 'โบนัสเติมเงิน'),
    'consumption' => t('消费金额', 'Consumption', '消費金額', 'ยอดใช้จ่าย'),
    'consumption_refund' => t(
      '消费退款',
      'Purchase refund',
      '消費退款',
      'คืนเงินซื้อสินค้า',
    ),
    'recharge_refund' => t(
      '充值退款',
      'Recharge refund',
      '充值退款',
      'คืนเงินเติมเงิน',
    ),
    'gift_cancelled' => t('赠送取消', 'Gift cancelled', '贈送取消', 'ยกเลิกโบนัส'),
    'gift_expiry' => t('赠送到期', 'Gift expired', '贈送到期', 'โบนัสหมดอายุ'),
    _ => '—',
  };
  String method(Object? value) => switch (value) {
    'wechat' => t('微信', 'WeChat', '微信', 'WeChat'),
    'alipay' => t('支付宝', 'Alipay', '支付寶', 'Alipay'),
    'cash' => t('现金', 'Cash', '現金', 'เงินสด'),
    'store_balance' => t('本店储值', 'Store balance', '本店儲值', 'ยอดร้านค้า'),
    'gift' => t('赠送', 'Gift', '贈送', 'โบนัส'),
    _ => '—',
  };
  @override
  Widget build(BuildContext context) {
    final headers = [
      t('日期时间', 'Date / time', '日期時間', 'วันเวลา'),
      t('会员号', 'Member no.', '會員號', 'เลขสมาชิก'),
      t('项目', 'Item', '項目', 'รายการ'),
      t('收入', 'Income', '收入', 'รับเข้า'),
      t('支出', 'Expense', '支出', 'จ่ายออก'),
      t('支付方式', 'Payment', '支付方式', 'วิธีชำระ'),
      t('流水号', 'Transaction no.', '流水號', 'เลขรายการ'),
      t('可用余额', 'Available', '可用餘額', 'ยอดใช้ได้'),
    ];
    final values = [
      for (final r in rows)
        [
          statementTime(r['occurredAt']),
          memberNumber,
          item(r['item']),
          amount(r['incomeCents'], hideZero: true),
          amount(r['expenseCents'], hideZero: true),
          method(r['paymentMethod']),
          '${r['operationRef']}',
          amount(r['balanceAfterCents']),
        ],
    ];
    TextStyle style(int index, {bool header = false, Color? color}) =>
        DefaultTextStyle.of(context).style.copyWith(
          fontSize: header || index == 0
              ? 13
              : index == 6
              ? 12
              : 14,
          height: 1.35,
          color: color,
          fontFeatures: const [FontFeature.tabularFigures()],
          fontWeight: header || index == 7
              ? FontWeight.w600
              : FontWeight.normal,
        );
    double measure(String text, TextStyle textStyle) {
      final painter = TextPainter(
        text: TextSpan(text: text, style: textStyle),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
        maxLines: 1,
      )..layout();
      final width = painter.width;
      painter.dispose();
      return width.ceilToDouble() + 24;
    }

    final naturalWidths = List.generate(8, (i) {
      var width = measure(headers[i], style(i, header: true));
      for (final row in values) {
        width = math.max(width, measure(row[i], style(i)));
      }
      return width;
    });
    Widget cell(
      String text,
      int index, {
      bool header = false,
      Color? color,
      bool selectable = false,
    }) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
      child: selectable
          ? Tooltip(
              message: text,
              child: SelectableText(text, maxLines: 1, style: style(index)),
            )
          : Text(
              text,
              maxLines: 1,
              softWrap: false,
              textAlign: [3, 4, 7].contains(index)
                  ? TextAlign.right
                  : TextAlign.left,
              style: style(index, header: header, color: color),
            ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          t(
            '充值和消费记录',
            'Recharge and consumption',
            '充值和消費記錄',
            'รายการเติมเงินและใช้จ่าย',
          ),
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 14),
        LayoutBuilder(
          builder: (context, constraints) {
            // Short fields take only their measured width; the reference takes
            // the remaining space. Very narrow screens retain horizontal scroll.
            final widths = [...naturalWidths];
            final fixed = widths
                .asMap()
                .entries
                .where((e) => e.key != 6)
                .fold<double>(0, (sum, e) => sum + e.value);
            widths[6] = math.max(
              naturalWidths[6],
              constraints.maxWidth - fixed,
            );
            final tableWidth = widths.fold<double>(
              0,
              (sum, width) => sum + width,
            );
            return SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SizedBox(
                width: tableWidth,
                child: Table(
                  defaultVerticalAlignment: TableCellVerticalAlignment.middle,
                  columnWidths: {
                    for (final (i, width) in widths.indexed)
                      i: FixedColumnWidth(width),
                  },
                  border: const TableBorder(
                    horizontalInside: BorderSide(color: Color(0xffdce3df)),
                    verticalInside: BorderSide(
                      color: Color(0xffe8eeea),
                      width: 0.5,
                    ),
                  ),
                  children: [
                    TableRow(
                      decoration: BoxDecoration(
                        color: const Color(0xffe8eeea),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      children: [
                        for (var i = 0; i < headers.length; i++)
                          cell(headers[i], i, header: true),
                      ],
                    ),
                    for (final (rowIndex, r) in rows.indexed)
                      TableRow(
                        key: ValueKey('statement-${r['rowRef']}'),
                        decoration: BoxDecoration(
                          color: rowIndex.isEven
                              ? const Color(0xfffafcfb)
                              : Colors.transparent,
                        ),
                        children: [
                          cell(statementTime(r['occurredAt']), 0),
                          cell(memberNumber, 1),
                          cell(item(r['item']), 2),
                          cell(
                            amount(r['incomeCents'], hideZero: true),
                            3,
                            color: const Color(0xff247653),
                          ),
                          cell(
                            amount(r['expenseCents'], hideZero: true),
                            4,
                            color: const Color(0xffbd533f),
                          ),
                          cell(method(r['paymentMethod']), 5),
                          cell('${r['operationRef']}', 6, selectable: true),
                          cell(amount(r['balanceAfterCents']), 7),
                        ],
                      ),
                  ],
                ),
              ),
            );
          },
        ),
        if (rows.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 28),
            child: Text(
              t(
                '暂无充值和消费记录',
                'No recharge or consumption records',
                '暫無充值和消費記錄',
                'ยังไม่มีรายการเติมเงินหรือใช้จ่าย',
              ),
              textAlign: TextAlign.center,
            ),
          ),
        if (onMore != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: TextButton(
              onPressed: loading ? null : onMore,
              child: Text(t('查看更多', 'Load more', '查看更多', 'ดูเพิ่มเติม')),
            ),
          ),
      ],
    );
  }
}
