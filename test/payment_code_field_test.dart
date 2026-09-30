import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/live/payment_code_field.dart';
import 'package:kingclub_cash_register/src/live/provider_payment.dart';

void main() {
  testWidgets(
    'shared code field preserves malformed and oversized scanner input',
    (tester) async {
      final controller = TextEditingController();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PaymentCodeField(
              controller: controller,
              enabled: true,
              label: 'TEST ONLY',
            ),
          ),
        ),
      );
      for (final raw in [
        'TEST_130000000000000000',
        '250000000000000000000000999',
        'KCPAY1:${'A' * 43}EXTRA',
      ]) {
        await tester.enterText(find.byType(TextField), raw);
        expect(controller.text, raw);
        for (final channel in ['wechat', 'alipay', 'member_balance']) {
          expect(validProviderCode(channel, controller.text), false);
        }
      }
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.obscureText, true);
      expect(field.enableIMEPersonalizedLearning, false);
      expect(field.autofillHints, isNull);
      expect(field.inputFormatters, isNull);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );
  testWidgets(
    'scanner done keeps input for explicit review without a payment callback',
    (tester) async {
      final controller = TextEditingController();
      var edits = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PaymentCodeField(
              controller: controller,
              enabled: true,
              label: 'TEST ONLY',
              onChanged: (_) => edits++,
            ),
          ),
        ),
      );
      const value = '130000000000000000';
      await tester.enterText(find.byType(TextField), value);
      final before = edits;
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(edits, before);
      expect(controller.text, value);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );
}
