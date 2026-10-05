import 'package:flutter/material.dart';

import 'table_snapshot.dart';

Color tableStatusColor(LiveTable table) => table.status != 'active'
    ? const Color(0xFF64748B)
    : table.session == null
    ? (table.reservation == null ? Colors.white : const Color(0xFFFACC15))
    : table.isBarSeat &&
          !table.session!.hasConsumption &&
          table.session!.linkedMembers == 0
    ? Colors.white
    : table.session!.status == 'clearing'
    ? const Color(0xFF15803D)
    : table.session!.temporaryHold || table.session!.pendingCents > 0
    ? const Color(0xFFDC2626)
    : table.session!.unservedQuantity > 0
    ? const Color(0xFFAD2885)
    : const Color(0xFF1D4ED8);

LinearGradient tableStatusGradient(Color color) {
  if (color.toARGB32() == 0xFFEA580C || color.toARGB32() == 0xFFDC2626) {
    return LinearGradient(colors: [color, color]);
  }
  final start = switch (color.toARGB32()) {
    0xFFFACC15 => const Color(0xFFFDE047),
    0xFF15803D => const Color(0xFF22A65A),
    0xFFDC2626 => const Color(0xFFF05252),
    0xFF1D4ED8 => const Color(0xFF3B82F6),
    0xFF64748B => const Color(0xFF8492A6),
    0xFF64716B => const Color(0xFF64716B),
    _ => color,
  };
  return LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [start, color == Colors.white ? const Color(0xFFF0F3F1) : color],
  );
}
