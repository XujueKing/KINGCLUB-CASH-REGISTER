import 'operation_authorization_dialog.dart';

import 'package:flutter/material.dart';

import '../strings.dart';
import 'table_snapshot.dart';
import '../auth/staff_auth_controller.dart';
import 'member_identity_panel.dart';

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
  VoidCallback? onDetails,
  StaffAuthController? auth,
  String? expenseOwnerUserAccount,
  ValueChanged<String?>? onExpenseOwner,
  Map<String, Object>? authorizationScope,
  ValueChanged<String>? onAuthorization,
}) => showDialog<int>(
  context: context,
  builder: (_) => _ItemPriceDialog(
    language: language,
    name: name,
    quantity: quantity,
    originalCents: originalCents,
    currentCents: currentCents,
    onDetails: onDetails,
    auth: auth,
    expenseOwnerUserAccount: expenseOwnerUserAccount,
    onExpenseOwner: onExpenseOwner,
    authorizationScope: authorizationScope,
    onAuthorization: onAuthorization,
  ),
);

class _ItemPriceDialog extends StatefulWidget {
  const _ItemPriceDialog({
    required this.language,
    required this.name,
    required this.quantity,
    required this.originalCents,
    required this.currentCents,
    this.onDetails,
    this.auth,
    this.expenseOwnerUserAccount,
    this.onExpenseOwner,
    this.authorizationScope,
    this.onAuthorization,
  });
  final UiLanguage language;
  final String name;
  final int quantity, originalCents, currentCents;
  final VoidCallback? onDetails;
  final StaffAuthController? auth;
  final String? expenseOwnerUserAccount;
  final ValueChanged<String?>? onExpenseOwner;
  final Map<String, Object>? authorizationScope;
  final ValueChanged<String>? onAuthorization;
  @override
  State<_ItemPriceDialog> createState() => _ItemPriceDialogState();
}

