import 'dart:async';

import 'swipe_grid.dart';

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../auth/staff_auth_controller.dart';
import '../strings.dart';
import 'catalog_snapshot.dart';
import 'product_thumbnail.dart';
import 'table_snapshot.dart';

class LiveCatalogPanel extends StatefulWidget {
  const LiveCatalogPanel({
    super.key,
    required this.auth,
    required this.language,
    required this.onBack,
    this.revision = 0,
    this.header,
    this.onSelect,
    this.canAdd,
    this.paymentTiming = 'postpay',
  });
  final Widget? header;
  final StaffAuthController auth;
  final UiLanguage language;
  final VoidCallback onBack;
  final int revision;
  final String paymentTiming;
  final ValueChanged<CatalogProduct>? onSelect;
  final bool Function(CatalogProduct)? canAdd;
  @override
  State<LiveCatalogPanel> createState() => _LiveCatalogPanelState();
}

class _LiveCatalogPanelState extends State<LiveCatalogPanel>
    with WidgetsBindingObserver {
  CatalogSnapshot? data;
  List<CatalogCategory> categories = [];
  String? category;
  List<List<CatalogProduct>> groups = [];
  int epoch = 0;
  bool loading = false, failed = false, foreground = true;
  String t(String key) => tr(widget.language, key);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.auth.addListener(identityChanged);
    unawaited(load());
  }

  void identityChanged() {
    ++epoch;
    setState(() {
      data = null;
      categories = [];
      loading = false;
      failed = false;
    });
  }

  @override
  void didUpdateWidget(covariant LiveCatalogPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.auth != widget.auth) {
      oldWidget.auth.removeListener(identityChanged);
      widget.auth.addListener(identityChanged);
      category = null;
      categories = [];
      data = null;
      unawaited(load(reset: true));
    } else if (oldWidget.revision != widget.revision && foreground) {
      unawaited(load());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    if (foreground) {
      unawaited(load(reset: true));
    } else {
      identityChanged();
    }
  }

  Future<void> load({bool reset = false, int? target}) async {
    final generation = ++epoch, identity = widget.auth.session;
    setState(() {
      loading = true;
      failed = false;
    });
    try {
      final products = <CatalogProduct>[];
      final seen = <String>{};
      String? cursor;
      late CatalogSnapshot result;
      do {
        result = await widget.auth.readCatalog(
          categoryRef: category,
          afterProduct: cursor,
        );
        if (!mounted ||
            generation != epoch ||
            !identical(identity, widget.auth.session))
          return;
        products.addAll(result.products);
        cursor = result.nextAfterProduct;
        if (cursor != null && (!seen.add(cursor) || seen.length >= 100)) {
          throw const FormatException();
        }
      } while (cursor != null);
      final families = <String, List<CatalogProduct>>{};
      for (final p in products) {
        final key =
            '${p.categoryRef}/${p.productGroupRef == null ? "sku:${p.reference}" : "group:${p.productGroupRef}"}';
        (families[key] ??= []).add(p);
      }
      setState(() {
        data = result;
        categories = result.categories;
        groups = families.values.toList();
        loading = false;
      });
    } catch (_) {
      if (mounted && generation == epoch) {
        setState(() {
          failed = true;
          loading = false;
        });
      }
    }
  }

  void select(String? ref) {
    if (category == ref) return;
    data = null;
    category = ref;
    unawaited(load(reset: true));
  }

  @override
  void dispose() {
    ++epoch;
    widget.auth.removeListener(identityChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      if (widget.header != null) widget.header!,
      if (widget.header == null)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Row(
            children: [
              IconButton(
                tooltip: t('ordersBack'),
                onPressed: widget.onBack,
                icon: const Icon(Icons.arrow_back, size: 20),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  t('catalogTitle'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Tooltip(
                message: t(
                  widget.onSelect == null ? 'catalogNotice' : 'cartNotice',
                ),
                child: const Padding(
                  padding: EdgeInsets.all(12),
                  child: Icon(Icons.info_outline, size: 20),
                ),
              ),
              IconButton(
                key: const ValueKey('catalog-refresh'),
                tooltip: t('liveRefresh'),
                onPressed: loading ? null : () => unawaited(load(reset: true)),
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
        ),
      SizedBox(
        height:
            44 * math.max(1, MediaQuery.textScalerOf(context).scale(14) / 14),
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: ChoiceChip(
                label: Text(t('all')),
                selected: category == null,
                onSelected: foreground ? (_) => select(null) : null,
              ),
            ),
            for (final c in categories)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: ChoiceChip(
                  key: ValueKey('catalog-category-${c.reference}'),
                  label: Text(c.name(widget.language)),
                  selected: category == c.reference,
                  onSelected: foreground ? (_) => select(c.reference) : null,
                ),
              ),
          ],
        ),
      ),
      if (failed && data != null) Text(t('liveReadFailed')),
      Expanded(
        child: failed && data == null
            ? Center(child: Text(t('liveReadFailed')))
            : data == null
            ? const SizedBox()
            : LayoutBuilder(
                builder: (context, constraints) {
                  final scale = math.max(
                    1.0,
                    MediaQuery.textScalerOf(context).scale(16) / 16,
                  );
                  final columns = ((constraints.maxWidth - 14) / (200 * scale))
                      .floor()
                      .clamp(1, 6);
                  return SwipeGrid(
                    key: ValueKey('catalog-page-$category'),
                    columns: columns,
                    tileHeight: 132 * scale,
                    fillHeight: true,
                    loading: loading,
                    hasPrevious: false,
                    hasNext: false,
                    onPrevious: () {},
                    onNext: () {},
                    itemCount: groups.length,
                    itemBuilder: (context, i) => productCard(groups[i]),
                  );
                },
              ),
      ),
    ],
  );

  bool canSelectProduct(CatalogProduct p) =>
      widget.onSelect != null &&
      foreground &&
      !failed &&
      p.inventoryKnown &&
      p.available > 0 &&
      (widget.canAdd?.call(p) ?? true);

  String variantCopy(String values) => values.split('|')[widget.language.index];

  Future<void> chooseVariant(List<CatalogProduct> variants) async {
    if (variants.length == 1) {
      if (canSelectProduct(variants.first)) widget.onSelect!(variants.first);
      return;
    }
    final generation = epoch, identity = widget.auth.session;
    final selected = await showDialog<CatalogProduct>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(variants.first.name(widget.language)),
        content: SizedBox(
          width: 480,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final p in variants)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 5),
                    child: SizedBox(
                      width: double.infinity,
                      child: OutlinedButton(
                        key: ValueKey('catalog-variant-${p.reference}'),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.all(18),
                        ),
                        onPressed: canSelectProduct(p)
                            ? () => Navigator.pop(context, p)
                            : null,
                        child: Text(
                          '${p.specification(widget.language)}   ${data!.currency == 'CNY' ? '¥' : data!.currency} ${formatCents(p.priceCents)}\n${p.inventoryKnown ? "${t('catalogAvailable')}: ${p.available}" : t('catalogUnknown')}',
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    if (selected != null &&
        mounted &&
        generation == epoch &&
        identical(identity, widget.auth.session) &&
        canSelectProduct(selected)) {
      widget.onSelect!(selected);
    }
  }

  Widget productCard(List<CatalogProduct> variants) {
    final p = variants.first;
    final multiple = variants.length > 1;
    final price = variants.map((p) => p.priceCents).reduce(math.min);
    final available = variants.any((p) => p.inventoryKnown && p.available > 0);
    final canSelect = variants.any(canSelectProduct);
    final stockColor = !p.inventoryKnown
        ? const Color(0xff986500)
        : available
        ? const Color(0xff16733e)
        : const Color(0xffb53636);
    return Material(
      key: ValueKey('catalog-product-${p.reference}'),
      color: available ? Colors.white : const Color(0xfff2f2ef),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(
          color: available ? const Color(0xffb2c6ba) : const Color(0xffd2d2cd),
        ),
      ),
      child: InkWell(
        key: ValueKey('catalog-select-${p.reference}'),
        borderRadius: BorderRadius.circular(8),
        onTap: canSelect ? () => unawaited(chooseVariant(variants)) : null,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 4),
              Row(
                children: [
                  ProductThumbnail(
                    path: p.thumbnailPath,
                    base: widget.auth.session?.base,
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Tooltip(
                          message: p.name(widget.language),
                          child: LayoutBuilder(
                            builder: (context, bounds) {
                              final name = p.name(widget.language);
                              var fontSize = 16.0;
                              while (fontSize > 12) {
                                final measure = TextPainter(
                                  text: TextSpan(
                                    text: name,
                                    style: TextStyle(
                                      fontSize: fontSize,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  textDirection: Directionality.of(context),
                                  textScaler: MediaQuery.textScalerOf(context),
                                  maxLines: 2,
                                )..layout(maxWidth: bounds.maxWidth);
                                final fits = !measure.didExceedMaxLines;
                                measure.dispose();
                                if (fits) break;
                                fontSize--;
                              }
                              return Text(
                                name,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: fontSize,
                                  height: 1.15,
                                  fontWeight: FontWeight.w700,
                                ),
                              );
                            },
                          ),
                        ),
                        const SizedBox(height: 3),
                        Tooltip(
                          message: p.specification(widget.language),
                          child: Text(
                            multiple
                                ? variants
                                      .map(
                                        (p) => p.specification(widget.language),
                                      )
                                      .join(' / ')
                                : p.specification(widget.language),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 13,
                              color: Color(0xff616c65),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const Spacer(),
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          multiple
                              ? variantCopy('多规格|Multiple sizes|多規格|หลายขนาด')
                              : !p.inventoryKnown
                              ? t('catalogUnknown')
                              : !available
                              ? t('catalogSoldOut')
                              : '${t('catalogAvailable')}: ${p.available}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            color: stockColor,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${data!.currency == 'CNY' ? '¥' : data!.currency} ${formatCents(price)}${multiple ? variantCopy(' 起| +| 起| +') : ''}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (widget.onSelect != null && multiple)
                    TextButton(
                      onPressed: canSelect
                          ? () => unawaited(chooseVariant(variants))
                          : null,
                      child: Text(variantCopy('选规格|Size|選規格|ขนาด')),
                    )
                  else if (widget.onSelect != null)
                    IconButton.filledTonal(
                      key: ValueKey('catalog-add-${p.reference}'),
                      style: IconButton.styleFrom(
                        minimumSize: const Size(32, 32),
                        fixedSize: const Size(32, 32),
                        padding: const EdgeInsets.all(6),
                        tapTargetSize: MaterialTapTargetSize.padded,
                      ),
                      iconSize: 20,
                      tooltip: t('cartAdd'),
                      onPressed: canSelect
                          ? () => unawaited(chooseVariant(variants))
                          : null,
                      icon: const Icon(Icons.add),
                    )
                  else
                    const SizedBox(height: 42),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
