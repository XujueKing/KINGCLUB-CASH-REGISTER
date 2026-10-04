import 'staff_qr_login.dart';

import 'dart:async';

import 'package:flutter/material.dart';

import '../strings.dart';
import '../workbench_page.dart';
import '../hardware/printer_discovery_dialog.dart';
import 'staff_auth_controller.dart';

/// Live entry point. Preview records never enter this widget or its session.
class StaffAccessPage extends StatefulWidget {
  const StaffAccessPage({super.key, this.controller});
  final StaffAuthController? controller;

  @override
  State<StaffAccessPage> createState() => _StaffAccessPageState();
}

class _StaffAccessPageState extends State<StaffAccessPage>
    with WidgetsBindingObserver {
  late final StaffAuthController auth;
  static const serviceEndpoint = String.fromEnvironment('CASHIER_SERVICE_URL');
  final employee = TextEditingController();
  final password = TextEditingController();
  final form = GlobalKey<FormState>();
  UiLanguage language = UiLanguage.zh;
  Timer? refreshTimer;
  bool foreground = true;
  bool passwordMode = false;
  String? notice;
  String t(String key) => tr(language, key);

  @override
  void initState() {
    super.initState();
    auth = widget.controller ?? StaffAuthController();
    auth.addListener(changed);
    WidgetsBinding.instance.addObserver(this);
    // Do not invoke platform secure storage during build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(restore());
    });
  }

  void changed() {
    if (!mounted) return;
    refreshTimer?.cancel();
    final session = auth.session;
    if (foreground && session != null && !auth.busy) {
      final until = session.expiresAt
          .subtract(const Duration(minutes: 1))
          .difference(DateTime.now());
      // Avoid a tight refresh loop for a session nearing its absolute expiry.
      if (until > Duration.zero) {
        refreshTimer = Timer(until, () => unawaited(restore()));
      } else {
        refreshTimer = Timer(
          const Duration(minutes: 1),
          () => unawaited(restore()),
        );
      }
    }
    setState(() {});
  }

  Future<void> restore() async {
    if (auth.busy) return;
    try {
      await auth.restore();
      if (mounted) setState(() => notice = null);
    } catch (_) {
      if (mounted)
        setState(
          () => notice = auth.canRetryRestore
              ? 'staffReconnectNotice'
              : 'staffAuthFailure',
        );
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    if (!foreground) {
      refreshTimer?.cancel();
      password.clear();
      return;
    }
    final session = auth.session;
    if (session != null &&
        session.expiresAt.difference(DateTime.now()) <=
            const Duration(minutes: 1)) {
      unawaited(restore());
    } else {
      changed();
    }
  }

  Future<void> login() async {
    if (auth.busy || !(form.currentState?.validate() ?? false)) return;
    final secret = password.text;
    password.clear();
    setState(() => notice = null);
    try {
      await auth.login(
        base: serviceEndpoint,
        selectStore: (stores) async {
          if (!mounted || !foreground) return null;
          final selected = await showDialog<String>(
            context: context,
            builder: (context) => SimpleDialog(
              title: Text(t('staffChooseStore')),
              children: [
                for (final store in stores)
                  SimpleDialogOption(
                    onPressed: () => Navigator.pop(context, store['storeRef']),
                    child: Text(store['storeName']!),
                  ),
                SimpleDialogOption(
                  onPressed: () => Navigator.pop(context),
                  child: Text(t('staffCancelSelection')),
                ),
              ],
            ),
          );
          return mounted && foreground ? selected : null;
        },
        loginName: employee.text.trim(),
        password: secret,
      );
    } catch (_) {
      if (mounted) setState(() => notice = 'staffAuthFailure');
    }
  }

  Future<void> logout() async {
    setState(() => notice = null);
    try {
      final confirmed = await auth.logout();
      if (mounted && !confirmed) {
        setState(() => notice = 'staffLogoutUnconfirmed');
      }
    } catch (_) {
      if (mounted) setState(() => notice = 'staffStorageFailure');
    }
  }

  @override
  void dispose() {
    refreshTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    auth.removeListener(changed);
    if (widget.controller == null) auth.dispose();
    employee.dispose();
    password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = auth.session;
    final message = auth.errorCode == 'SECURE_STORAGE_FAILED'
        ? 'staffStorageFailure'
        : notice;
    if (session != null) {
      return WorkbenchPage(
        key: ObjectKey(session),
        auth: auth,
        language: language,
        onLanguage: (value) => setState(() => language = value),
        onLogout: auth.busy ? null : logout,
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('KINGCLUB POS'),
        actions: [
          TextButton(
            key: const ValueKey('printer-inspect-open'),
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => PrinterDiscoveryDialog(language: language),
            ),
            child: Text(t('printerInspectTitle')),
          ),
          if (session != null)
            TextButton(
              key: const ValueKey('staff-logout'),
              onPressed: auth.busy ? null : logout,
              child: Text(t('staffSignOut')),
            ),
          DropdownButton<UiLanguage>(
            key: const ValueKey('staff-language'),
            value: language,
            onChanged: (value) {
              if (value != null) setState(() => language = value);
            },
            items: [
              for (final item in UiLanguage.values)
                DropdownMenuItem(
                  value: item,
                  child: Text(['简体中文', 'English', '繁體中文', 'ไทย'][item.index]),
                ),
            ],
          ),
          const SizedBox(width: 24),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Image.asset(
                      'assets/brand/kingclub-gold.png',
                      width: 128,
                      height: 69,
                      fit: BoxFit.contain,
                      color: Colors.black,
                      colorBlendMode: BlendMode.srcIn,
                      semanticLabel: 'KING CLUB',
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    t('staffWelcome'),
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 24),
                  if (auth.busy) ...[
                    const LinearProgressIndicator(),
                    const SizedBox(height: 16),
                    Text(t('staffVerifying')),
                  ],
                  if (message != null) ...[
                    Semantics(liveRegion: true, child: Text(t(message))),
                    const SizedBox(height: 16),
                  ],
                  if (auth.canRetryRestore)
                    FilledButton(
                      onPressed: auth.busy ? null : () => unawaited(restore()),
                      child: Text(t('staffReconnect')),
                    ),
                  if (!passwordMode && !auth.busy && !auth.canRetryRestore)
                    StaffQrLogin(
                      auth: auth,
                      base: serviceEndpoint,
                      language: language,
                    ),
                  TextButton(
                    key: const ValueKey('staff-login-mode'),
                    onPressed: auth.busy
                        ? null
                        : () => setState(() {
                            passwordMode = !passwordMode;
                            password.clear();
                            notice = null;
                          }),
                    child: Text(
                      t(passwordMode ? 'staffQrMode' : 'staffPasswordMode'),
                    ),
                  ),
                  if (passwordMode)
                    Form(
                      key: form,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          field(employee, 'staffAccount', 'staff-account'),
                          field(
                            password,
                            'staffPassword',
                            'staff-password',
                            secret: true,
                          ),
                          FilledButton(
                            key: const ValueKey('staff-login'),
                            onPressed: auth.busy ? null : login,
                            child: Text(t('staffSignIn')),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget field(
    TextEditingController controller,
    String label,
    String key, {
    bool secret = false,
    bool url = false,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TextFormField(
      key: ValueKey(key),
      controller: controller,
      enabled: !auth.busy,
      obscureText: secret,
      autocorrect: false,
      enableSuggestions: false,
      maxLength: secret ? 256 : (url ? 2048 : 64),
      keyboardType: url ? TextInputType.url : TextInputType.text,
      decoration: InputDecoration(labelText: t(label), counterText: ''),
      validator: (value) {
        if (value == null || (secret ? value.isEmpty : value.trim().isEmpty)) {
          return t('staffRequired');
        }
        if (url) {
          final uri = Uri.tryParse(value.trim());
          if (uri == null ||
              uri.scheme != 'https' ||
              uri.host.isEmpty ||
              uri.userInfo.isNotEmpty ||
              uri.hasQuery ||
              uri.hasFragment) {
            return t('invalidUrl');
          }
        }
        return null;
      },
    ),
  );
}
