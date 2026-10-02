import 'package:flutter/material.dart';

import 'table_snapshot.dart';

Color tableStatusColor(LiveTable table) => table.status != 'active'
    ? const Color(0xFF64748B)
    : table.session == null
    ? (table.reservation == null ? Colors.white : const Color(0xFFFACC15))
    : table.session!.status == 'clearing'
    ? const Color(0xFF15803D)
    : table.session!.temporaryHold || table.session!.pendingCents > 0
    ? const Color(0xFFDC2626)
    : const Color(0xFF1D4ED8);
