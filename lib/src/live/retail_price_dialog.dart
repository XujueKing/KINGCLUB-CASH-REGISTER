import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../strings.dart';

/// One store SKU, with its exact supplier quotes alongside the touch keypad.
class RetailPriceDialog extends StatefulWidget {
  const RetailPriceDialog({
    super.key,
    required this.product,
    required this.language,
    required this.save,
    this.savePack,
  });
  final Map<String, dynamic> product;
  final UiLanguage language;
  final Future<bool> Function(int cents) save;
  final Future<bool> Function(String unitRef, int cents)? savePack;
  @override
  State<RetailPriceDialog> createState() => _RetailPriceDialogState();
}

class _RetailPriceDialogState extends State<RetailPriceDialog> {
  static const green = Color(0xFF183E35);
  late String amount;
  bool fresh = true, busy = false;
  String? error;
  Map<String, dynamic>? selectedUnit;
  List<Map<String, dynamic>> get units =>
      ((widget.product['saleUnits'] as Map?)?['units'] as List? ?? [])
          .map((v) => Map<String, dynamic>.from(v as Map))
          .toList();
  dynamic get currentPrice =>
      selectedUnit?['priceCents'] ?? widget.product['priceCents'];
  int get stockUnits => (selectedUnit?['stockUnits'] as int?) ?? 1;
  dynamic suggested(dynamic cents) => cents is num ? cents * stockUnits : null;
  String t(String zh, String en, String tw, String th) =>
      [zh, en, tw, th][widget.language.index];
  String name(dynamic value) => value is Map
      ? '${value[['zh-CN', 'en', 'zh-TW', 'th'][widget.language.index]] ?? value['zh-CN'] ?? value.values.firstOrNull ?? ''}'
      : '';
  String money(dynamic cents) => cents is num
      ? '¥ ${(cents / 100).toStringAsFixed(2)}'
      : t('未提供', 'Not provided', '未提供', 'ไม่ได้ระบุ');
  @override
  void initState() {
    super.initState();
    if (widget.savePack != null &&
        (widget.product['saleUnits'] as Map?)?['hideSingle'] == true) {
      selectedUnit = units.firstOrNull;
    }
    amount = ((currentPrice as num? ?? 0) / 100).toStringAsFixed(2);
  }

  int? get cents {
    if (!RegExp(r'^\d{1,7}(\.\d{0,2})?$').hasMatch(amount)) return null;
    final parts = amount.split('.');
    final value =
        int.parse(parts[0]) * 100 +
        int.parse(parts.length == 1 ? '0' : parts[1].padRight(2, '0'));
    return value >= 1 && value <= 100000000 ? value : null;
  }

