import 'dart:async';

import 'package:flutter/material.dart';

import '../auth/staff_auth_controller.dart';
import '../strings.dart';
import 'member_identity.dart';
import 'member_identity_panel.dart';
import 'order_context_snapshot.dart';
import 'seating_command.dart';

/// Same identity entry for membership and a selected table, with original-request recovery.
class MemberSeatingPanel extends StatefulWidget {
  const MemberSeatingPanel({
    super.key,
    required this.auth,
    required this.language,
    this.orderContext,
    this.onBack,
    this.onSeated,
  });
  final StaffAuthController auth;
  final UiLanguage language;
  final OrderContextSnapshot? orderContext;
  final VoidCallback? onBack, onSeated;
  @override
  State<MemberSeatingPanel> createState() => _MemberSeatingPanelState();
}

class _MemberSeatingPanelState extends State<MemberSeatingPanel>
    with WidgetsBindingObserver {
  List<PendingSeating> pending = [];
  int epoch = 0, scanGeneration = 0;
  bool busy = false, failed = false, foreground = true;
  String? outcome;
  String t(String key) => tr(widget.language, key);
  bool get canSeat =>
      widget.auth.session?.permissions.contains('table.open') == true &&
      widget.auth.session?.permissions.contains('orders.create') == true;
  @override
  void initState() {
    super.initState();
    foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    widget.auth.addListener(changed);
    WidgetsBinding.instance.addObserver(this);
    unawaited(load());
  }

  void changed() {
    ++epoch;
    ++scanGeneration;
    setState(() {
      pending = [];
      outcome = null;
      failed = false;
      busy = false;
    });
    if (foreground) unawaited(load());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    changed();
  }

  @override
  void didUpdateWidget(covariant MemberSeatingPanel old) {
    super.didUpdateWidget(old);
    if (old.auth != widget.auth) {
      old.auth.removeListener(changed);
      widget.auth.addListener(changed);
    }
    if (old.auth != widget.auth || old.orderContext != widget.orderContext) {
      changed();
    }
  }

  Future<void> load() async {
    if (!foreground || !canSeat) return;
    final e = ++epoch, session = widget.auth.session;
    setState(() {
      busy = true;
      failed = false;
    });
    try {
      final rows = await widget.auth.pendingSeating();
      if (!mounted ||
          e != epoch ||
          !foreground ||
          !identical(session, widget.auth.session)) {
        return;
      }
      setState(() {
        pending = rows;
        busy = false;
      });
    } catch (_) {
      if (mounted && e == epoch) {
        setState(() {
          failed = true;
          busy = false;
          pending = [];
        });
      }
    }
  }

  Future<void> completed(SeatingResult? result) async {
    if (!mounted || !foreground) return;
    setState(() {
      scanGeneration++;
      outcome = result == null
          ? 'seatingUnknown'
          : result.confirmed
          ? 'seatingConfirmed'
          : 'seatingCancelled';
    });
    await load();
    if (mounted && foreground && result?.confirmed == true) {
      widget.onSeated?.call();
    }
  }

  Future<void> recover(PendingSeating command, {bool cancel = false}) async {
    if (busy || !foreground) return;
    final session = widget.auth.session, initial = epoch;
    if (cancel) {
      final agreed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(t('seatingCancel')),
          content: Text(
            '${command.tableName} · ${command.memberName ?? t('orderMemberUnnamed')}\n${t('seatingCancelNotice')}',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(t('seatingKeep')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(t('seatingCancel')),
            ),
          ],
        ),
      );
      if (agreed != true ||
          !mounted ||
          !foreground ||
          epoch != initial ||
          !identical(session, widget.auth.session)) {
        return;
      }
    }
    final e = ++epoch;
    bool current() =>
        mounted &&
        foreground &&
        epoch == e &&
        identical(session, widget.auth.session);
    setState(() {
      busy = true;
      outcome = null;
      scanGeneration++;
    });
    try {
      final result = await widget.auth.recoverSeating(
        command.requestId,
        cancelUnsent: cancel,
        stillCurrent: current,
      );
      if (!current()) return;
      if (result.terminal) {
        await completed(result);
      } else {
        setState(() {
          busy = false;
          outcome = 'seatingNotObserved';
        });
      }
    } catch (_) {
      if (current()) {
        setState(() {
          busy = false;
          outcome = 'seatingUnknown';
        });
      }
    }
  }

  @override
  void dispose() {
    epoch++;
    widget.auth.removeListener(changed);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Widget seatingActions(
    MemberIdentity member,
    String code,
    bool Function() current,
  ) {
    final owner = widget.auth.session, target = widget.orderContext!;
    return _SeatingConfirmation(
      key: ValueKey(member),
      auth: widget.auth,
      language: widget.language,
      orderContext: target,
      member: member,
      code: code,
      stillCurrent: current,
      blocked: busy || failed,
      onFinished: (result) async {
        if (mounted &&
            identical(owner, widget.auth.session) &&
            identical(target, widget.orderContext)) {
          await completed(result);
        }
      },
    );
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      if (widget.orderContext != null)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Row(
            children: [
              IconButton(
                tooltip: t('ordersBack'),
                onPressed: widget.onBack,
                icon: const Icon(Icons.arrow_back),
              ),
              Expanded(
                child: Text(
                  '${widget.orderContext!.tableName} · ${t('seatingTitle')}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
      if (busy) const LinearProgressIndicator(),
      if (failed)
        ListTile(
          title: Text(t('seatingRecoveryFailed')),
          trailing: IconButton(
            onPressed: () => unawaited(load()),
            icon: const Icon(Icons.refresh),
          ),
        ),
      if (outcome != null)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Text(t(outcome!)),
        ),
      if (pending.isNotEmpty)
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 180),
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final command in pending)
                ListTile(
                  key: ValueKey('seating-pending-${command.requestId}'),
                  title: Text(
                    '${command.tableName} · ${command.memberName ?? t('orderMemberUnnamed')}',
                  ),
                  subtitle: Text(t('seatingPending')),
                  trailing: Wrap(
                    spacing: 8,
                    children: [
                      OutlinedButton(
                        key: ValueKey('seating-lookup-${command.requestId}'),
                        onPressed: busy
                            ? null
                            : () => unawaited(recover(command)),
                        child: Text(t('seatingLookup')),
                      ),
                      TextButton(
                        key: ValueKey('seating-cancel-${command.requestId}'),
                        onPressed: busy
                            ? null
                            : () => unawaited(recover(command, cancel: true)),
                        child: Text(t('seatingCancel')),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      Expanded(
        child: MemberIdentityPanel(
          key: ValueKey(scanGeneration),
          auth: widget.auth,
          language: widget.language,
          actionsBuilder: widget.orderContext == null || !canSeat
              ? null
              : seatingActions,
        ),
      ),
    ],
  );
}

class _SeatingConfirmation extends StatefulWidget {
  const _SeatingConfirmation({
    super.key,
    required this.auth,
    required this.language,
    required this.orderContext,
    required this.member,
    required this.code,
    required this.stillCurrent,
    required this.blocked,
    required this.onFinished,
  });
  final StaffAuthController auth;
  final UiLanguage language;
  final OrderContextSnapshot orderContext;
  final MemberIdentity member;
  final String code;
  final bool Function() stillCurrent;
  final bool blocked;
  final Future<void> Function(SeatingResult?) onFinished;
  @override
  State<_SeatingConfirmation> createState() => _SeatingConfirmationState();
}

class _SeatingConfirmationState extends State<_SeatingConfirmation> {
  bool busy = false;
  String t(String key) => tr(widget.language, key);
  Future<void> confirm() async {
    if (busy || widget.blocked || !widget.stillCurrent()) {
      return;
    }
    final session = widget.auth.session,
        auth = widget.auth,
        finished = widget.onFinished;
    if (session == null) return;
    setState(() => busy = true);
    bool current() =>
        mounted &&
        !widget.blocked &&
        widget.stillCurrent() &&
        identical(session, widget.auth.session);
    SeatingResult? result;
    try {
      final command = PendingSeating.prepare(
        session: session,
        context: widget.orderContext,
        member: widget.member,
        now: DateTime.now(),
        // The employee confirms this member and table with the single seating action.
        // Keep the existing server contract; do not auto-submit on scan.
        arrivalConfirmed: true,
        reservationChecked: true,
      );
      result = await widget.auth.confirmSeating(
        command,
        widget.code,
        confirmed: true,
        stillCurrent: current,
      );
    } catch (_) {
      /* Original command remains recoverable if it was admitted. */
    }
    if (identical(session, auth.session)) {
      await finished(result);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const SizedBox(height: 8),
      FilledButton(
        key: const ValueKey('seating-confirm'),
        onPressed: busy || widget.blocked ? null : () => unawaited(confirm()),
        child: Text(
          '${t('seatingConfirm')} · ${widget.orderContext.tableName}',
        ),
      ),
    ],
  );
}
