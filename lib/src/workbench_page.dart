import 'package:flutter/material.dart';

import '../main.dart';
import 'models.dart';
import 'service_probe.dart';
import 'strings.dart';
import 'auth/staff_access_page.dart';

class WorkbenchPage extends StatefulWidget {
  const WorkbenchPage({super.key, required this.preview});
  final bool preview;
  @override
  State<WorkbenchPage> createState() => _WorkbenchPageState();
}

class _WorkbenchPageState extends State<WorkbenchPage> {
  late final Workbench model;
  UiLanguage language = UiLanguage.zh;
  int page = 0;
  String area = 'all', category = 'all', tableSearch = '', productSearch = '';
  TableStage? stage;
  String orderFilter = 'all';
  final endpoint = TextEditingController();
  String? probeStatus;
  bool checking = false;
  int probeEpoch = 0;
  String t(String key) => tr(language, key);

  @override
  void initState() {
    super.initState();
    model = Workbench(preview: widget.preview)..addListener(changed);
  }

  void changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    model.removeListener(changed);
    model.dispose();
    endpoint.dispose();
    super.dispose();
  }

  Color stageColor(TableStage value) => switch (value) {
    TableStage.free => const Color(0xFF698277),
    TableStage.ordering => const Color(0xFF237763),
    TableStage.unpaid => const Color(0xFFAA6832),
    TableStage.cleaning => const Color(0xFF6E739F),
  };
  String stageKey(TableStage value) =>
      ['free', 'taking', 'unpaid', 'cleaning'][value.index];

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: LayoutBuilder(
        builder: (context, box) {
          if (box.maxWidth < 900 || box.maxHeight < 400) {
            return empty(
              Icons.screen_rotation_outlined,
              'landscape',
              'workbench',
            );
          }
          return Row(
            children: [
              sidebar(),
              Expanded(
                child: Column(
                  children: [
                    header(),
                    Container(
                      width: double.infinity,
                      color: model.preview
                          ? const Color(0xFFF4E9D2)
                          : const Color(0xFFE6ECE8),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 24,
                        vertical: 9,
                      ),
                      child: Row(
                        children: [
                          Icon(
                            model.preview
                                ? Icons.science_outlined
                                : Icons.lock_outline,
                            size: 16,
                            color: forest,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              t(model.preview ? 'banner' : 'liveBanner'),
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: switch (page) {
                        0 => tables(),
                        1 => ordering(),
                        2 => orders(),
                        3 => empty(
                          Icons.badge_outlined,
                          'pendingModule',
                          'memberHint',
                        ),
                        4 => empty(
                          Icons.bar_chart_outlined,
                          'pendingModule',
                          'reportHint',
                        ),
                        _ => settings(),
                      },
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    ),
  );

  Widget sidebar() {
    const icons = [
      Icons.grid_view_rounded,
      Icons.restaurant_menu,
      Icons.receipt_long_outlined,
      Icons.people_outline,
      Icons.bar_chart_rounded,
      Icons.tune_rounded,
    ];
    const labels = [
      'tables',
      'ordering',
      'orders',
      'members',
      'reports',
      'settings',
    ];
    return Container(
      width: 92,
      color: forest,
      child: Column(
        children: [
          const SizedBox(height: 20),
          Image.asset(
            'assets/brand/kingclub.png',
            key: const ValueKey('kingclub-logo'),
            semanticLabel: 'KINGCLUB',
            width: 64,
            height: 64,
            cacheWidth: 180,
            fit: BoxFit.contain,
          ),
          const SizedBox(height: 12),
          Expanded(
            child: ListView.separated(
              itemCount: labels.length,
              separatorBuilder: (_, _) => const SizedBox(height: 7),
              itemBuilder: (context, i) => Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Material(
                  color: page == i
                      ? const Color(0xFF31554A)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(14),
                  child: InkWell(
                    key: ValueKey('nav-$i'),
                    borderRadius: BorderRadius.circular(14),
                    onTap: () => setState(() => page = i),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        vertical: 13,
                        horizontal: 3,
                      ),
                      child: Column(
                        children: [
                          Icon(
                            icons[i],
                            color: page == i
                                ? const Color(0xFFE2C88D)
                                : const Color(0xFFB9C9C2),
                            size: 25,
                          ),
                          const SizedBox(height: 6),
                          Text(
                            t(labels[i]),
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 11,
                              color: page == i
                                  ? Colors.white
                                  : const Color(0xFFB9C9C2),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'POS / 01',
              style: TextStyle(
                color: Color(0xFF9AB3A6),
                fontSize: 10,
                letterSpacing: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget header() => Container(
    color: Colors.white,
    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
    child: Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                t('workbench'),
                style: const TextStyle(
                  fontSize: 21,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                t(model.preview ? 'sampleStore' : 'live'),
                style: const TextStyle(fontSize: 12, color: Color(0xFF728078)),
              ),
            ],
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: paper,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            children: [
              Icon(
                model.preview
                    ? Icons.science_outlined
                    : Icons.cloud_off_outlined,
                size: 16,
              ),
              const SizedBox(width: 6),
              Text(
                t(model.preview ? 'preview' : 'live'),
                style: const TextStyle(fontSize: 12),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        PopupMenuButton<UiLanguage>(
          key: const ValueKey('language'),
          tooltip: t('language'),
          icon: const Icon(Icons.translate, size: 21),
          onSelected: (v) => setState(() => language = v),
          itemBuilder: (_) => [
            for (final v in UiLanguage.values)
              PopupMenuItem(
                value: v,
                child: Text(['简体中文', 'English', '繁體中文', 'ไทย'][v.index]),
              ),
          ],
        ),
      ],
    ),
  );

  Widget empty(IconData icon, String title, String hint, {Widget? action}) =>
      Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(28),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 490),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.all(25),
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: Color(0xFFE8EDE6),
                  ),
                  child: Icon(icon, size: 43, color: const Color(0xFF688477)),
                ),
                const SizedBox(height: 22),
                Text(
                  t(title),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 21,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  t(hint),
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Color(0xFF7A847D), height: 1.6),
                ),
                if (action != null) ...[const SizedBox(height: 24), action],
              ],
            ),
          ),
        ),
      );

  Widget liveEmpty() => empty(
    Icons.storefront_outlined,
    'emptyLive',
    'authHint',
    action: FilledButton.icon(
      onPressed: togglePreview,
      icon: const Icon(Icons.science_outlined),
      label: Text(t('enterPreview')),
    ),
  );

  Widget chips(List<String> keys, String value, void Function(String) change) =>
      SizedBox(
        height: 50,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: keys.length,
          separatorBuilder: (_, _) => const SizedBox(width: 8),
          itemBuilder: (_, i) => Center(
            child: ChoiceChip(
              label: Text(t(keys[i])),
              selected: value == keys[i],
              showCheckmark: false,
              selectedColor: forest,
              backgroundColor: Colors.white,
              labelStyle: TextStyle(
                color: value == keys[i] ? Colors.white : ink,
                fontSize: 13,
              ),
              side: BorderSide(
                color: value == keys[i] ? forest : const Color(0xFFDDE3DB),
              ),
              onSelected: (_) => change(keys[i]),
            ),
          ),
        ),
      );

  Widget tables() {
    if (!model.preview) return liveEmpty();
    final visible = model.desks
        .where(
          (d) =>
              (area == 'all' || d.area == area) &&
              (stage == null || d.stage == stage) &&
              d.id.toLowerCase().contains(tableSearch.toLowerCase()),
        )
        .toList();
    return Padding(
      padding: const EdgeInsets.all(22),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      t('overview'),
                      style: const TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      '${model.desks.length}',
                      style: const TextStyle(color: Color(0xFF819086)),
                    ),
                    const Spacer(),
                    SizedBox(
                      width: 205,
                      child: TextField(
                        key: const ValueKey('table-search'),
                        onChanged: (s) => setState(() => tableSearch = s),
                        decoration: InputDecoration(
                          hintText: t('searchTable'),
                          prefixIcon: const Icon(Icons.search, size: 20),
                          isDense: true,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                chips(
                  ['all', 'hall', 'booth'],
                  area,
                  (v) => setState(() => area = v),
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: visible.isEmpty
                      ? empty(Icons.search_off, 'noResults', 'searchTable')
                      : LayoutBuilder(
                          builder: (_, size) {
                            final columns = (size.maxWidth / 190).floor().clamp(
                              2,
                              5,
                            );
                            final rows = (visible.length / columns)
                                .ceil()
                                .clamp(1, 3);
                            final minimum = MediaQuery.textScalerOf(context)
                                .scale(132);
                            final tileHeight =
                                ((size.maxHeight - (rows - 1) * 12) / rows)
                                    .clamp(minimum, minimum + 36)
                                    .toDouble();
                            return GridView.builder(
                              key: const ValueKey('table-grid'),
                              itemCount: visible.length,
                              gridDelegate:
                                  SliverGridDelegateWithFixedCrossAxisCount(
                                    crossAxisCount: columns,
                                    mainAxisExtent: tileHeight,
                                    mainAxisSpacing: 12,
                                    crossAxisSpacing: 12,
                                  ),
                              itemBuilder: (_, index) =>
                                  tableCard(visible[index]),
                            );
                          },
                        ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  height: 46,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: FilterChip(
                          label: Text('${t('all')} ${model.desks.length}'),
                          selected: stage == null,
                          onSelected: (_) => setState(() => stage = null),
                        ),
                      ),
                      for (final s in TableStage.values)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: FilterChip(
                            avatar: Icon(
                              Icons.circle,
                              size: 10,
                              color: stageColor(s),
                            ),
                            label: Text(
                              '${t(stageKey(s))} ${model.desks.where((d) => d.stage == s).length}',
                            ),
                            selected: stage == s,
                            onSelected: (_) => setState(() => stage = s),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 20),
          SizedBox(width: 270, child: tableSummary()),
        ],
      ),
    );
  }

  Widget tableCard(Desk desk) {
    final selected = model.selectedDesk == desk.id;
    final color = stageColor(desk.stage);
    return Material(
      color: selected ? const Color(0xFFEAF1E9) : Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: selected ? forest : const Color(0xFFE1E6DD),
          width: selected ? 2 : 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: ValueKey('desk-${desk.id}'),
        onTap: () => model.select(desk.id),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      desk.id,
                      style: const TextStyle(
                        fontSize: 25,
                        fontWeight: FontWeight.w700,
                        letterSpacing: .5,
                      ),
                    ),
                  ),
                  Icon(
                    selected
                        ? Icons.check_circle
                        : Icons.table_restaurant_outlined,
                    color: selected ? forest : const Color(0xFFB6C3B8),
                    size: 21,
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                '${t(desk.area)}  ·  ${desk.guests} ${t('guests')}',
                style: const TextStyle(color: Color(0xFF87938A), fontSize: 12),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const Spacer(),
              Row(
                children: [
                  Flexible(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: color.withValues(alpha: .1),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        t(stageKey(desk.stage)),
                        style: TextStyle(color: color, fontSize: 12),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                  if (desk.cents > 0) ...[
                    const SizedBox(width: 4),
                    Text(
                      money(desk.cents),
                      style: TextStyle(
                        color: color,
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget panel({required Widget child}) => Material(
    color: Colors.white,
    clipBehavior: Clip.antiAlias,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(18),
      side: const BorderSide(color: Color(0xFFE4E8DE)),
    ),
    child: child,
  );

  Widget tableSummary() {
    final selected = model.selectedDesk;
    if (selected == null) {
      return panel(
        child: empty(Icons.touch_app_outlined, 'selectTable', 'selectHint'),
      );
    }
    final desk = model.desks.firstWhere((d) => d.id == selected);
    return panel(
      child: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(22),
              children: [
                Text(
                  t('tables'),
                  style: const TextStyle(
                    color: Color(0xFF859185),
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  desk.id,
                  style: const TextStyle(
                    fontSize: 40,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '${t(desk.area)}  /  ${t(stageKey(desk.stage))}',
                  style: TextStyle(color: stageColor(desk.stage)),
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  child: Divider(),
                ),
                pair('guests', '${desk.guests}'),
                pair('elapsed', '${desk.minutes}'),
                pair('currentBill', money(desk.cents)),
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Divider(),
                ),
                pair('draft', '${model.count} ${t('items')}'),
                Text(
                  money(model.total),
                  style: const TextStyle(
                    fontSize: 27,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  t('localOnly'),
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xFF87938A),
                    height: 1.5,
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                FilledButton.icon(
                  key: const ValueKey('open-menu'),
                  onPressed: model.canDraft
                      ? () => setState(() => page = 1)
                      : null,
                  icon: const Icon(Icons.add, size: 19),
                  label: Text(t('startDraft')),
                ),
                const SizedBox(height: 10),
                OutlinedButton(
                  onPressed: blocked,
                  child: Text(t('tableActions')),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget pair(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Text(
            t(label),
            style: const TextStyle(color: Color(0xFF7D8A80), fontSize: 12),
          ),
        ),
        const SizedBox(width: 10),
        Flexible(
          child: Text(
            value,
            textAlign: TextAlign.end,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
      ],
    ),
  );

  Widget ordering() {
    if (!model.preview) return liveEmpty();
    if (!model.canDraft) {
      return empty(
        Icons.table_restaurant_outlined,
        'selectTable',
        'selectHint',
        action: FilledButton(
          onPressed: () => setState(() => page = 0),
          child: Text(t('back')),
        ),
      );
    }
    final products = model.products
        .where(
          (p) =>
              (category == 'all' || p.category == category) &&
              t(p.label).toLowerCase().contains(productSearch.toLowerCase()),
        )
        .toList();
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Row(
        children: [
          SizedBox(width: 322, child: cart()),
          const SizedBox(width: 20),
          Expanded(
            child: Column(
              children: [
                Row(
                  children: [
                    Text(
                      t('ordering'),
                      style: const TextStyle(
                        fontSize: 21,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const Spacer(),
                    SizedBox(
                      width: 235,
                      child: TextField(
                        key: const ValueKey('product-search'),
                        decoration: InputDecoration(
                          hintText: t('searchProduct'),
                          prefixIcon: const Icon(Icons.search),
                        ),
                        onChanged: (s) => setState(() => productSearch = s),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                chips(
                  ['all', 'beer', 'spirits', 'soft', 'snacks', 'sets'],
                  category,
                  (v) => setState(() => category = v),
                ),
                const SizedBox(height: 10),
                Expanded(
                  child: products.isEmpty
                      ? empty(Icons.search_off, 'noResults', 'searchProduct')
                      : LayoutBuilder(
                          builder: (_, box) => GridView.builder(
                            itemCount: products.length,
                            gridDelegate:
                                SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: (box.maxWidth / 195)
                                      .floor()
                                      .clamp(2, 5),
                                  mainAxisExtent: 182,
                                  mainAxisSpacing: 12,
                                  crossAxisSpacing: 12,
                                ),
                            itemBuilder: (_, i) => productCard(products[i]),
                          ),
                        ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  IconData productIcon(String cat) => switch (cat) {
    'beer' => Icons.sports_bar_outlined,
    'spirits' => Icons.local_bar_outlined,
    'soft' => Icons.local_drink_outlined,
    'sets' => Icons.tapas_outlined,
    _ => Icons.ramen_dining_outlined,
  };
  Widget productCard(Product product) => Material(
    color: product.available ? Colors.white : const Color(0xFFEDEFE9),
    borderRadius: BorderRadius.circular(16),
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      key: ValueKey('product-${product.id}'),
      onTap: product.available ? () => chooseVariant(product) : null,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: paper,
                    borderRadius: BorderRadius.circular(11),
                  ),
                  child: Icon(
                    productIcon(product.category),
                    color: const Color(0xFF7D8D72),
                    size: 26,
                  ),
                ),
                const Spacer(),
                if (!product.available)
                  Flexible(
                    child: Text(
                      t('soldOut'),
                      style: const TextStyle(
                        color: Color(0xFF9A7762),
                        fontSize: 12,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 13),
            Text(
              t(product.label),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
            const Spacer(),
            Row(
              children: [
                Expanded(
                  child: Text(
                    money(product.variants.first.cents),
                    style: const TextStyle(
                      fontSize: 19,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Icon(
                  product.variants.length > 1
                      ? Icons.tune
                      : Icons.add_circle_outline,
                  size: 22,
                  color: forest,
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );

  Widget cart() => panel(
    child: Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 16, 8),
          child: Row(
            children: [
              IconButton(
                onPressed: () => setState(() => page = 0),
                icon: const Icon(Icons.arrow_back),
                tooltip: t('back'),
              ),
              Expanded(
                child: Text(
                  '${model.selectedDesk}  ·  ${t('draft')}',
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: model.cart.isEmpty
              ? empty(Icons.shopping_bag_outlined, 'cartEmpty', 'localOnly')
              : ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: model.cart.length,
                  separatorBuilder: (_, _) => const Divider(height: 24),
                  itemBuilder: (_, i) {
                    final line = model.cart[i];
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          t(line.product.label),
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          '${t(line.variant.label)}  ·  ${money(line.variant.cents)}',
                          style: const TextStyle(
                            fontSize: 12,
                            color: Color(0xFF859082),
                          ),
                        ),
                        const SizedBox(height: 7),
                        Row(
                          children: [
                            IconButton(
                              key: ValueKey('minus-${line.key}'),
                              onPressed: () => model.change(line.key, -1),
                              icon: const Icon(
                                Icons.remove_circle_outline,
                                size: 23,
                              ),
                            ),
                            Text(
                              '${line.quantity}',
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            IconButton(
                              key: ValueKey('plus-${line.key}'),
                              onPressed: line.quantity < 99
                                  ? () => model.change(line.key, 1)
                                  : null,
                              icon: const Icon(
                                Icons.add_circle_outline,
                                size: 23,
                              ),
                            ),
                            const Spacer(),
                            Text(
                              money(line.cents),
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ],
                    );
                  },
                ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  TextButton.icon(
                    onPressed: editNote,
                    icon: const Icon(Icons.edit_note, size: 18),
                    label: Text(t('note')),
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed: model.cart.isEmpty ? null : clearDraft,
                    icon: const Icon(Icons.delete_outline),
                    tooltip: t('clear'),
                  ),
                ],
              ),
              if (model.note.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    model.note,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              pair('total', money(model.total)),
              Text(
                '${model.count} ${t('items')} · ${t('draft')}',
                style: const TextStyle(fontSize: 11, color: Color(0xFF869381)),
              ),
              const SizedBox(height: 12),
              FilledButton(
                key: const ValueKey('checkout'),
                onPressed: model.cart.isEmpty ? null : checkout,
                child: Text(t('checkout')),
              ),
            ],
          ),
        ),
      ],
    ),
  );

  Future<void> chooseVariant(Product product) async {
    if (product.variants.length == 1) {
      model.add(product, product.variants.first);
      return;
    }
    var selected = product.variants.first;
    final variant = await showDialog<Variant>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, update) => AlertDialog(
          title: Text(t('variants')),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(t(product.label)),
                  const SizedBox(height: 20),
                  for (final v in product.variants)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: OutlinedButton(
                        key: ValueKey('variant-${v.id}'),
                        style: OutlinedButton.styleFrom(
                          backgroundColor: selected == v
                              ? const Color(0xFFEAF1E9)
                              : null,
                        ),
                        onPressed: () => update(() => selected = v),
                        child: Row(
                          children: [
                            Icon(
                              selected == v
                                  ? Icons.radio_button_checked
                                  : Icons.radio_button_off,
                              size: 19,
                            ),
                            const SizedBox(width: 10),
                            Expanded(child: Text(t(v.label))),
                            Text(money(v.cents)),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(t('cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, selected),
              child: Text(t('add')),
            ),
          ],
        ),
      ),
    );
    if (mounted && variant != null) model.add(product, variant);
  }

  Future<bool> confirm(String title, String message) async =>
      await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(t(title)),
          content: Text(t(message)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(t('cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(t('confirm')),
            ),
          ],
        ),
      ) ??
      false;
  Future<void> togglePreview() async {
    if (!await confirm(
          model.preview ? 'leavePreview' : 'preview',
          model.preview ? 'staffExitPreview' : 'previewConfirm',
        ) ||
        !mounted) {
      return;
    }
    probeEpoch++;
    if (model.preview) {
      await Navigator.of(context).pushReplacement<void, void>(
        MaterialPageRoute(builder: (_) => const StaffAccessPage()),
      );
      return;
    }
    checking = false;
    probeStatus = null;
    page = 0;
    area = 'all';
    stage = null;
    category = 'all';
    tableSearch = '';
    productSearch = '';
    model.setPreview(!model.preview);
  }

  Future<void> clearDraft() async {
    if (await confirm('clear', 'clearConfirm') && mounted) model.clear();
  }

  Future<void> editNote() async {
    var draftNote = model.note;
    final note = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t('note')),
        content: SizedBox(
          width: 420,
          child: TextFormField(
            initialValue: draftNote,
            onChanged: (value) => draftNote = value,
            maxLength: 200,
            minLines: 2,
            maxLines: 4,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(t('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, draftNote.trim()),
            child: Text(t('save')),
          ),
        ],
      ),
    );
    if (mounted && note != null) model.saveNote(note);
  }

  void blocked() => showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(t('notConnected')),
      content: Text(t('blocked')),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: Text(t('confirm')),
        ),
      ],
    ),
  );

  void checkout() => showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('${t('checkout')} · ${model.selectedDesk}'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(14),
                color: const Color(0xFFF4E9D2),
                child: Text(
                  t('checkoutHint'),
                  style: const TextStyle(height: 1.5),
                ),
              ),
              const SizedBox(height: 16),
              for (final line in model.cart)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${t(line.product.label)}\n${t(line.variant.label)} × ${line.quantity}',
                        ),
                      ),
                      const SizedBox(width: 12),
                      Text(money(line.cents)),
                    ],
                  ),
                ),
              const Divider(),
              pair('total', money(model.total)),
              const SizedBox(height: 14),
              Text(
                t('blocked'),
                style: const TextStyle(color: Color(0xFF8C7656)),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: Text(t('cancel')),
        ),
        FilledButton(
          key: const ValueKey('real-payment'),
          onPressed: null,
          child: Text(t('paymentDisabled')),
        ),
      ],
    ),
  );

  Widget orders() {
    if (!model.preview) return liveEmpty();
    final samples = [
      (id: 'DEMO-001', table: 'T02', cents: 14800, status: 'unpaid'),
      (id: 'DEMO-002', table: 'T08', cents: 23600, status: 'unpaid'),
      (id: 'DEMO-003', table: 'B01', cents: 9600, status: 'paid'),
    ];
    final list = samples
        .where((o) => orderFilter == 'all' || o.status == orderFilter)
        .toList();
    return Padding(
      padding: const EdgeInsets.all(26),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            t('orders'),
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          Text(
            t('sampleOrders'),
            style: const TextStyle(color: Color(0xFF899184)),
          ),
          const SizedBox(height: 12),
          chips(
            ['all', 'unpaid', 'paid'],
            orderFilter,
            (v) => setState(() => orderFilter = v),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: ListView.separated(
              itemCount: list.length,
              separatorBuilder: (_, _) => const SizedBox(height: 12),
              itemBuilder: (_, i) {
                final order = list[i];
                return panel(
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 24,
                      vertical: 14,
                    ),
                    leading: const Icon(
                      Icons.receipt_long_outlined,
                      color: forest,
                    ),
                    title: Text('${order.id}  ·  ${order.table}'),
                    subtitle: Text(t(order.status)),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          money(order.cents),
                          style: const TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(width: 24),
                        const Icon(Icons.chevron_right),
                      ],
                    ),
                    onTap: () => showDialog<void>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: Text(t('orderDetails')),
                        content: SizedBox(
                          width: 400,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              pair('orderId', order.id),
                              pair('tables', order.table),
                              pair('amount', money(order.cents)),
                              pair('source', t('sampleSource')),
                              const SizedBox(height: 12),
                              Text(t('blocked')),
                            ],
                          ),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(ctx),
                            child: Text(t('back')),
                          ),
                          FilledButton(
                            onPressed: null,
                            child: Text(t('print')),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget settings() => ListView(
    padding: const EdgeInsets.all(28),
    children: [
      Text(
        t('settings'),
        style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
      ),
      const SizedBox(height: 20),
      panel(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                t('connection'),
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 10),
              Text(t('connectionHint')),
              const SizedBox(height: 20),
              TextField(
                key: const ValueKey('endpoint'),
                controller: endpoint,
                keyboardType: TextInputType.url,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText: t('endpoint'),
                  hintText: 'https://…',
                ),
                onChanged: (_) => setState(() {
                  probeEpoch++;
                  checking = false;
                  probeStatus = null;
                }),
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 18,
                runSpacing: 10,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  FilledButton.icon(
                    onPressed: checking ? null : checkConnection,
                    icon: const Icon(Icons.cloud_outlined, size: 20),
                    label: Text(t(checking ? 'checking' : 'check')),
                  ),
                  if (probeStatus != null)
                    Text(
                      t(probeStatus!),
                      style: const TextStyle(color: forest),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 18),
      panel(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                t('preview'),
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 10),
              Text(t('previewConfirm')),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: togglePreview,
                icon: const Icon(Icons.science_outlined),
                label: Text(t(model.preview ? 'leavePreview' : 'enterPreview')),
              ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 18),
      Text(
        '${t('device')}  SUNMI D2 · Android 11 · ARM 32-bit',
        style: const TextStyle(color: Color(0xFF7E897B)),
      ),
    ],
  );

  Future<void> checkConnection() async {
    if (model.preview) {
      setState(() => probeStatus = 'previewNetwork');
      return;
    }
    final uri = readinessUri(endpoint.text);
    if (uri == null) {
      setState(() => probeStatus = 'invalidUrl');
      return;
    }
    final epoch = ++probeEpoch;
    setState(() {
      checking = true;
      probeStatus = null;
    });
    final ready = await probeService(uri);
    if (!mounted || epoch != probeEpoch || model.preview) return;
    setState(() {
      checking = false;
      probeStatus = ready ? 'ready' : 'failed';
    });
  }
}
