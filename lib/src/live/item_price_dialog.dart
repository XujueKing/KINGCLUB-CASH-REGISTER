import 'package:flutter/material.dart';

import '../strings.dart';
import 'table_snapshot.dart';

// Parse decimal input as integers so discounts are rounded per unit, not per bill.
int? parseUnitPrice(String raw) {
  final match = RegExp(r'^(0|[1-9][0-9]{0,6})(?:\.([0-9]{1,2}))?$')
      .firstMatch(raw.trim());
  if (match == null) return null;
  final cents =
      int.parse(match[1]!) * 100 + int.parse((match[2] ?? '').padRight(2, '0'));
  return cents <= 100000000 ? cents : null;
}

int? discountedUnitPrice(int originalCents, String raw) {
  final discount = parseUnitPrice(raw);
  if (originalCents < 1 ||
      originalCents > 100000000 ||
      discount == null ||
      discount < 1 ||
      discount > 1000) {
    return null;
  }
  return (originalCents * discount + 500) ~/ 1000;
}

/// Returns null for cancellation. Zero is an explicit waiver, not cancellation.
Future<int?> showItemPriceDialog(
  BuildContext context, {
  required UiLanguage language,
  required String name,
  required int quantity,
  required int originalCents,
  required int currentCents,
}) => showDialog<int>(
  context: context,
  builder: (_) => _ItemPriceDialog(
    language: language,
    name: name,
    quantity: quantity,
    originalCents: originalCents,
    currentCents: currentCents,
  ),
);

class _ItemPriceDialog extends StatefulWidget {
  const _ItemPriceDialog({
    required this.language,
    required this.name,
    required this.quantity,
    required this.originalCents,
    required this.currentCents,
  });
  final UiLanguage language;
  final String name;
  final int quantity, originalCents, currentCents;
  @override
  State<_ItemPriceDialog> createState() => _ItemPriceDialogState();
}

class _ItemPriceDialogState extends State<_ItemPriceDialog> {
  late final price = TextEditingController(
    text: formatCents(widget.currentCents),
  );
  final discount = TextEditingController();
  bool byDiscount = false;
  String words(List<String> values) => values[widget.language.index];
  int? get cents => byDiscount
      ? discountedUnitPrice(widget.originalCents, discount.text)
      : parseUnitPrice(price.text);

  @override
  void dispose() {
    price.dispose();
    discount.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.name),
    content: SizedBox(
      width: 380,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '${words(['原单价', 'Original unit price', '原單價', 'ราคาต่อหน่วยเดิม'])} ¥ ${formatCents(widget.originalCents)}',
          ),
          const SizedBox(height: 16),
          SegmentedButton<bool>(
            segments: [
              ButtonSegment(
                value: false,
                label: Text(
                  words(['改单价', 'Unit price', '改單價', 'ราคาต่อหน่วย']),
                ),
              ),
              ButtonSegment(
                value: true,
                label: Text(words(['打折', 'Discount', '打折', 'ส่วนลด'])),
              ),
            ],
            selected: {byDiscount},
            onSelectionChanged: (value) =>
                setState(() => byDiscount = value.single),
          ),
          const SizedBox(height: 12),
          TextField(
            key: ValueKey(
              byDiscount ? 'item-discount-input' : 'item-price-input',
            ),
            controller: byDiscount ? discount : price,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              labelText: byDiscount
                  ? words([
                      '折扣（8.5 为八五折）',
                      'Rate out of 10 (8.5 = 15% off)',
                      '折扣（8.5 為八五折）',
                      'อัตราจาก 10 (8.5 = ลด 15%)',
                    ])
                  : words([
                      '单价（元）',
                      'Unit price (CNY)',
                      '單價（元）',
                      'ราคาต่อหน่วย (CNY)',
                    ]),
              errorText: cents == null
                  ? words([
                      '请输入有效金额或折扣',
                      'Enter a valid price or rate',
                      '請輸入有效金額或折扣',
                      'กรอกราคาหรืออัตราที่ถูกต้อง',
                    ])
                  : null,
            ),
          ),
          const SizedBox(height: 12),
          if (cents != null)
            Text(
              '¥ ${formatCents(cents!)} × ${widget.quantity} = ¥ ${formatCents(cents! * widget.quantity)}',
              key: const ValueKey('item-price-preview'),
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          Wrap(
            spacing: 12,
            children: [
              TextButton(
                key: const ValueKey('item-price-waive'),
                onPressed: () => setState(() {
                  byDiscount = false;
                  price.text = '0.00';
                }),
                child: Text(words(['免单', 'Complimentary', '免單', 'ไม่คิดเงิน'])),
              ),
              TextButton(
                onPressed: () => setState(() {
                  byDiscount = false;
                  price.text = formatCents(widget.originalCents);
                }),
                child: Text(
                  words(['恢复原价', 'Reset price', '恢復原價', 'คืนราคาเดิม']),
                ),
              ),
            ],
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(words(['取消', 'Cancel', '取消', 'ยกเลิก'])),
      ),
      FilledButton(
        key: const ValueKey('item-price-save'),
        onPressed: cents == null || cents! * widget.quantity > 100000000
            ? null
            : () => Navigator.pop(context, cents),
        child: Text(words(['确定', 'Apply', '確定', 'ยืนยัน'])),
      ),
    ],
  );
}
