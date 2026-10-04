import 'dart:convert';

import 'package:flutter/material.dart';

import '../auth/staff_auth_controller.dart';
import '../strings.dart';
import 'table_snapshot.dart';

/// Neutral counter strip. Member identity uses the existing table association.
class BarCounterStrip extends StatefulWidget {
  const BarCounterStrip({
    super.key,
    required this.table,
    required this.auth,
    required this.language,
    required this.revision,
    required this.onEnter,
    required this.onMembers,
  });
  final LiveTable table;
  final StaffAuthController auth;
  final UiLanguage language;
  final DateTime revision;
  final VoidCallback onEnter, onMembers;
  @override
  State<BarCounterStrip> createState() => _BarCounterStripState();
}

class _BarCounterStripState extends State<BarCounterStrip> {
  List<Map<String, String?>> members = [];
  int epoch = 0;
  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void didUpdateWidget(covariant BarCounterStrip old) {
    super.didUpdateWidget(old);
    if (old.table.session?.reference != widget.table.session?.reference ||
        old.auth != widget.auth)
      members = [];
    if (old.revision != widget.revision ||
        old.table.session?.reference != widget.table.session?.reference)
      load();
  }

  Future<void> load() async {
    final generation = ++epoch;
    final session = widget.table.session;
    if (session == null) return;
    try {
      final rows = await widget.auth.tableMembers(
        tableRef: widget.table.reference,
        sessionRef: session.reference,
      );
      if (mounted && generation == epoch) setState(() => members = rows);
    } catch (_) {
      /* Keep the current session's last successful avatars. */
    }
  }

  Widget avatar(Map<String, String?>? member) {
    try {
      final raw = member?['avatarBase64'];
      if (raw != null && raw.length < 100000)
        return Image.memory(
          base64Decode(raw),
          fit: BoxFit.cover,
          gaplessPlayback: true,
          errorBuilder: (_, __, ___) =>
              const Icon(Icons.person, color: Color(0xff8b9591)),
        );
    } catch (_) {}
    return Icon(
      Icons.person,
      color: member == null ? const Color(0xffb3bab7) : const Color(0xff566a60),
    );
  }

  @override
  Widget build(BuildContext context) => Material(
    color: const Color(0xffeef0ed),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(10),
      side: const BorderSide(color: Color(0xffaab5ae)),
    ),
    child: InkWell(
      onTap: widget.onEnter,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        child: SizedBox(
          height: 112,
          child: Row(
            children: [
              SizedBox(
                width: 64,
                child: Text(
                  widget.table.name,
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              ...List.generate(widget.table.maximumSeats, (index) {
                final member = index < members.length ? members[index] : null;
                final label = member == null
                    ? '${index + 1}'
                    : (member['nickname']?.isNotEmpty == true
                          ? member['nickname']!
                          : member['userAccount']!);
                return Expanded(
                  child: InkWell(
                    onTap: widget.onMembers,
                    borderRadius: BorderRadius.circular(8),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: SizedBox(
                            width: 52,
                            height: 52,
                            child: ColoredBox(
                              color: const Color(0xffdce1dd),
                              child: avatar(member),
                            ),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 11,
                            color: Color(0xff526159),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }),
              const SizedBox(width: 8),
              const Icon(Icons.chevron_right, color: Color(0xff526159)),
            ],
          ),
        ),
      ),
    ),
  );
}
