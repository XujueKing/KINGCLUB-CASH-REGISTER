import 'live/together_admission_dialog.dart';

import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../main.dart';
import 'auth/staff_auth_controller.dart';
import 'hardware/printer_discovery_dialog.dart';
import 'live/member_seating_panel.dart';
import 'live/live_tables_panel.dart';
import 'live/voucher_report_panel.dart';
import 'strings.dart';
import 'power_icon.dart';

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
  String? storeName, storeRef;
  String t(String key) => tr(widget.language, key);
  static const labels = [
    'tables',
    'ordering',
    'orders',
    'members',
    'reports',
    'settings',
    'voucherWorkspace',
  ];
  static const icons = [
    Icons.grid_view_rounded,
    Icons.restaurant_menu,
    Icons.receipt_long_outlined,
    Icons.people_outline,
    Icons.bar_chart_rounded,
    Icons.tune_rounded,
    Icons.qr_code_scanner,
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
                    separatorBuilder: (_, _) => const SizedBox(height: 3),
                    itemBuilder: (context, position) {
                      final index = const [0, 1, 6, 2, 3, 4, 5][position];
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
                                : () => setState(() => page = index),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                vertical: 8,
                                horizontal: 3,
                              ),
                              child: Column(
                                children: [
                                  Icon(
                                    icons[index],
                                    color: page == index
                                        ? const Color(0xFFE2C88D)
                                        : const Color(0xFFB9C9C2),
                                    size: 23,
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
                  padding: const EdgeInsets.only(top: 8),
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
                                errorBuilder: (_, error, stack) => const Icon(
                                  Icons.person_outline,
                                  color: forest,
                                  size: 24,
                                ),
                              ),
                            ),
                    ),
                  ),
                ),
                const SizedBox(height: 28),
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 0, 10, 12),
                  child: Material(
                    color: Colors.transparent,
                    borderRadius: BorderRadius.circular(14),
                    child: InkWell(
                      key: const ValueKey('staff-logout'),
                      borderRadius: BorderRadius.circular(14),
                      onTap: widget.onLogout,
                      child: SizedBox(
                        width: 72,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            vertical: 13,
                            horizontal: 3,
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const ColorFiltered(
                                colorFilter: ColorFilter.mode(
                                  Color(0xffb9c9c2),
                                  BlendMode.srcIn,
                                ),
                                child: PowerIcon(),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                [
                                  '退出',
                                  'Sign out',
                                  '退出',
                                  'ออก',
                                ][widget.language.index],
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: Color(0xffb9c9c2),
                                ),
                              ),
                            ],
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
                          icon: const Icon(Icons.qr_code_scanner),
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
    // Order views require selection of a real table and its current session.
    0 || 1 || 2 || 6 => LiveTablesPanel(
      key: const ValueKey('tables'),
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
      voucherVisible: page == 6,
      onMenuChanged: (value) => setState(() => page = value ? 1 : 0),
      auth: widget.auth,
      language: widget.language,
    ),
    3 => MemberSeatingPanel(auth: widget.auth, language: widget.language),
    4 =>
      widget.auth.session?.permissions.contains('report.read') == true
          ? VoucherReportPanel(
              auth: widget.auth,
              language: widget.language,
              onBack: () => setState(() => page = 0),
            )
          : Center(child: Text(t('staffAuthFailure'))),
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
        ],
      ),
    ),
  };
}
