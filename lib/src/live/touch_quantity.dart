import 'package:flutter/material.dart';

/// Touch-only count selection; the server still checks the available quantity.
class TouchQuantity extends StatelessWidget {
  const TouchQuantity({
    super.key,
    required this.controller,
    required this.maximum,
    required this.label,
    required this.onChanged,
    this.enabled = true,
  });
  final TextEditingController controller;
  final int maximum;
  final String label;
  final VoidCallback onChanged;
  final bool enabled;
  @override
  Widget build(BuildContext context) {
    final count = int.tryParse(controller.text) ?? 1;
    void set(int n) {
      controller.text = '$n';
      onChanged();
    }

    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 4,
      runSpacing: 4,
      children: [
        Text(label),
        const SizedBox(width: 16),
        IconButton(
          key: const ValueKey('quantity-minus'),
          onPressed: enabled && count > 1 ? () => set(count - 1) : null,
          icon: const Icon(Icons.remove_circle_outline),
          color: const Color(0xffd99a00),
          iconSize: 36,
        ),
        SizedBox(
          width: 56,
          child: Text(
            '$count',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
          ),
        ),
        IconButton(
          key: const ValueKey('quantity-plus'),
          onPressed: enabled && count < maximum ? () => set(count + 1) : null,
          icon: const Icon(Icons.add_circle),
          color: const Color(0xffffc107),
          iconSize: 36,
        ),
        TextButton(
          onPressed: enabled && maximum > 0 ? () => set(maximum) : null,
          child: Text('/ $maximum'),
        ),
      ],
    );
  }
}
