import 'package:flutter/material.dart';

/// Mirrors the cabinet: higher row numbers appear above the bottom shelf.
class WineLocationPicker extends StatelessWidget {
  const WineLocationPicker({
    super.key,
    required this.locations,
    required this.selected,
    required this.onSelected,
  });
  final List<String> locations;
  final String? selected;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    final pattern = RegExp(r'^([A-Z])([1-9][0-9]*)-([1-9][0-9]*)$');
    final rows = <String, List<String>>{};
    for (final code in locations) {
      final match = pattern.firstMatch(code);
      if (match == null) continue;
      rows.putIfAbsent('${match[1]}${match[2]}', () => []).add(code);
    }
    final keys = rows.keys.toList()
      ..sort((a, b) {
        final cabinet = a[0].compareTo(b[0]);
        return cabinet != 0
            ? cabinet
            : int.parse(b.substring(1)).compareTo(int.parse(a.substring(1)));
      });
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final key in keys)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(
              children: [
                for (final code
                    in (rows[key]!..sort(
                      (a, b) =>
                          int.parse(a.split('-').last)
                              .compareTo(int.parse(b.split('-').last)),
                    )))
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 3),
                      child: OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size(0, 36),
                          padding: EdgeInsets.zero,
                          backgroundColor: selected == code
                              ? Theme.of(context).colorScheme.primaryContainer
                              : null,
                          side: BorderSide(
                            color: selected == code
                                ? Theme.of(context).colorScheme.primary
                                : Colors.black26,
                          ),
                        ),
                        onPressed: () => onSelected(code),
                        child: Text(code),
                      ),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}