  void press(String key) => setState(() {
    error = null;
    if (key == 'back') {
      amount = amount.length > 1 ? amount.substring(0, amount.length - 1) : '0';
      fresh = false;
      return;
    }
    final next = fresh
        ? (key == '.' ? '0.' : key)
        : (amount == '0' && key != '.' ? key : amount + key);
    if (RegExp(r'^\d{1,7}(\.\d{0,2})?$').hasMatch(next)) {
      amount = next;
      fresh = false;
    }
  });
  Future<void> save() async {
    final value = cents;
    if (busy || value == null) return;
    setState(() => busy = true);
    bool saved = false;
    try {
      saved = selectedUnit == null
          ? await widget.save(value)
          : await widget.savePack!(selectedUnit!['unitRef'] as String, value);
    } catch (_) {
      /* Never show credentials or raw server messages. */
    }
    if (!mounted) return;
    if (saved) {
      Navigator.pop(context);
      return;
    }
    setState(() {
      busy = false;
      error = t(
        '未保存，请关闭后查看操作提示',
        'Not saved. Close to view the operation notice.',
        '未儲存，請關閉後查看操作提示',
        'ยังไม่บันทึก กรุณาปิดเพื่อดูรายละเอียด',
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final quotes =
        (widget.product['quotes'] as List? ?? [])
            .map((q) => Map<String, dynamic>.from(q as Map))
            .toList()
          ..sort(
            (a, b) => (a['unitCostCents'] as num? ?? double.infinity).compareTo(
              b['unitCostCents'] as num? ?? double.infinity,
            ),
          );
    final size = MediaQuery.sizeOf(context);
    return Dialog(
      backgroundColor: const Color(0xFFF5F4EF),
      child: SizedBox(
        width: math.min(900, size.width - 64),
        height: math.min(580, size.height - 64),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      t('修改零售价', 'Retail price', '修改零售價', 'แก้ไขราคาขาย'),
                      style: const TextStyle(
                        fontSize: 23,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('retail-price-close'),
                    onPressed: busy ? null : () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      flex: 5,
                      child: SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              name(widget.product['names']),
                              style: const TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              name(widget.product['specifications']),
                              style: const TextStyle(
                                color: Colors.grey,
                                fontSize: 16,
                              ),
                            ),
                            const SizedBox(height: 16),
                            if (widget.savePack != null && units.isNotEmpty)
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  if ((widget.product['saleUnits']
                                          as Map?)?['hideSingle'] !=
                                      true)
                                    ChoiceChip(
                                      label: Text(
                                        t('单瓶', 'Single bottle', '單瓶', '1 ขวด'),
                                      ),
                                      selected: selectedUnit == null,
                                      onSelected: busy
                                          ? null
                                          : (_) => setState(() {
                                              selectedUnit = null;
                                              amount =
                                                  ((currentPrice as num) / 100)
                                                      .toStringAsFixed(2);
                                              fresh = true;
                                            }),
                                    ),
                                  for (final unit in units)
                                    ChoiceChip(
                                      key: ValueKey(
                                        'retail-unit-${unit['unitRef']}',
                                      ),
                                      padding: const EdgeInsets.symmetric(
                                        vertical: 10,
                                        horizontal: 8,
                                      ),
                                      label: Text(name(unit['specifications'])),
                                      selected:
                                          selectedUnit?['unitRef'] ==
                                          unit['unitRef'],
                                      onSelected: busy
                                          ? null
                                          : (_) => setState(() {
                                              selectedUnit = unit;
                                              amount =
                                                  ((currentPrice as num) / 100)
                                                      .toStringAsFixed(2);
                                              fresh = true;
                                              error = null;
                                            }),
                                    ),
                                ],
                              ),
                            if (units.isNotEmpty) const SizedBox(height: 16),
                            Text(
                              '${t('当前本店售价', 'Current store price', '目前本店售價', 'ราคาขายปัจจุบัน')}  ${money(currentPrice)}',
                              style: const TextStyle(fontSize: 19),
                            ),
                            const SizedBox(height: 20),
                            Text(
                              t(
                                '供应商报价 / 建议零售价',
                                'Supplier quotes / suggested retail',
                                '供應商報價 / 建議零售價',
                                'ราคาผู้จำหน่าย / ราคาขายแนะนำ',
                              ),
                              style: const TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 10),
                            if (quotes.isEmpty)
                              Text(
                                t(
                                  '暂无对应规格的供应商报价',
                                  'No supplier quote for this size',
                                  '暫無對應規格的供應商報價',
                                  'ไม่มีราคาสำหรับขนาดนี้',
                                ),
                              ),
                            for (final q in quotes)
                              Container(
                                margin: const EdgeInsets.only(bottom: 10),
                                padding: const EdgeInsets.all(14),
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '${q['supplierName']}',
                                      style: const TextStyle(
                                        fontSize: 17,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    const SizedBox(height: 6),
                                    Text(
                                      '${q['specification']} · ${money(q['quoteCents'])} / ${q['quoteUnit']}',
                                      style: const TextStyle(
                                        color: Colors.grey,
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                    Text(
                                      '${t('折算进货单价', 'Unit purchase cost', '折算進貨單價', 'ต้นทุนต่อหน่วย')}  ${money(q['unitCostCents'])}',
                                      style: const TextStyle(
                                        fontSize: 17,
                                        color: green,
                                      ),
                                    ),
                                    const SizedBox(height: 6),
                                    Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            '${t('建议零售价', 'Suggested retail', '建議零售價', 'ราคาขายแนะนำ')}  ${money(suggested(q['suggestedRetailCents']))}',
                                          ),
                                        ),
                                        if (q['suggestedRetailCents'] is num &&
                                            (q['suggestedRetailCents'] as num) >
                                                0)
                                          TextButton(
                                            onPressed: busy
                                                ? null
                                                : () => setState(() {
                                                    amount =
                                                        ((suggested(
                                                                  q['suggestedRetailCents'],
                                                                ) as num) /
                                                                100)
                                                            .toStringAsFixed(2);
                                                    fresh = true;
                                                  }),
                                            child: Text(
                                              t('采用', 'Use', '採用', 'ใช้'),
                                            ),
                                          ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            Text(
                              t(
                                '只修改本店后续售价，历史订单与进货成本保持原记录。',
                                'Applies to future sales. Historical orders and stock costs retain their records.',
                                '只修改本店後續售價，歷史訂單與進貨成本保留原記錄。',
                                'ใช้กับการขายครั้งถัดไป ไม่เปลี่ยนรายการเก่าหรือต้นทุน',
                              ),
                              style: const TextStyle(
                                color: Colors.grey,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 24),
                    Expanded(
                      flex: 4,
                      child: Column(
                        children: [
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 10,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  t(
                                    '新的本店零售价',
                                    'New store price',
                                    '新的本店零售價',
                                    'ราคาขายใหม่',
                                  ),
                                  style: const TextStyle(color: Colors.grey),
                                ),
                                Text(
                                  '¥ $amount',
                                  key: const ValueKey('retail-price-amount'),
                                  style: const TextStyle(
                                    fontSize: 32,
                                    fontWeight: FontWeight.bold,
                                    color: green,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 12),
                          Expanded(
                            child: LayoutBuilder(
                              builder: (context, bounds) => GridView.count(
                                physics: const NeverScrollableScrollPhysics(),
                                crossAxisCount: 3,
                                mainAxisSpacing: 8,
                                crossAxisSpacing: 8,
                                childAspectRatio:
                                    ((bounds.maxWidth - 16) / 3) /
                                    ((bounds.maxHeight - 24) / 4),
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
                                    'back',
                                  ])
                                    FilledButton.tonal(
                                      key: ValueKey('retail-key-$key'),
                                      style: FilledButton.styleFrom(
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(
                                            10,
                                          ),
                                        ),
                                      ),
                                      onPressed: busy ? null : () => press(key),
                                      child: key == 'back'
                                          ? const Icon(Icons.backspace_outlined)
                                          : Text(
                                              key,
                                              style: const TextStyle(
                                                fontSize: 25,
                                              ),
                                            ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                          if (error != null)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Text(
                                error!,
                                style: const TextStyle(
                                  color: Colors.red,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                          SizedBox(
                            width: double.infinity,
                            height: 56,
                            child: FilledButton(
                              key: const ValueKey('retail-price-save'),
                              style: FilledButton.styleFrom(
                                backgroundColor: green,
                              ),
                              onPressed: busy || cents == null ? null : save,
                              child: Text(
                                t(
                                  busy ? '保存中…' : '保存零售价',
                                  busy ? 'Saving…' : 'Save retail price',
                                  busy ? '儲存中…' : '儲存零售價',
                                  busy ? 'กำลังบันทึก…' : 'บันทึกราคาขาย',
                                ),
                                style: const TextStyle(fontSize: 18),
                              ),
                            ),
                          ),
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
