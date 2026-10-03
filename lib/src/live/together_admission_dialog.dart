import 'dart:async';

import 'package:flutter/material.dart';

import '../auth/staff_auth_controller.dart';
import '../hardware/scanner_input.dart';
import '../strings.dart';
import 'together_admission.dart';

class TogetherAdmissionDialog extends StatefulWidget {
  const TogetherAdmissionDialog({
    super.key,
    required this.auth,
    required this.language,
    this.scannerEvents,
  });
  final StaffAuthController auth;
  final UiLanguage language;
  final Stream<String>? scannerEvents;
  @override
  State<TogetherAdmissionDialog> createState() =>
      _TogetherAdmissionDialogState();
}

class _TogetherAdmissionDialogState extends State<TogetherAdmissionDialog>
    with WidgetsBindingObserver {
  final code = TextEditingController();
  final focus = FocusNode();
  StreamSubscription<String>? scanner;
  Timer? debounce;
  TogetherAdmission? receipt;
  bool busy = false, failed = false, foreground = true;
  int epoch = 0;
  String t(String key) => tr(widget.language, key);
  bool get allowed =>
      widget.auth.session?.permissions.contains('together.admit') == true;
  @override
  void initState() {
    super.initState();
    foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    widget.auth.addListener(invalidate);
    scanner = (widget.scannerEvents ?? ScannerInput.codes).listen(
      (value) {
        if (mounted &&
            foreground &&
            !busy &&
            allowed &&
            ModalRoute.of(context)?.isCurrent == true) {
          unawaited(scan(value.trim()));
        }
      },
      onError: (Object _) {
        if (mounted && foreground) setState(() => failed = true);
      },
    );
  }

  void invalidate() {
    epoch++;
    debounce?.cancel();
    code.clear();
    if (mounted) {
      setState(() {
        receipt = null;
        busy = false;
        failed = false;
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    invalidate();
  }

  Future<void> scan(String value) async {
    if (busy || !foreground || !allowed || value.isEmpty) return;
    debounce?.cancel();
    code.clear();
    setState(() {
      receipt = null;
      failed = false;
    });
    if (!TogetherAdmission.codePattern.hasMatch(value)) {
      setState(() => failed = true);
      return;
    }
    final current = ++epoch, session = widget.auth.session;
    bool valid() =>
        mounted &&
        foreground &&
        current == epoch &&
        identical(session, widget.auth.session);
    setState(() => busy = true);
    try {
      final result = await widget.auth.consumeTogetherAdmission(value);
      if (valid()) setState(() => receipt = result);
    } catch (_) {
      if (valid()) setState(() => failed = true);
    } finally {
      if (valid()) {
        setState(() => busy = false);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (valid() && ModalRoute.of(context)?.isCurrent == true) {
            focus.requestFocus();
          }
        });
      }
    }
  }

  @override
  void dispose() {
    epoch++;
    debounce?.cancel();
    unawaited(scanner?.cancel());
    widget.auth.removeListener(invalidate);
    WidgetsBinding.instance.removeObserver(this);
    code.dispose();
    focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(t('togetherAdmission')),
    content: SizedBox(
      width: 520,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(allowed ? t('togetherAdmissionHelp') : t('staffAuthFailure')),
            const SizedBox(height: 16),
            TextField(
              key: const ValueKey('together-admission-code'),
              controller: code,
              focusNode: focus,
              autofocus: true,
              obscureText: true,
              enabled: allowed && foreground && !busy,
              keyboardType: TextInputType.none,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.qr_code_scanner),
              ),
              onSubmitted: (value) => unawaited(scan(value.trim())),
              onEditingComplete: () {},
              onChanged: (value) {
                debounce?.cancel();
                setState(() {
                  receipt = null;
                  failed = false;
                });
                if (TogetherAdmission.codePattern.hasMatch(value.trim())) {
                  debounce = Timer(
                    const Duration(milliseconds: 150),
                    () => unawaited(scan(value.trim())),
                  );
                }
              },
            ),
            const SizedBox(height: 16),
            if (busy) const LinearProgressIndicator(),
            if (failed) Text(t('togetherAdmissionFailed')),
            if (receipt != null) ...[
              Text(
                t(
                  receipt!.replayed
                      ? 'togetherAdmissionRepeated'
                      : 'togetherAdmissionSuccess',
                ),
                style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Text(receipt!.bookingRef),
              Text(receipt!.usedAt.toLocal().toString()),
            ],
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(t('togetherAdmissionClose')),
      ),
    ],
  );
}
