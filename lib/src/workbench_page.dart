import 'dart:async';

import 'live/paid_order_alerts.dart';
import 'live/together_admission_dialog.dart';

import 'package:flutter/material.dart';

import 'scan_icon.dart';

import '../main.dart';
import 'auth/staff_auth_controller.dart';
import 'hardware/printer_discovery_dialog.dart';
import 'live/store_members_panel.dart';
import 'live/receipt_accounts_settings.dart';
import 'live/live_tables_panel.dart';
import 'live/order_history_panel.dart';
import 'live/business_report_panel.dart';
import 'live/inventory_panel.dart';
import 'live/reservations_panel.dart';
import 'strings.dart';

import 'package:flutter/services.dart';

import 'live/cashbook_panel.dart';

/// The single authenticated workspace, using server-backed business panels.
class WorkbenchPage extends StatefulWidget {
  const WorkbenchPage({
    super.key,
    required this.auth,
    required this.language,
    required this.onLanguage,
    required this.onLogout,
  });
  final StaffAuthController auth;
  final UiLanguage language;
  final ValueChanged<UiLanguage> onLanguage;
  final VoidCallback? onLogout;
  @override
  State<WorkbenchPage> createState() => _WorkbenchPageState();
}

class _WorkbenchPageState extends State<WorkbenchPage> {
  final tablesKey = GlobalKey<LiveTablesPanelState>();
  bool changingPage = false;

  Future<void> selectPage(int index) async {
    if (changingPage || page == index) return;
    changingPage = true;
    try {
      if (index == 1 &&
          await tablesKey.currentState?.requestOrdering() == false)
        return;
      if (mounted) setState(() => page = index);
    } finally {
      changingPage = false;
    }
  }

  late final PaidOrderAlerts orderAlerts;
  @override
  void initState() {
    super.initState();
    orderAlerts = PaidOrderAlerts(widget.auth)..addListener(alertChanged);
    unawaited(orderAlerts.start());
  }

