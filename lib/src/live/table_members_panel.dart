import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

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
    this.onLinked,
  });
  final StaffAuthController auth;
  final UiLanguage language;
  final String tableRef;
  final String? sessionRef;
  final bool enabled;
  final VoidCallback? onLinked;
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
        if (foreground && ModalRoute.of(context)?.isCurrent == true) {
          widget.onLinked?.call();
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
          widget.onLinked == null ? '可连续扫码，无需点击输入框' : '请扫会员码，成功后自动关闭',
          widget.onLinked == null
              ? 'Scan members consecutively; no input field needed'
              : 'Scan a member code; closes automatically on success',
          widget.onLinked == null ? '可連續掃碼，無需點擊輸入框' : '請掃會員碼，成功後自動關閉',
          widget.onLinked == null
              ? 'สแกนต่อเนื่องได้ ไม่ต้องแตะช่องกรอก'
              : 'สแกนรหัสสมาชิก ปิดอัตโนมัติเมื่อสำเร็จ',
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

class TableMembersButton extends StatefulWidget {
  const TableMembersButton({
    super.key,
    required this.auth,
    required this.language,
    required this.tableRef,
    required this.sessionRef,
    this.revision = 0,
  });
  final StaffAuthController auth;
  final UiLanguage language;
  final String tableRef, sessionRef;
  final int revision;
  @override
  State<TableMembersButton> createState() => _TableMembersButtonState();
}

class _TableMembersButtonState extends State<TableMembersButton> {
  List<Map<String, String?>> members = [];
  Uint8List? avatar;
  int epoch = 0;
  @override
  void initState() {
    super.initState();
    widget.auth.addListener(reset);
    unawaited(load());
  }

  void reset() {
    epoch++;
    if (mounted) {
      setState(() {
        members = [];
        avatar = null;
      });
    }
  }

  @override
  void didUpdateWidget(covariant TableMembersButton old) {
    super.didUpdateWidget(old);
    final changed =
        old.auth != widget.auth ||
        old.tableRef != widget.tableRef ||
        old.sessionRef != widget.sessionRef;
    if (old.auth != widget.auth) {
      old.auth.removeListener(reset);
      widget.auth.addListener(reset);
    }
    if (changed) {
      epoch++;
      members = [];
      avatar = null;
    }
    if (changed || old.revision != widget.revision) unawaited(load());
  }

  Future<void> load() async {
    final generation = ++epoch;
    try {
      final rows = await widget.auth.tableMembers(
        tableRef: widget.tableRef,
        sessionRef: widget.sessionRef,
      );
      if (!mounted || generation != epoch) return;
      Uint8List? bytes;
      try {
        final raw = rows.isEmpty ? null : rows.first['avatarBase64'];
        if (raw != null) bytes = base64Decode(raw);
      } catch (_) {}
      setState(() {
        members = rows;
        avatar = bytes;
      });
    } catch (_) {
      /* Retain this session's last successful image without flashing. */
    }
  }

  @override
  void dispose() {
    epoch++;
    widget.auth.removeListener(reset);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IconButton(
    key: const ValueKey('table-members-open'),
    tooltip: [
      '关联会员',
      'Linked members',
      '關聯會員',
      'สมาชิกที่เชื่อมโยง',
    ][widget.language.index],
    onPressed: () async {
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(
            [
              '关联会员',
              'Linked members',
              '關聯會員',
              'สมาชิกที่เชื่อมโยง',
            ][widget.language.index],
          ),
          content: SizedBox(
            width: 440,
            child: SingleChildScrollView(
              child: TableMembersPanel(
                auth: widget.auth,
                language: widget.language,
                tableRef: widget.tableRef,
                sessionRef: widget.sessionRef,
                onLinked: () => Navigator.pop(dialogContext),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(['关闭', 'Close', '關閉', 'ปิด'][widget.language.index]),
            ),
          ],
        ),
      );
      if (mounted) await load();
    },
    icon: Badge(
      isLabelVisible: members.length > 1,
      label: Text('${members.length}'),
      child: ClipOval(
        child: SizedBox(
          width: 32,
          height: 32,
          child: ColoredBox(
            color: members.isEmpty
                ? const Color(0xffdedede)
                : const Color(0xffd5e5df),
            child: avatar == null
                ? fallback()
                : Image.memory(
                    avatar!,
                    gaplessPlayback: true,
                    fit: BoxFit.cover,
                    errorBuilder: (_, error, stack) => fallback(),
                  ),
          ),
        ),
      ),
    ),
  );
  Widget fallback() => members.isEmpty
      ? const Icon(Icons.person, color: Color(0xff9e9e9e), size: 23)
      : Center(
          child: Text(
            (members.first['nickname'] ?? members.first['userAccount'] ?? '')
                .characters
                .take(1)
                .toString(),
            style: const TextStyle(
              color: Color(0xff204c40),
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
        );
}