class _ItemPriceDialogState extends State<_ItemPriceDialog> {
  late final price = TextEditingController(
    text: formatCents(widget.currentCents),
  );
  final discount = TextEditingController(text: '10');
  bool byDiscount = true;
  bool replacePrice = true;
  late int? shortcutPrice = widget.currentCents;
  late String? expenseOwner = widget.expenseOwnerUserAccount;
  String? expenseOwnerName;
  Future<void> selectExpenseOwner() async {
    final selected = await showDialog<({String account, String name})>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(
          words([
            '扫码选择赠送承担人',
            'Scan expense owner',
            '掃碼選擇贈送承擔人',
            'สแกนผู้รับผิดชอบค่าใช้จ่าย',
          ]),
        ),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: MemberIdentityPanel(
              auth: widget.auth!,
              language: widget.language,
              actionsBuilder: (member, code, stillCurrent) => FilledButton(
                onPressed: () {
                  if (stillCurrent()) {
                    Navigator.pop(dialogContext, (
                      account: member.memberRef,
                      name: member.nickname ?? member.memberRef,
                    ));
                  }
                },
                child: Text(
                  words([
                    '使用此会员',
                    'Use this member',
                    '使用此會員',
                    'เลือกสมาชิกนี้',
                  ]),
                ),
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(words(['取消', 'Cancel', '取消', 'ยกเลิก'])),
          ),
        ],
      ),
    );
    if (mounted && selected != null) {
      setState(() {
        expenseOwner = selected.account;
        expenseOwnerName = selected.name;
      });
    }
  }

  String words(List<String> values) => values[widget.language.index];
  int? get cents =>
      shortcutPrice ??
      (byDiscount
          ? discountedUnitPrice(widget.originalCents, discount.text)
          : parseUnitPrice(
              price.text.endsWith('.') ? '${price.text}0' : price.text,
            ));

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
      width: 480,
      child: SingleChildScrollView(
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
              onSelectionChanged: (value) => setState(() {
                byDiscount = value.single;
                shortcutPrice = null;
              }),
            ),
            const SizedBox(height: 12),
            if (byDiscount)
              GridView.count(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                crossAxisCount: 4,
                childAspectRatio: 2.5,
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
                children: [
                  for (final rate in [
                    '9.5',
                    '9',
                    '8.8',
                    '8.5',
                    '8',
                    '7.5',
                    '7',
                    '6.5',
                    '6',
                    '5',
                    '4',
                    '3',
                  ])
                    OutlinedButton(
                      key: ValueKey('discount-$rate'),
                      style: OutlinedButton.styleFrom(
                        backgroundColor: discount.text == rate
                            ? Theme.of(context).colorScheme.primaryContainer
                            : null,
                      ),
                      onPressed: () => setState(() {
                        discount.text = rate;
                        shortcutPrice = null;
                      }),
                      child: Text(
                        words([
                          '$rate折',
                          '${100 - (double.parse(rate) * 10).round()}% off',
                          '$rate折',
                          'ลด ${100 - (double.parse(rate) * 10).round()}%',
                        ]),
                      ),
                    ),
                ],
              )
            else ...[
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                alignment: Alignment.centerRight,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '¥ ${price.text}',
                  key: const ValueKey('item-price-input'),
                  style: const TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              GridView.count(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                crossAxisCount: 4,
                childAspectRatio: 2.7,
                mainAxisSpacing: 6,
                crossAxisSpacing: 6,
                children: [
                  for (final key in [
                    '7',
                    '8',
                    '9',
                    '⌫',
                    '4',
                    '5',
                    '6',
                    'C',
                    '1',
                    '2',
                    '3',
                    '.',
                    '0',
                    '00',
                  ])
                    OutlinedButton(
                      key: ValueKey('price-key-$key'),
                      onPressed: () => setState(() {
                        shortcutPrice = null;
                        if (key == 'C') {
                          price.text = '0';
                          replacePrice = true;
                          return;
                        }
                        if (key == '⌫') {
                          price.text = price.text.length > 1
                              ? price.text.substring(0, price.text.length - 1)
                              : '0';
                          replacePrice = false;
                          return;
                        }
                        var next = replacePrice ? '' : price.text;
                        if (key == '.') {
                          if (next.contains('.')) return;
                          next = next.isEmpty ? '0.' : '$next.';
                        } else {
                          next = (next == '0' ? '' : next) + key;
                          if (RegExp(r'^0+$').hasMatch(next)) next = '0';
                        }
                        if (!RegExp(r'^(0|[1-9][0-9]{0,6})(\.[0-9]{0,2})?$')
                            .hasMatch(next)) {
                          return;
                        }
                        price.text = next;
                        replacePrice = false;
                      }),
                      child: Text(key, style: const TextStyle(fontSize: 22)),
                    ),
                ],
              ),
            ],
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
                FilledButton.tonal(
                  key: const ValueKey('item-price-waive'),
                  onPressed: () => setState(() {
                    shortcutPrice = 0;
                    price.text = '0.00';
                  }),
                  child: Text(
                    words(['免单', 'Complimentary', '免單', 'ไม่คิดเงิน']),
                  ),
                ),
                OutlinedButton(
                  key: const ValueKey('item-price-reset'),
                  onPressed: () => setState(() {
                    shortcutPrice = widget.originalCents;
                    price.text = formatCents(widget.originalCents);
                  }),
                  child: Text(
                    words(['恢复原价', 'Reset price', '恢復原價', 'คืนราคาเดิม']),
                  ),
                ),
              ],
            ),
            if (cents == 0 && widget.auth != null)
              TextButton.icon(
                key: const ValueKey('item-price-expense-owner'),
                onPressed: selectExpenseOwner,
                icon: const Icon(Icons.qr_code_scanner),
                label: Text(
                  expenseOwnerName ??
                      expenseOwner ??
                      words([
                        '门店赠送 · 扫码记到个人',
                        'Store expense · scan a person',
                        '門店贈送 · 掃碼記到個人',
                        'ค่าใช้จ่ายร้าน · สแกนผู้รับผิดชอบ',
                      ]),
                ),
              ),
          ],
        ),
      ),
    ),
    actions: [
      if (widget.onDetails != null)
        TextButton(
          key: const ValueKey('item-price-details'),
          onPressed: () {
            widget.onDetails!();
            Navigator.pop(context);
          },
          child: Text(
            words([
              '上酒 / 退款',
              'Serving / refunds',
              '上酒 / 退款',
              'เสิร์ฟ / คืนเงิน',
            ]),
          ),
        ),
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(words(['取消', 'Cancel', '取消', 'ยกเลิก'])),
      ),
      FilledButton(
        key: const ValueKey('item-price-save'),
        onPressed: cents == null || cents! * widget.quantity > 100000000
            ? null
            : () async {
                final amount = cents!;
                if (widget.authorizationScope != null && widget.auth != null) {
                  final authorization = await scanPriceAuthorization(
                    context,
                    auth: widget.auth!,
                    language: widget.language,
                    scope: {
                      ...widget.authorizationScope!,
                      'originalUnitPriceCents': widget.originalCents,
                      'unitPriceCents': amount,
                      if (amount == 0 && expenseOwner != null)
                        'expenseOwnerUserAccount': expenseOwner!,
                    },
                  );
                  if (!mounted || authorization == null) return;
                  widget.onAuthorization?.call(authorization);
                }
                widget.onExpenseOwner?.call(cents == 0 ? expenseOwner : null);
                if (!context.mounted) return;
                Navigator.pop(context, cents);
              },
        child: Text(words(['确定', 'Apply', '確定', 'ยืนยัน'])),
      ),
    ],
  );
}
