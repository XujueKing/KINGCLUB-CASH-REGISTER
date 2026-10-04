import 'package:flutter/material.dart';

import 'table_snapshot.dart';

class BarCounterStrip extends StatelessWidget {
  const BarCounterStrip({
    super.key,
    required this.table,
    required this.onSeat,
    this.selectedSeat,
    this.seatAmounts = const {},
  });
  final LiveTable table;
  final ValueChanged<int> onSeat;
  final int? selectedSeat;
  final Map<int, int> seatAmounts;

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
                  color: const Color(0xffeef0ed),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                    side: BorderSide(
                      color: selectedSeat == seat
                          ? const Color(0xff40544a)
                          : const Color(0xffaab5ae),
                      width: selectedSeat == seat ? 2 : 1,
                    ),
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
                            style: const TextStyle(
                              fontSize: 26,
                              fontWeight: FontWeight.bold,
                              color: Color(0xff30483b),
                            ),
                          ),
                          const Spacer(),
                          Text(
                            seatAmounts[seat] == null
                                ? '—'
                                : '¥ ${formatCents(seatAmounts[seat]!)}',
                            textAlign: TextAlign.right,
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: Color(0xff526159),
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
        ],
      ),
    ],
  );
}
