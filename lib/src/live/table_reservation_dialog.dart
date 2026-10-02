import 'dart:math';

import 'package:flutter/material.dart';

import '../auth/staff_auth_controller.dart';
import '../network/ccsop_client.dart';
import '../strings.dart';

class TableReservationDialog extends StatefulWidget {
  const TableReservationDialog({
    super.key,
    required this.auth,
    required this.language,
    required this.date,
    required this.tables,
  });
  final StaffAuthController auth;
  final UiLanguage language;
  final DateTime date;
  final List<Map<String, dynamic>> tables;
  @override
  State<TableReservationDialog> createState() => _TableReservationDialogState();
}

class _TableReservationDialogState extends State<TableReservationDialog> {
  final name = TextEditingController(),
      people = TextEditingController(text: '2');
  final time = TextEditingController(text: '18:00'),
      hours = TextEditingController(text: '4');
  String? table, error;
  Map<String, Object>? request;
  bool busy = false;
  String t(String key) => tr(widget.language, key);
  @override
  void initState() {
    super.initState();
    table = widget.tables.firstOrNull?['tableRef'];
  }

  @override
  void dispose() {
    name.dispose();
    people.dispose();
    time.dispose();
    hours.dispose();
    super.dispose();
  }

  Future<void> save() async {
    if (busy) return;
    if (request == null) {
      final parts = time.text.split(':'),
          count = int.tryParse(people.text),
          duration = int.tryParse(hours.text);
      final h = parts.length == 2 ? int.tryParse(parts[0]) : null,
          m = parts.length == 2 ? int.tryParse(parts[1]) : null;
      if (table == null ||
          name.text.trim().isEmpty ||
          count == null ||
          count < 1 ||
          duration == null ||
          duration < 1 ||
          duration > 24 ||
          h == null ||
          h < 0 ||
          h > 23 ||
          m == null ||
          m < 0 ||
          m > 59) {
        setState(() => error = t('reserveFailed'));
        return;
      }
      final start = DateTime(
        widget.date.year,
        widget.date.month,
        widget.date.day,
        h,
        m,
      );
      if (!start.isAfter(DateTime.now())) {
        setState(() => error = t('reserveFailed'));
        return;
      }
      final bytes = List.generate(16, (_) => Random.secure().nextInt(256));
      bytes[6] = (bytes[6] & 15) | 64;
      bytes[8] = (bytes[8] & 63) | 128;
      final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      final ref =
          '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
      request = {
        'action': 'reserve',
        'reservationRef': ref,
        'tableRef': table!,
        'guestName': name.text.trim(),
        'partySize': count,
        'startsAt': start.toUtc().toIso8601String(),
        'endsAt': start
            .add(Duration(hours: duration))
            .toUtc()
            .toIso8601String(),
        'source': 'cashier',
      };
    }
    final identity = widget.auth.session;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final raw = await widget.auth.saveTableReservation(request!);
      if (!mounted || !identical(identity, widget.auth.session)) return;
      final result = (raw as Map<String, dynamic>)['result'];
      if (result['reservationRef'] != request!['reservationRef'] ||
          result['status'] != 'reserved') {
        throw const FormatException();
      }
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        error = t(
          e is CcsopFailure && e.code == 'RESERVATION_TIME_CONFLICT'
              ? 'reserveConflict'
              : 'reserveFailed',
        );
        if (e is CcsopFailure &&
            !e.deliveryUncertain &&
            {
              'RESERVATION_TIME_CONFLICT',
              'RESERVATION_TIME_INVALID',
              'RESERVATION_CAPACITY_INVALID',
            }.contains(e.code)) {
          request = null;
        }
      });
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: AlertDialog(
      title: Text(
        '${t('reserveTable')} · ${widget.date.month}/${widget.date.day}',
      ),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                initialValue: table,
                items: widget.tables
                    .map(
                      (r) => DropdownMenuItem<String>(
                        value: r['tableRef'],
                        child: Text(r['tableName']),
                      ),
                    )
                    .toList(),
                onChanged: busy || request != null
                    ? null
                    : (v) => setState(() => table = v),
              ),
              for (final field in [
                (name, 'reserveGuest'),
                (people, 'reservePeople'),
                (time, 'reserveTime'),
                (hours, 'reserveHours'),
              ])
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: TextField(
                    controller: field.$1,
                    enabled: !busy && request == null,
                    maxLength: field.$1 == name ? 64 : null,
                    decoration: InputDecoration(labelText: t(field.$2)),
                  ),
                ),
              if (error != null)
                Text(error!, style: const TextStyle(color: Colors.red)),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: busy ? null : () => Navigator.pop(context),
          child: Text(t('staffCancelSelection')),
        ),
        FilledButton(
          onPressed: busy || table == null ? null : save,
          child: Text(t(request == null ? 'reserveSave' : 'reserveRetry')),
        ),
      ],
    ),
  );
}
