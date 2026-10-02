import 'package:flutter/material.dart';

import '../strings.dart';
import 'product_thumbnail.dart';
import 'table_snapshot.dart';

class BillProductCard extends StatelessWidget {
  const BillProductCard({
    super.key,
    required this.language,
    required this.name,
    required this.specification,
    required this.quantity,
    required this.priceCents,
    required this.totalCents,
    required this.base,
    this.thumbnailPath,
    this.footer,
    this.badges,
    this.leadingBadge,
    this.onTap,
    this.priceLabel,
  });
  final UiLanguage language;
  final String name, specification;
  final int quantity, priceCents, totalCents;
  final Uri? base;
  final String? thumbnailPath;
  final Widget? footer;
  final Widget? badges;
  final Widget? leadingBadge;
  final VoidCallback? onTap;
  final String? priceLabel;
  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.symmetric(vertical: 7),
    decoration: BoxDecoration(
      color: Colors.white,
      border: Border.all(color: const Color(0xffd7e2dc)),
      borderRadius: BorderRadius.circular(10),
    ),
    child: Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (leadingBadge != null || badges != null) ...[
                Row(children: [?leadingBadge, const Spacer(), ?badges]),
                const SizedBox(height: 9),
              ],
              Row(
                children: [
                  ProductThumbnail(path: thumbnailPath, base: base),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: Color(0xff203d32),
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          specification,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 12,
                            color: Color(0xff63756b),
                          ),
                        ),
                        Text(
                          priceLabel ?? '${tr(language, 'billUnitPrice')} ¥${formatCents(priceCents)}',
                          style: const TextStyle(fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      const SizedBox(height: 7),
                      Text('× $quantity', style: const TextStyle(fontSize: 13)),
                      Text(
                        '¥${formatCents(totalCents)}',
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              if (footer != null) ...[const SizedBox(height: 6), footer!],
            ],
          ),
        ),
      ),
    ),
  );
}
