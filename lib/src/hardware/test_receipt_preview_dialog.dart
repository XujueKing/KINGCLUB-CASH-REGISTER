import 'dart:async';

import 'package:flutter/material.dart';

import '../strings.dart';
import 'test_receipt_renderer.dart';

typedef TestReceiptRender = Future<RenderedTestReceipt> Function({
  required UiLanguage language,
  required int widthDots,
});

/// Local-only diagnostic preview. Deliberately has no transport or print action.
class TestReceiptPreviewDialog extends StatefulWidget {
  const TestReceiptPreviewDialog({
    super.key,
    required this.language,
    this.render,
  });
  final UiLanguage language;
  final TestReceiptRender? render;
  @override
  State<TestReceiptPreviewDialog> createState() =>
      _TestReceiptPreviewDialogState();
}

class _TestReceiptPreviewDialogState extends State<TestReceiptPreviewDialog> {
  late UiLanguage language;
  int width = 576;
  bool busy = false, failed = false;
  RenderedTestReceipt? receipt;
  String t(String key) => tr(language, key);

  @override
  void initState() {
    super.initState();
    language = widget.language;
    unawaited(render());
  }

  Future<void> render() async {
    if (!mounted || busy) return;
    setState(() {
      busy = true;
      failed = false;
      receipt = null;
    });
    try {
      final next = await (widget.render ?? renderTestReceipt)(
        language: language,
        widthDots: width,
      );
      if (mounted) setState(() => receipt = next);
    } catch (_) {
      if (mounted) setState(() => failed = true);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: SizedBox(
        width: 900,
        height: 640,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      t('printerTestPreview'),
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  TextButton(
                    key: const ValueKey('test-receipt-close'),
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(t('printerInspectClose')),
                  ),
                ],
              ),
              Text(t('printerTestPreviewNotice')),
              Wrap(
                spacing: 24,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  DropdownButton<UiLanguage>(
                    key: const ValueKey('test-receipt-language'),
                    value: language,
                    items: [
                      for (final item in UiLanguage.values)
                        DropdownMenuItem(
                          value: item,
                          child: Text(
                            const [
                              '简体中文',
                              'English',
                              '繁體中文',
                              'ไทย',
                            ][item.index],
                          ),
                        ),
                    ],
                    onChanged: busy
                        ? null
                        : (value) {
                            if (value == null || value == language) return;
                            setState(() => language = value);
                            unawaited(render());
                          },
                  ),
                  Text(t('printerTestDotWidth')),
                  DropdownButton<int>(
                    key: const ValueKey('test-receipt-width'),
                    value: width,
                    items: [
                      for (final value in [384, 512, 576])
                        DropdownMenuItem(value: value, child: Text('$value')),
                    ],
                    onChanged: busy
                        ? null
                        : (value) {
                            if (value == null || value == width) return;
                            setState(() => width = value);
                            unawaited(render());
                          },
                  ),
                ],
              ),
              if (busy) const LinearProgressIndicator(),
              if (failed)
                Text(
                  t('printerTestPreviewFailed'),
                  key: const ValueKey('test-receipt-error'),
                ),
              if (failed)
                TextButton(
                  key: const ValueKey('test-receipt-retry'),
                  onPressed: busy ? null : () => unawaited(render()),
                  child: Text(t('printerInspectRefresh')),
                ),
              Expanded(
                child: ColoredBox(
                  color: const Color(0xffdddddd),
                  child: Center(
                    child: receipt == null
                        ? const SizedBox()
                        : Image.memory(
                            receipt!.png,
                            key: const ValueKey('test-receipt-image'),
                            fit: BoxFit.contain,
                            filterQuality: FilterQuality.none,
                            gaplessPlayback: false,
                            semanticLabel: t('printerTestTitle'),
                          ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
