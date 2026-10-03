import 'table_members_panel.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../auth/staff_auth_controller.dart';
import '../strings.dart';
import 'opening_snapshot.dart';
import 'table_snapshot.dart';

class QuickOpeningDialog extends StatefulWidget {
  const QuickOpeningDialog({
    super.key,
    required this.auth,
    required this.table,
    required this.language,
  });
  final StaffAuthController auth;
  final LiveTable table;
  final UiLanguage language;
  @override
  State<QuickOpeningDialog> createState() => _QuickOpeningDialogState();
}

class _QuickOpeningDialogState extends State<QuickOpeningDialog> {
  OpeningContext? data;
  final memberPanel = GlobalKey<TableMembersPanelState>();
  String? openedSessionRef;
  String mode = 'manual';
  int count = 1;
  bool busy = true, attempted = false;
  String? error;
  final threshold = TextEditingController();
  String t(String key) => tr(widget.language, key);
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final pending = await widget.auth.pendingOpenings();
      if (pending.any((p) => p.tableId == widget.table.reference)) {
        throw StateError('pending');
      }
      final value = await widget.auth.readOpeningContext(
        tableId: widget.table.reference,
      );
      if (!mounted) return;
      setState(() {
        data = value;
        mode = value.mode;
        count = (value.minimumPeople ?? 1).clamp(1, value.maximumSeats);
        threshold.text = value.mode == 'minimum_spend'
            ? ((value.minimumSpendCents ?? 0) / 100).toStringAsFixed(2)
            : '${value.minimumPeople ?? 1}';
      });
    } catch (_) {
      if (mounted) setState(() => error = 'openingRefresh');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> open() async {
    if (busy || data == null || memberPanel.currentState?.busy == true) return;
    if (openedSessionRef != null) {
      final linked = await memberPanel.currentState?.attachTo(
        openedSessionRef!,
      );
      if (mounted && linked == true) Navigator.pop(context, true);
      return;
    }
    if (attempted) return;
    final rule = <String, dynamic>{'mode': mode};
    if (mode == 'minimum_spend') {
      final value = double.tryParse(threshold.text);
      if (value == null ||
          !value.isFinite ||
          value <= 0 ||
          value > 21474836.47) {
        setState(() => error = 'openingRule_minimum_spend');
        return;
      }
      rule['minimumSpendCents'] = (value * 100).round();
    }
    if (mode == 'minimum_people') {
      final value = int.tryParse(threshold.text);
      if (value == null || value < 1 || value > count) {
        setState(() => error = 'openingRule_minimum_people');
        return;
      }
      rule['minimumPeople'] = value;
    }
    setState(() {
      busy = true;
      attempted = true;
      error = null;
    });
    try {
      final result = await widget.auth.submitOpening(
        context: data!,
        partySize: count,
        memberRefs: [],
        arrivalConfirmed: true,
        reservationChecked: true,
        selectedRule: rule,
      );
      if (!mounted) return;
      if (result.state == OpeningLookupState.confirmed) {
        openedSessionRef = result.receipt!.sessionRef;
        final linked = await memberPanel.currentState?.attachTo(
          openedSessionRef!,
        );
        if (!mounted) return;
        if (linked == true) {
          Navigator.pop(context, true);
          return;
        }
        setState(() => error = 'tableMembersOpeningPartial');
        return;
      }
      setState(() => error = 'openingPending');
    } catch (_) {
      if (mounted) setState(() => error = 'openingPending');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    threshold.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: AlertDialog(
      title: Text('${widget.table.name} · ${t('openingSubmit')}'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (busy && data == null) const LinearProgressIndicator(),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final kind in [
                    'manual',
                    'aa',
                    'minimum_spend',
                    'minimum_people',
                  ])
                    ChoiceChip(
                      label: Text(t('tableKind_$kind')),
                      selected: mode == kind,
                      onSelected: busy || attempted
                          ? null
                          : (_) => setState(() {
                              mode = kind;
                              threshold.text = kind == 'minimum_people'
                                  ? '1'
                                  : '';
                            }),
                    ),
                ],
              ),
              if (mode == 'minimum_spend' || mode == 'minimum_people')
                TextField(
                  controller: threshold,
                  enabled: !busy && !attempted,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: InputDecoration(
                    labelText: t('openingRule_$mode'),
                  ),
                ),
              const SizedBox(height: 16),
              Text(t('guests')),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (
                    var i = 1;
                    i <= widget.table.maximumSeats.clamp(1, 10);
                    i++
                  )
                    SizedBox(
                      width: 76,
                      height: 48,
                      child: OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          backgroundColor: count == i
                              ? const Color(0xffffd451)
                              : null,
                        ),
                        onPressed: busy || attempted
                            ? null
                            : () => setState(() => count = i),
                        child: Text('$i'),
                      ),
                    ),
                ],
              ),
              if (widget.table.maximumSeats > 10)
                TextFormField(
                  initialValue: '$count',
                  enabled: !busy && !attempted,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: InputDecoration(
                    labelText:
                        '${t('guests')} (1–${widget.table.maximumSeats})',
                  ),
                  onChanged: (value) {
                    final n = int.tryParse(value);
                    if (n != null && n > 0 && n <= widget.table.maximumSeats) {
                      setState(() => count = n);
                    }
                  },
                ),
              const SizedBox(height: 16),
              TableMembersPanel(
                key: memberPanel,
                auth: widget.auth,
                language: widget.language,
                tableRef: widget.table.reference,
                enabled: !busy,
              ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    error == 'tableMembersOpeningPartial'
                        ? [
                            '已开台，会员关联未完成，可重扫后完成',
                            'Table opened. Rescan unlinked members, then finish.',
                            '已開台，請重掃未關聯會員',
                            'เปิดโต๊ะแล้ว กรุณาสแกนสมาชิกอีกครั้ง',
                          ][widget.language.index]
                        : t(error!),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: busy
              ? null
              : () => Navigator.pop(context, openedSessionRef != null),
          child: Text(t('cancel')),
        ),
        FilledButton(
          onPressed:
              busy ||
                  (attempted && openedSessionRef == null) ||
                  data == null ||
                  !data!.openingEnabled ||
                  data!.activeSessionRef != null
              ? null
              : open,
          child: Text(
            openedSessionRef == null
                ? t('openingSubmit')
                : ['完成', 'Done', '完成', 'เสร็จสิ้น'][widget.language.index],
          ),
        ),
      ],
    ),
  );
}
