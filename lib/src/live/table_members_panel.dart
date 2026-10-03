import 'dart:async';

import 'package:flutter/material.dart';

import '../auth/staff_auth_controller.dart';
import '../hardware/scanner_input.dart';
import '../strings.dart';
import 'member_identity.dart';

class TableMembersPanel extends StatefulWidget {
  const TableMembersPanel({
    super.key,
    required this.auth,
    required this.language,
    required this.tableRef,
    this.sessionRef,
    this.enabled = true,
  });
  final StaffAuthController auth;
  final UiLanguage language;
  final String tableRef;
  final String? sessionRef;
  final bool enabled;
  @override
  TableMembersPanelState createState() => TableMembersPanelState();
}

class TableMembersPanelState extends State<TableMembersPanel>
    with WidgetsBindingObserver {
  StreamSubscription<String>? scans;
  String? attachedSession;
  bool busy = false, failed = false, foreground = true;
  int epoch = 0;
  List<Map<String, String?>> members = [];
  final pending = <String, ({String code, String name})>{};
  String words(List<String> values) => values[widget.language.index];
  @override
  void initState() {
    super.initState();
    attachedSession = widget.sessionRef;
    WidgetsBinding.instance.addObserver(this);
    widget.auth.addListener(identityChanged);
    scans = ScannerInput.codes.listen((code) {
      if (mounted &&
          foreground &&
          widget.enabled &&
          !busy &&
          ModalRoute.of(context)?.isCurrent == true &&
          MemberIdentity.codePattern.hasMatch(code)) {
        unawaited(scan(code));
      }
    });
    if (attachedSession != null) unawaited(load());
  }

  void identityChanged() {
    epoch++;
    pending.clear();
    if (mounted) {
      setState(() {
        members = [];
        failed = true;
        busy = false;
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    if (!foreground) {
      epoch++;
      pending.clear();
      if (mounted) setState(() => busy = false);
    } else if (attachedSession != null) {
      unawaited(load());
    }
  }

  @override
  void dispose() {
    epoch++;
    pending.clear();
    scans?.cancel();
    widget.auth.removeListener(identityChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> load() async {
    final generation = ++epoch;
    try {
      final rows = await widget.auth.tableMembers(
        tableRef: widget.tableRef,
        sessionRef: attachedSession!,
      );
      if (mounted && epoch == generation) setState(() => members = rows);
    } catch (_) {
      if (mounted && epoch == generation) setState(() => failed = true);
    }
  }

  Future<void> scan(String code) async {
    if (busy || !foreground || !widget.enabled) return;
    final generation = ++epoch;
    setState(() {
      busy = true;
      failed = false;
    });
    try {
      if (attachedSession == null) {
        final member = await widget.auth.readMemberIdentity(code);
        if (!mounted || generation != epoch) return;
        pending[member.memberRef] = (
          code: code,
          name: member.nickname ?? member.memberRef,
        );
      } else {
        final rows = await widget.auth.tableMembers(
          tableRef: widget.tableRef,
          sessionRef: attachedSession!,
          identityCode: code,
        );
        if (!mounted || generation != epoch) return;
        members = rows;
        for (final member in members) {
          pending.remove(member['userAccount']);
        }
      }
    } catch (_) {
      if (mounted && generation == epoch) failed = true;
    } finally {
      if (mounted && generation == epoch) setState(() => busy = false);
    }
  }

  /// Opening has already committed. Retrying here never opens another session.
  Future<bool> attachTo(String sessionRef) async {
    if (busy || !foreground) return false;
    attachedSession = sessionRef;
    final generation = ++epoch;
    setState(() {
      busy = true;
      failed = false;
    });
    try {
      for (final entry in pending.entries.toList()) {
        final rows = await widget.auth.tableMembers(
          tableRef: widget.tableRef,
          sessionRef: sessionRef,
          identityCode: entry.value.code,
        );
        if (!mounted || generation != epoch) return false;
        members = rows;
        pending.remove(entry.key);
      }
      return true;
    } catch (_) {
      if (mounted && generation == epoch) failed = true;
      return false;
    } finally {
      if (mounted && generation == epoch) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          const Icon(Icons.qr_code_scanner, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              words([
                '扫码关联会员',
                'Scan to link members',
                '掃碼關聯會員',
                'สแกนเพื่อเชื่อมโยงสมาชิก',
              ]),
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          if (busy)
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
        ],
      ),
      const SizedBox(height: 6),
      Text(
        words([
          '可连续扫码，无需点击输入框',
          'Scan members consecutively; no input field needed',
          '可連續掃碼，無需點擊輸入框',
          'สแกนต่อเนื่องได้ ไม่ต้องแตะช่องกรอก',
        ]),
        style: const TextStyle(fontSize: 12),
      ),
      if (members.isNotEmpty || pending.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              for (final member in members)
                Chip(
                  avatar: const Icon(Icons.check, size: 16),
                  label: Text(member['nickname'] ?? member['userAccount']!),
                ),
              for (final entry in pending.entries)
                Chip(
                  label: Text(entry.value.name),
                  onDeleted: attachedSession == null && !busy
                      ? () => setState(() => pending.remove(entry.key))
                      : null,
                ),
            ],
          ),
        ),
      if (failed)
        Text(
          words([
            attachedSession == null ? '识别失败，请刷新会员码重扫' : '会员未关联成功，请刷新会员码重扫',
            'Could not link. Refresh the member code and scan again.',
            '請刷新會員碼重掃',
            'กรุณารีเฟรชรหัสสมาชิกแล้วสแกนอีกครั้ง',
          ]),
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
    ],
  );
}

class TableMembersButton extends StatelessWidget {
  const TableMembersButton({
    super.key,
    required this.auth,
    required this.language,
    required this.tableRef,
    required this.sessionRef,
  });
  final StaffAuthController auth;
  final UiLanguage language;
  final String tableRef, sessionRef;
  @override
  Widget build(BuildContext context) => TextButton.icon(
    key: const ValueKey('table-members-open'),
    style: TextButton.styleFrom(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      minimumSize: const Size(0, 32),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    ),
    onPressed: () => showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(
          [
            '关联会员',
            'Linked members',
            '關聯會員',
            'สมาชิกที่เชื่อมโยง',
          ][language.index],
        ),
        content: SizedBox(
          width: 440,
          child: SingleChildScrollView(
            child: TableMembersPanel(
              auth: auth,
              language: language,
              tableRef: tableRef,
              sessionRef: sessionRef,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(['完成', 'Done', '完成', 'เสร็จสิ้น'][language.index]),
          ),
        ],
      ),
    ),
    icon: const Icon(Icons.qr_code_scanner, size: 16),
    label: Text(
      ['关联会员', 'Members', '關聯會員', 'สมาชิก'][language.index],
      style: const TextStyle(fontSize: 11),
    ),
  );
}
