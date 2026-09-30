import 'package:flutter/material.dart';

import '../main.dart';
import 'auth/staff_auth_controller.dart';
import 'hardware/printer_discovery_dialog.dart';
import 'live/live_catalog_panel.dart';
import 'live/live_tables_panel.dart';
import 'live/voucher_report_panel.dart';
import 'strings.dart';

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
  int page = 0;
  String t(String key) => tr(widget.language, key);
  static const labels = [
    'tables',
    'ordering',
    'orders',
    'members',
    'reports',
    'settings',
  ];
  static const icons = [
    Icons.grid_view_rounded,
    Icons.restaurant_menu,
    Icons.receipt_long_outlined,
    Icons.people_outline,
    Icons.bar_chart_rounded,
    Icons.tune_rounded,
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
                const SizedBox(height: 20),
                Image.asset(
                  'assets/brand/kingclub.png',
                  key: const ValueKey('kingclub-logo'),
                  semanticLabel: 'KINGCLUB',
                  width: 64,
                  height: 64,
                  cacheWidth: 180,
                ),
                const SizedBox(height: 20),
                Expanded(
                  child: ListView.separated(
                    itemCount: labels.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 7),
                    itemBuilder: (context, index) => Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      child: Material(
                        color: page == index
                            ? const Color(0xFF31554A)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(14),
                        child: InkWell(
                          key: ValueKey('nav-$index'),
                          borderRadius: BorderRadius.circular(14),
                          onTap: () => setState(() => page = index),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              vertical: 13,
                              horizontal: 3,
                            ),
                            child: Column(
                              children: [
                                Icon(
                                  icons[index],
                                  color: page == index
                                      ? const Color(0xFFE2C88D)
                                      : const Color(0xFFB9C9C2),
                                  size: 25,
                                ),
                                const SizedBox(height: 6),
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
                  color: Colors.white,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 0,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          t(labels[page]),
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      Text(widget.auth.session?.displayName ?? ''),
                      const SizedBox(width: 16),
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
                                [
                                  '简体中文',
                                  'English',
                                  '繁體中文',
                                  'ไทย',
                                ][language.index],
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(width: 16),
                      TextButton(
                        key: const ValueKey('staff-logout'),
                        onPressed: widget.onLogout,
                        child: Text(t('staffSignOut')),
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
    // Order views require selection of a real table and its current session.
    0 || 2 => LiveTablesPanel(
      key: ValueKey('tables-$page'),
      auth: widget.auth,
      language: widget.language,
    ),
    1 => LiveCatalogPanel(
      auth: widget.auth,
      language: widget.language,
      onBack: () => setState(() => page = 0),
    ),
    3 => Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.people_outline, size: 48, color: forest),
            const SizedBox(height: 16),
            Text(t('memberIntegrationPending'), textAlign: TextAlign.center),
          ],
        ),
      ),
    ),
    4 =>
      widget.auth.session?.permissions.contains('report.read') == true
          ? VoucherReportPanel(
              auth: widget.auth,
              language: widget.language,
              onBack: () => setState(() => page = 0),
            )
          : Center(child: Text(t('staffAuthFailure'))),
    _ => Center(
      child: OutlinedButton.icon(
        key: const ValueKey('printer-inspect-open'),
        onPressed: () => showDialog<void>(
          context: context,
          builder: (_) => PrinterDiscoveryDialog(language: widget.language),
        ),
        icon: const Icon(Icons.print_outlined),
        label: Text(t('printerInspectTitle')),
      ),
    ),
  };
}