  void alertChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    orderAlerts.dispose();
    super.dispose();
  }

  int page = 0;
  String? storeName, storeRef;
  String t(String key) => tr(widget.language, key);
  static const labels = [
    'tables',
    'ordering',
    'orders',
    'members',
    'reports',
    'settings',
    'inventory',
    'reservations',
    'cashbook',
  ];
  static const icons = [
    Icon(Icons.grid_view_rounded),
    Icon(Icons.restaurant_menu),
    Icon(Icons.receipt_long_outlined),
    Icon(Icons.people_outline),
    Icon(Icons.bar_chart_rounded),
    Icon(Icons.tune_rounded),
    Icon(Icons.inventory_2_outlined),
    Icon(Icons.event_seat_outlined),
    Icon(Icons.menu_book_outlined),
  ];

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Row(
        children: [
          Container(
            width: 92,
            color: forest,
            child: Column(
              children: [
                const SizedBox(height: 8),
                SizedBox(
                  width: 64,
                  height: 48,
                  child: Transform.scale(
                    scale: 0.75,
                    child: Image.asset(
                      'assets/brand/kingclub-gold.png',
                      key: const ValueKey('kingclub-logo'),
                      semanticLabel: 'KINGCLUB',
                      width: 76,
                      height: 64,
                      fit: BoxFit.contain,
                      color: const Color(0xffb9c9c2),
                      colorBlendMode: BlendMode.srcIn,
                      cacheWidth: 228,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: ListView.separated(
                    itemCount: labels.length,
                    padding: EdgeInsets.zero,
                    separatorBuilder: (_, _) => const SizedBox(height: 7),
                    itemBuilder: (context, position) {
                      final index = const [0, 1, 3, 2, 7, 6, 4, 8, 5][position];
                      return Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        child: Material(
                          color: page == index
                              ? const Color(0xFF31554A)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(14),
                          child: InkWell(
                            key: ValueKey('nav-$index'),
                            borderRadius: BorderRadius.circular(14),
                            onTap: page == index
                                ? null
                                : () => unawaited(selectPage(index)),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                vertical: 8,
                                horizontal: 3,
                              ),
                              child: Column(
                                children: [
                                  Badge(
                                    isLabelVisible:
                                        index == 0 && orderAlerts.count > 0,
                                    label: Text(orderAlerts.count.toString()),
                                    child: IconTheme(
                                      data: IconThemeData(
                                        color: page == index
                                            ? const Color(0xFFE2C88D)
                                            : const Color(0xFFB9C9C2),
                                        size: 23,
                                      ),
                                      child: icons[index],
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    t(labels[index]),
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: page == index
                                          ? Colors.white
                                          : const Color(0xFFB9C9C2),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 8, 8, 12),
                  child: PopupMenuButton<String>(
                    key: const ValueKey('staff-avatar-menu'),
                    tooltip: t('staffAccountMenu'),
                    offset: const Offset(72, -120),
                    onSelected: (value) {
                      if (value == 'logout') widget.onLogout?.call();
                      if (value == 'exit') SystemNavigator.pop();
                    },
                    itemBuilder: (_) => [
                      PopupMenuItem(
                        value: 'logout',
                        height: 56,
                        enabled: widget.onLogout != null,
                        child: ListTile(
                          leading: const Icon(Icons.logout),
                          title: Text(t('staffMenuSignOut')),
                        ),
                      ),
                      PopupMenuItem(
                        value: 'exit',
                        height: 56,
                        child: ListTile(
                          leading: const Icon(Icons.power_settings_new),
                          title: Text(t('staffExitApp')),
                        ),
                      ),
                    ],
                    child: SizedBox(
                      width: 56,
                      height: 52,
                      child: Center(
                        child: ValueListenableBuilder<Uint8List?>(
                          valueListenable: widget.auth.operatorAvatar,
                          builder: (context, bytes, _) => CircleAvatar(
                            radius: 18,
                            backgroundColor: const Color(0xffdce5df),
                            child: bytes == null
                                ? const Icon(
                                    Icons.person_outline,
                                    color: forest,
                                    size: 24,
                                  )
                                : ClipOval(
                                    child: Image.memory(
                                      bytes,
                                      width: 36,
                                      height: 36,
                                      fit: BoxFit.cover,
                                      gaplessPlayback: true,
                                      errorBuilder: (_, error, stack) =>
                                          const Icon(
                                            Icons.person_outline,
                                            color: forest,
                                            size: 24,
                                          ),
                                    ),
                                  ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: Column(
              children: [
                Container(
                  height: 44,
                  color: Colors.white,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 0,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          widget.auth.session?.storeName ??
                              (storeRef == widget.auth.session?.storeRef
                                  ? storeName
                                  : null) ??
                              'KINGCLUB',
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      if (widget.auth.session?.permissions.contains(
                            'together.admit',
                          ) ==
                          true)
                        TextButton.icon(
                          key: const ValueKey('together-admission-open'),
                          onPressed: () => showDialog<void>(
                            context: context,
                            builder: (_) => TogetherAdmissionDialog(
                              auth: widget.auth,
                              language: widget.language,
                            ),
                          ),
                          icon: const ScanIcon(),
                          label: Text(t('togetherAdmission')),
                        ),
                      Text(
                        [
                          '超级智能收银台',
                          'Super Smart POS',
                          '超級智能收銀台',
                          'ระบบแคชเชียร์อัจฉริยะ',
                        ][widget.language.index],
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(child: content()),
              ],
            ),
          ),
        ],
      ),
    ),
  );

  Widget content() => switch (page) {
    0 || 1 => LiveTablesPanel(
      key: tablesKey,
      orderAlerts: orderAlerts,
      onStoreName: (name) {
        if (mounted &&
            (storeName != name || storeRef != widget.auth.session?.storeRef)) {
          setState(() {
            storeName = name;
            storeRef = widget.auth.session?.storeRef;
          });
        }
      },
      menuVisible: page == 1,
      onMenuChanged: (value) => setState(() => page = value ? 1 : 0),
      auth: widget.auth,
      language: widget.language,
    ),
    2 => OrderHistoryPanel(auth: widget.auth, language: widget.language),
    3 => StoreMembersPanel(auth: widget.auth, language: widget.language),
    4 =>
      widget.auth.session?.permissions.contains('report.read') == true
          ? BusinessReportPanel(auth: widget.auth, language: widget.language)
          : Center(child: Text(t('staffAuthFailure'))),
    6 => InventoryPanel(auth: widget.auth, language: widget.language),
    7 => ReservationsPanel(auth: widget.auth, language: widget.language),
    8 => CashbookPanel(auth: widget.auth, language: widget.language),
    _ => Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(t('language')),
              const SizedBox(width: 20),
              DropdownButton<UiLanguage>(
                key: const ValueKey('staff-language'),
                value: widget.language,
                onChanged: (value) {
                  if (value != null) widget.onLanguage(value);
                },
                items: [
                  for (final language in UiLanguage.values)
                    DropdownMenuItem(
                      value: language,
                      child: Text(
                        ['简体中文', 'English', '繁體中文', 'ไทย'][language.index],
                      ),
                    ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 20),
          OutlinedButton.icon(
            key: const ValueKey('printer-inspect-open'),
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => PrinterDiscoveryDialog(language: widget.language),
            ),
            icon: const Icon(Icons.print_outlined),
            label: Text(t('printerInspectTitle')),
          ),
          const SizedBox(height: 20),
          OutlinedButton.icon(
            key: const ValueKey('receipt-accounts-settings'),
            onPressed:
                widget.auth.session?.permissions.contains('price.adjust') !=
                    true
                ? null
                : () => showDialog<void>(
                    context: context,
                    barrierDismissible: false,
                    builder: (_) => ReceiptAccountsSettings(
                      auth: widget.auth,
                      language: widget.language,
                    ),
                  ),
            icon: const Icon(Icons.account_balance_outlined),
            label: Text(
              [
                '银行／第三方收款码',
                'Bank / third-party QR',
                '銀行／第三方收款碼',
                'QR ธนาคาร / ผู้ให้บริการ',
              ][widget.language.index],
            ),
          ),
        ],
      ),
    ),
  };
}
