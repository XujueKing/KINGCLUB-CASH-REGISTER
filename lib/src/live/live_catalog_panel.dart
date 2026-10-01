import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../auth/staff_auth_controller.dart';
import '../strings.dart';
import 'catalog_snapshot.dart';
import 'table_snapshot.dart';

class LiveCatalogPanel extends StatefulWidget {
  const LiveCatalogPanel({
    super.key,
    required this.auth,
    required this.language,
    required this.onBack,
    this.revision = 0,
    this.onSelect,
    this.paymentTiming = 'postpay',
  });
  final StaffAuthController auth;
  final UiLanguage language;
  final VoidCallback onBack;
  final int revision;
  final String paymentTiming;
  final ValueChanged<CatalogProduct>? onSelect;
  @override
  State<LiveCatalogPanel> createState() => _LiveCatalogPanelState();
}

class _LiveCatalogPanelState extends State<LiveCatalogPanel>
    with WidgetsBindingObserver {
  CatalogSnapshot? data;
  String? category;
  final cursors = <String?>[null];
  int page = 0, epoch = 0;
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
      data = null;
      unawaited(load(reset: true));
    } else if (oldWidget.revision != widget.revision && foreground) {
      unawaited(load(reset: true));
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
    final previousPage = page;
    if (reset) {
      cursors
        ..clear()
        ..add(null);
      page = 0;
    }
    final requestedPage = target ?? page;
    setState(() {
      if (requestedPage != previousPage) data = null;
      loading = true;
      failed = false;
    });
    try {
      final result = await widget.auth.readCatalog(
        categoryRef: category,
        afterProduct: cursors[requestedPage],
      );
      if (!mounted ||
          generation != epoch ||
          !identical(identity, widget.auth.session)) {
        return;
      }
      if (result.nextAfterProduct != null &&
          cursors.take(requestedPage + 1).contains(result.nextAfterProduct)) {
        throw const FormatException();
      }
      setState(() {
        data = result;
        page = requestedPage;
        loading = false;
      });
    } catch (_) {
      if (mounted && generation == epoch) {
        setState(() {
          failed = true;
          loading = false;
          data = null;
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
            52 * math.max(1, MediaQuery.textScalerOf(context).scale(14) / 14),
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: ChoiceChip(
                label: Text(t('all')),
                selected: category == null,
                onSelected: loading ? null : (_) => select(null),
              ),
            ),
            for (final c in data?.categories ?? <CatalogCategory>[])
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: ChoiceChip(
                  key: ValueKey('catalog-category-${c.reference}'),
                  label: Text(c.name(widget.language)),
                  selected: category == c.reference,
                  onSelected: loading ? null : (_) => select(c.reference),
                ),
              ),
          ],
        ),
      ),
      if (loading) const LinearProgressIndicator(),
      Expanded(
        child: failed
            ? Center(child: Text(t('liveReadFailed')))
            : data == null
            ? const SizedBox()
            : data!.products.isEmpty
            ? Center(child: Text(t('catalogEmpty')))
            : LayoutBuilder(
                builder: (context, constraints) {
                  final scale = math.max(
                    1.0,
                    MediaQuery.textScalerOf(context).scale(16) / 16,
                  );
                  final columns = ((constraints.maxWidth - 14) / (250 * scale))
                      .floor()
                      .clamp(1, 6);
                  return GridView.builder(
                    padding: const EdgeInsets.all(12),
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: columns,
                      crossAxisSpacing: 10,
                      mainAxisSpacing: 10,
                      mainAxisExtent: 168 * scale,
                    ),
                    itemCount: data!.products.length,
                    itemBuilder: (context, i) => productCard(data!.products[i]),
                  );
                },
              ),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Row(
          children: [
            Expanded(
              child: data == null
                  ? const SizedBox()
                  : Tooltip(
                      message:
                          '${t('liveObserved')}: ${data!.observedAt.toLocal()}',
                      child: Text(
                        '${t('liveObserved')}: ${TimeOfDay.fromDateTime(data!.observedAt.toLocal()).format(context)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
            ),
            IconButton(
              tooltip: t('livePrevious'),
              onPressed: loading || page == 0
                  ? null
                  : () => unawaited(load(target: page - 1)),
              icon: const Icon(Icons.chevron_left),
            ),
            Text('${t('livePage')} ${page + 1}'),
            IconButton(
              key: const ValueKey('catalog-next'),
              tooltip: t('liveNext'),
              onPressed: loading || data?.nextAfterProduct == null
                  ? null
                  : () {
                      cursors.removeRange(page + 1, cursors.length);
                      cursors.add(data!.nextAfterProduct);
                      unawaited(load(target: page + 1));
                    },
              icon: const Icon(Icons.chevron_right),
            ),
          ],
        ),
      ),
    ],
  );

  Widget productCard(CatalogProduct p) {
    final available = p.inventoryKnown && p.available > 0;
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
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Tooltip(
              message: p.name(widget.language),
              child: Text(
                p.name(widget.language),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(height: 3),
            Tooltip(
              message: p.specification(widget.language),
              child: Text(
                p.specification(widget.language),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13, color: Color(0xff616c65)),
              ),
            ),
            const Spacer(),
            Text(
              !p.inventoryKnown
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
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${data!.currency} ${formatCents(p.priceCents)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (widget.onSelect != null)
                  IconButton.filledTonal(
                    key: ValueKey('catalog-add-${p.reference}'),
                    tooltip: t('cartAdd'),
                    onPressed:
                        foreground &&
                            !loading &&
                            (widget.paymentTiming == 'prepay' || available)
                        ? () => widget.onSelect!(p)
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
    );
  }
}
