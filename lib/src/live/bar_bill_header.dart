import 'package:flutter/material.dart';

import '../strings.dart';
import 'table_status_color.dart';

/// Identical header for unused seats and seats with an existing session.
class BarBillHeader extends StatelessWidget {
  const BarBillHeader({
    super.key,
    required this.number,
    required this.color,
    required this.language,
    required this.filter,
    required this.member,
    this.mergeAction,
    this.voucherAction,
  });

  final int number;
  final Color color;
  final UiLanguage language;
  final Widget filter, member;
  final Widget? mergeAction;
  final Widget? voucherAction;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.center,
    children: [
      Container(
        key: const ValueKey('bill-table-badge'),
        constraints: const BoxConstraints(
          minWidth: 52,
          maxWidth: 82,
          minHeight: 48,
        ),
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          gradient: tableStatusGradient(color),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          'B$number',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w800,
            color: color == Colors.white
                ? const Color(0xff263c30)
                : Colors.white,
          ),
        ),
      ),
      const SizedBox(width: 6),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              tr(language, 'ordersDetails'),
              key: const ValueKey('bill-heading'),
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
            ),
            if (mergeAction != null) mergeAction!,
          ],
        ),
      ),
      filter,
      if (voucherAction != null) voucherAction!,
      member,
    ],
  );
}
