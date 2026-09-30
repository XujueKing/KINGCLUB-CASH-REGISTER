import 'package:flutter/material.dart';

/// Shared input only. Enter finishes a scanner input, never authorizes payment.
/// Do not strip non-digits or truncate a scanned value into a different code:
/// the selected channel's validator must reject malformed input before sending.
/// The owning transaction clears this controller on scope/lifecycle changes.
class PaymentCodeField extends StatelessWidget {
  const PaymentCodeField({
    super.key,
    required this.controller,
    required this.enabled,
    required this.label,
    this.onChanged,
  });
  final TextEditingController controller;
  final bool enabled;
  final String label;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) => TextField(
    controller: controller,
    enabled: enabled,
    obscureText: true,
    enableSuggestions: false,
    autocorrect: false,
    enableIMEPersonalizedLearning: false,
    autofillHints: null,
    keyboardType: TextInputType.visiblePassword,
    textInputAction: TextInputAction.done,
    onEditingComplete: () {},
    onSubmitted: (_) {},
    onChanged: onChanged,
    decoration: InputDecoration(labelText: label),
  );
}
