import 'package:flutter/material.dart';

import 'table_snapshot.dart';
import 'table_status_color.dart';

class BarCounterStrip extends StatelessWidget {
  const BarCounterStrip({
    super.key,
    required this.table,
    required this.onSeat,
    this.selectedSeat,
    this.seatAmounts = const {},
    this.seatTables = const {},
  });
  final LiveTable table;
  final ValueChanged<int> onSeat;
  final int? selectedSeat;
  final Map<int, int> seatAmounts;
  final Map<int, LiveTable> seatTables;
  Color seatColor(int seat) => seatTables[seat] == null
      ? Colors.white
      : tableStatusColor(seatTables[seat]!);
  Color seatTextColor(int seat) =>
      seatColor(seat) == Colors.white ||
          seatColor(seat) == const Color(0xfffacc15)
      ? const Color(0xff263c30)
      : Colors.white;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(
        table.name,
        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
      ),
      const SizedBox(height: 8),
      Row(
        children: [
          for (var seat = 1; seat <= table.maximumSeats; seat++) ...[
            if (seat > 1) const SizedBox(width: 10),
            Expanded(
              child: AspectRatio(
                aspectRatio: 1,
                child: Material(
                  color: seatColor(seat),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                    side: BorderSide(
                      color: selectedSeat == seat
                          ? const Color(0xff40544a)
                          : const Color(0xffaab5ae),
                      width: selectedSeat == seat ? 2 : 1,
                    ),
                  ),
                  child: Ink(
                    decoration: BoxDecoration(
                      gradient: tableStatusGradient(seatColor(seat)),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: InkWell(
                      key: ValueKey('bar-seat-$seat'),
                      onTap: () => onSeat(seat),
                      borderRadius: BorderRadius.circular(10),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              'B$seat',
                              style: TextStyle(
                                fontSize: 26,
                                fontWeight: FontWeight.bold,
                                color: seatTextColor(seat),
                              ),
                            ),
                            const Spacer(),
                            Text(
                              seatAmounts[seat] == null
                                  ? '—'
                                  : '¥ ${formatCents(seatAmounts[seat]!)}',
                              textAlign: TextAlign.right,
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: seatTextColor(seat),
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
        ],
      ),
    ],
  );
}
