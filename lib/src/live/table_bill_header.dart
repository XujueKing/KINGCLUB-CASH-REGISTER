import 'package:flutter/material.dart';

import '../strings.dart';
import 'table_status_color.dart';

/// Shared V1 table bill header: table badge, details, count, filter, scan, member.
class TableBillHeader extends StatelessWidget {
  const TableBillHeader({
    super.key,
    required this.tableName,
    required this.color,
    required this.language,
    required this.statusLabel,
    required this.guestsLabel,
    required this.filter,
    required this.voucher,
    required this.member,
    this.onStatusTap,
  });
  final String tableName, statusLabel, guestsLabel;
  final Color color;
  final UiLanguage language;
  final Widget filter, voucher, member;
  final VoidCallback? onStatusTap;
  String t(String key) => tr(language, key);
  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
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
            tableName,
            textAlign: TextAlign.center,
            maxLines: 2,
            style: TextStyle(
              color: color == Colors.white
                  ? const Color(0xff263c30)
                  : Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      t('ordersDetails'),
                      key: const ValueKey('bill-heading'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: TextButton(
                      onPressed: onStatusTap,
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 5),
                        minimumSize: const Size(0, 20),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: Text(
                        statusLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 10),
                      ),
                    ),
                  ),
                ],
              ),
              Text(
                guestsLabel,
                style: const TextStyle(fontSize: 10, color: Color(0xff9e9e9e)),
              ),
            ],
          ),
        ),
        filter,
        voucher,
        member,
      ],
    );
  }
}
