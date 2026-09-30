import 'dart:async';

import 'package:flutter/material.dart';

import '../auth/staff_auth_controller.dart';
import '../strings.dart';
import 'member_identity.dart';

class MemberIdentityPanel extends StatefulWidget {
  const MemberIdentityPanel({
    super.key,
    required this.auth,
    required this.language,
    this.actionsBuilder,
  });
  final StaffAuthController auth;
  final UiLanguage language;
  final Widget Function(
    MemberIdentity member,
    String code,
    bool Function() stillCurrent,
  )?
  actionsBuilder;
  @override
  State<MemberIdentityPanel> createState() => _MemberIdentityPanelState();
}

class _MemberIdentityPanelState extends State<MemberIdentityPanel>
    with WidgetsBindingObserver {
  final code = TextEditingController();
  Timer? expiry;
  MemberIdentity? identity;
  String? identityCode;
  Stopwatch? validity;
  int epoch = 0;
  bool busy = false, failed = false, foreground = true;
  String t(String key) => tr(widget.language, key);
  @override
  void initState() {
    super.initState();
    foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    widget.auth.addListener(invalidate);
    WidgetsBinding.instance.addObserver(this);
  }

  void invalidate() {
    epoch++;
    expiry?.cancel();
    code.clear();
    identityCode = null;
    validity = null;
    if (mounted) {
      setState(() {
        identity = null;
        busy = false;
        failed = false;
      });
    }
  }

  @override
  void didUpdateWidget(covariant MemberIdentityPanel old) {
    super.didUpdateWidget(old);
    if (old.auth != widget.auth) {
      old.auth.removeListener(invalidate);
      widget.auth.addListener(invalidate);
      invalidate();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    invalidate();
  }

  Future<void> scan() async {
    if (busy || !foreground) return;
    final raw = code.text.trim();
    final current = ++epoch, session = widget.auth.session;
    expiry?.cancel();
    code.clear();
    setState(() {
      identity = null;
      identityCode = null;
      validity = null;
      failed = false;
    });
    if (!MemberIdentity.codePattern.hasMatch(raw)) {
      setState(() => failed = true);
      return;
    }
    setState(() => busy = true);
    bool valid() =>
        mounted &&
        foreground &&
        current == epoch &&
        identical(session, widget.auth.session);
    try {
      final result = await widget.auth.readMemberIdentity(raw);
      if (!valid()) return;
      setState(() {
        identity = result;
        identityCode = widget.actionsBuilder == null ? null : raw;
        validity = Stopwatch()..start();
        busy = false;
      });
      expiry = Timer(result.validFor, invalidate);
    } catch (_) {
      if (valid()) {
        setState(() {
          failed = true;
          busy = false;
        });
      }
    }
  }

  @override
  void dispose() {
    epoch++;
    expiry?.cancel();
    code.dispose();
    identityCode = null;
    validity = null;
    widget.auth.removeListener(invalidate);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.auth.session?.permissions.contains('orders.create') != true) {
      return Center(child: Text(t('staffAuthFailure')));
    }
    return Align(
      alignment: Alignment.topLeft,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 700),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                t('memberIdentityTitle'),
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              Text(t('memberIdentityHelp')),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: const ValueKey('member-identity-code'),
                      controller: code,
                      enabled: foreground && !busy,
                      obscureText: true,
                      enableSuggestions: false,
                      autocorrect: false,
                      textInputAction: TextInputAction.go,
                      decoration: InputDecoration(
                        labelText: t('memberIdentityInput'),
                        prefixIcon: const Icon(Icons.qr_code_scanner),
                      ),
                      onSubmitted: (_) => unawaited(scan()),
                      onChanged: (_) {
                        expiry?.cancel();
                        setState(() {
                          identity = null;
                          identityCode = null;
                          validity = null;
                          failed = false;
                        });
                      },
                    ),
                  ),
                  const SizedBox(width: 12),
                  FilledButton(
                    key: const ValueKey('member-identity-scan'),
                    onPressed: foreground && !busy
                        ? () => unawaited(scan())
                        : null,
                    child: Text(t('memberIdentityScan')),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              if (busy) const LinearProgressIndicator(),
              if (failed)
                Text(
                  t('memberIdentityFailed'),
                  style: const TextStyle(color: Color(0xffa62e2e)),
                ),
              if (identity != null)
                Card(
                  key: const ValueKey('member-identity-result'),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          identity!.nickname ?? t('orderMemberUnnamed'),
                          style: const TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(t('memberIdentityRecognized')),
                        const SizedBox(height: 8),
                        Text(t('memberIdentityNotice')),
                        if (widget.actionsBuilder != null &&
                            identityCode != null)
                          widget.actionsBuilder!(
                            identity!,
                            identityCode!,
                            () =>
                                mounted &&
                                foreground &&
                                identity != null &&
                                identityCode != null &&
                                validity != null &&
                                validity!.elapsed < identity!.validFor,
                          ),
                        Align(
                          alignment: Alignment.centerRight,
                          child: TextButton(
                            key: const ValueKey('member-identity-clear'),
                            onPressed: invalidate,
                            child: Text(t('memberIdentityClear')),
                          ),
                        ),
                      ],
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
