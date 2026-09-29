import 'dart:async';

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
  });
  final StaffAuthController auth;
  final UiLanguage language;
  final VoidCallback onBack;
  final int revision;
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
    if (reset) {
      cursors
        ..clear()
        ..add(null);
      page = 0;
    }
    final requestedPage = target ?? page;
    setState(() {
      data = null;
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
        padding: const EdgeInsets.all(12),
        child: Wrap(
          spacing: 16,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            OutlinedButton(
              onPressed: widget.onBack,
              child: Text(t('ordersBack')),
            ),
            Text(
              t('catalogTitle'),
              style: Theme.of(context).textTheme.titleLarge,
            ),
            OutlinedButton(
              key: const ValueKey('catalog-refresh'),
              onPressed: loading ? null : () => unawaited(load(reset: true)),
              child: Text(t('liveRefresh')),
            ),
          ],
        ),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Text(
          t(widget.onSelect == null ? 'catalogNotice' : 'cartNotice'),
        ),
      ),
      SizedBox(
        height: 60,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.all(8),
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
      if (data != null)
        Text('${t('liveObserved')}: ${data!.observedAt.toLocal()}'),
      if (loading) const LinearProgressIndicator(),
      Expanded(
        child: failed
            ? Center(child: Text(t('liveReadFailed')))
            : data == null
            ? const SizedBox()
            : data!.products.isEmpty
            ? Center(child: Text(t('catalogEmpty')))
            : ListView.builder(
                padding: const EdgeInsets.all(12),
                itemCount: data!.products.length,
                itemBuilder: (context, i) {
                  final p = data!.products[i];
                  return Card(
                    key: ValueKey('catalog-product-${p.reference}'),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            p.name(widget.language),
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                          Text(p.specification(widget.language)),
                          if (widget.onSelect != null)
                            OutlinedButton(
                              key: ValueKey('catalog-add-${p.reference}'),
                              onPressed:
                                  foreground &&
                                      p.inventoryKnown &&
                                      p.available > 0
                                  ? () => widget.onSelect!(p)
                                  : null,
                              child: Text(t('cartAdd')),
                            ),
                          Wrap(
                            spacing: 24,
                            runSpacing: 8,
                            children: [
                              Text(
                                '${data!.currency} ${formatCents(p.priceCents)}',
                              ),
                              Text(
                                !p.inventoryKnown
                                    ? t('catalogUnknown')
                                    : p.available == 0
                                    ? t('catalogSoldOut')
                                    : '${t('catalogAvailable')}: ${p.available}',
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
      ),
      Padding(
        padding: const EdgeInsets.all(12),
        child: Wrap(
          spacing: 20,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            OutlinedButton(
              onPressed: loading || page == 0
                  ? null
                  : () => unawaited(load(target: page - 1)),
              child: Text(t('livePrevious')),
            ),
            Text('${t('livePage')} ${page + 1}'),
            OutlinedButton(
              key: const ValueKey('catalog-next'),
              onPressed: loading || data?.nextAfterProduct == null
                  ? null
                  : () {
                      cursors.removeRange(page + 1, cursors.length);
                      cursors.add(data!.nextAfterProduct);
                      unawaited(load(target: page + 1));
                    },
              child: Text(t('liveNext')),
            ),
          ],
        ),
      ),
    ],
  );
}
