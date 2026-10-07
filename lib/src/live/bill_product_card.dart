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
    this.totalLabel,
    this.quantityControls = false,
    this.onPlus,
    this.onMinus,
    this.productRef,
    this.specialPrice = false,
    this.showThumbnail = true,
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
  final String? priceLabel, totalLabel;
  final bool quantityControls;
  final VoidCallback? onPlus, onMinus;
  final String? productRef;
  final bool specialPrice;
  final bool showThumbnail;
  Widget quantityButton(bool plus) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: () {},
    child: IconButton(
      key: productRef == null
          ? null
          : ValueKey('cart-${plus ? 'plus' : 'minus'}-$productRef'),
      onPressed: plus ? onPlus : onMinus,
      tooltip: tr(language, plus ? 'cartAdd' : 'cartRemove'),
      padding: const EdgeInsets.all(4),
      constraints: const BoxConstraints.tightFor(width: 36, height: 36),
      icon: Container(
        width: 26,
        height: 26,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: plus
              ? (onPlus == null
                    ? const Color(0xffdddddd)
                    : const Color(0xffffc107))
              : Colors.transparent,
          border: Border.all(
            color: (plus ? onPlus : onMinus) == null
                ? const Color(0xffcccccc)
                : const Color(0xffffc107),
            width: 1.5,
          ),
        ),
        child: Icon(
          plus ? Icons.add : Icons.remove,
          size: 21,
          color: (plus ? onPlus : onMinus) == null
              ? const Color(0xff999999)
              : plus
              ? Colors.black
              : const Color(0xffd99a00),
        ),
      ),
    ),
  );
  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.symmetric(vertical: 2),
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
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (leadingBadge != null || badges != null) ...[
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: leadingBadge ?? const SizedBox(),
                      ),
                    ),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: badges ?? const SizedBox(),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 5),
              ],
              Row(
                children: [
                  if (showThumbnail)
                    ProductThumbnail(path: thumbnailPath, base: base),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                  color: Color(0xff203d32),
                                ),
                              ),
                            ),
                            if (specialPrice) ...[
                              const SizedBox(width: 4),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 4,
                                  vertical: 1,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFFFE8AC),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  [
                                    '特价',
                                    'Special',
                                    '特價',
                                    'ราคาพิเศษ',
                                  ][language.index],
                                  style: const TextStyle(
                                    fontSize: 10,
                                    color: Color(0xFF805500),
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 3),
                        Text(
                          specification,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 12,
                            color: Color(0xff63756b),
                          ),
                        ),
                        Text(
                          priceLabel ??
                              '${tr(language, 'billUnitPrice')} ¥${formatCents(priceCents)}',
                          style: const TextStyle(fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      const SizedBox(height: 2),
                      if (quantityControls)
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            quantityButton(false),
                            Text(
                              '$quantity',
                              style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            quantityButton(true),
                          ],
                        )
                      else
                        Text(
                          '× $quantity',
                          style: const TextStyle(fontSize: 13),
                        ),
                      Text(
                        totalLabel ?? '¥${formatCents(totalCents)}',
                        style: const TextStyle(
                          fontSize: 15,
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
