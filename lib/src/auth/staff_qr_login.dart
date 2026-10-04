import 'dart:async';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../hardware/scanner_input.dart';
import '../strings.dart';
import 'staff_auth_controller.dart';

class StaffQrLogin extends StatefulWidget {
  const StaffQrLogin({
    super.key,
    required this.auth,
    required this.base,
    required this.language,
  });
  final StaffAuthController auth;
  final String base;
  final UiLanguage language;
  @override
  State<StaffQrLogin> createState() => _StaffQrLoginState();
}

class _StaffQrLoginState extends State<StaffQrLogin>
    with WidgetsBindingObserver {
  Timer? timer;
  StreamSubscription<String>? scanner;
  Map<String, dynamic>? ticket;
  int generation = 0;
  bool foreground = true, working = false, scanning = false;
  String? message;
  String t(String key) => tr(widget.language, key);
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    scanner = ScannerInput.codes.listen(
      scan,
      onError: (_) {
        if (mounted) setState(() => message = 'staffQrFailed');
      },
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(create());
    });
  }

  bool current(int g) =>
      mounted && foreground && generation == g && widget.auth.session == null;
  Future<Map<String, dynamic>> call(Map<String, dynamic> p, int g) =>
      widget.auth.qrLoginCall(widget.base, p, stillCurrent: () => current(g));
  Future<void> create() async {
    if (working || scanning || widget.auth.busy) return;
    final g = ++generation;
    timer?.cancel();
    setState(() {
      working = true;
      ticket = null;
      message = null;
    });
    try {
      final result = await call({'action': 'create'}, g);
      if (!current(g)) return;
      final id = result['challengeId'],
          secret = result['pollSecret'],
          expires = result['expiresAtMs'];
      if (id is! String ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(id) ||
          secret is! String ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(secret) ||
          expires is! num ||
          result['code'] != 'kingclub://cashier-login/v1/$id')
        throw const FormatException();
      setState(() => ticket = result);
      schedule(g);
    } catch (_) {
      if (current(g)) setState(() => message = 'staffQrFailed');
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  Map<String, dynamic> get credentials => {
    'challengeId': ticket!['challengeId'],
    'pollSecret': ticket!['pollSecret'],
  };
  void schedule(int g) {
    timer = Timer(const Duration(seconds: 2), () => unawaited(poll(g)));
  }

  Future<void> poll(int g) async {
    if (!current(g) || ticket == null || scanning) return;
    if (DateTime.now().millisecondsSinceEpoch >=
        (ticket!['expiresAtMs'] as num)) {
      setState(() {
        ticket = null;
        message = 'staffQrExpired';
      });
      return;
    }
    try {
      final result = await call({'action': 'poll', ...credentials}, g);
      if (!current(g)) return;
      if (['expired', 'rejected'].contains(result['status'])) {
        setState(() {
          ticket = null;
          message = 'staffQrExpired';
        });
        return;
      }
    } catch (_) {
      if (current(g)) {
        setState(() => message = 'staffQrFailed');
      }
    }
    if (current(g)) schedule(g);
  }

  Future<void> scan(String value) async {
    if (!mounted ||
        !foreground ||
        scanning ||
        working ||
        widget.auth.busy ||
        ModalRoute.of(context)?.isCurrent != true)
      return;
    final code = value.trim();
    if (!RegExp(r'^KC:M:[0-9A-F]{32}$').hasMatch(code)) return;
    final g = ++generation;
    timer?.cancel();
    setState(() {
      scanning = true;
      message = null;
    });
    try {
      // Invalidate the displayed QR before using the other login direction.
      if (ticket != null) {
        await call({'action': 'cancel', ...credentials}, g);
        if (!current(g)) return;
      }
      var result = await call({'action': 'member', 'identityCode': code}, g);
      if (!current(g)) return;
      if (result['requiresStoreSelection'] == true) {
        final stores = (result['stores'] as List).cast<Map>();
        final store = await showDialog<String>(
          context: context,
          builder: (context) => SimpleDialog(
            title: Text(t('staffChooseStore')),
            children: [
              for (final s in stores)
                SimpleDialogOption(
                  onPressed: () =>
                      Navigator.pop(context, s['storeRef'] as String),
                  child: Text(s['storeName'] as String),
                ),
            ],
          ),
        );
        if (store != null && current(g))
          result = await call({
            'action': 'member',
            'identityCode': code,
            'storeRef': store,
          }, g);
      }
    } catch (_) {
      if (current(g)) setState(() => message = 'staffQrDenied');
    } finally {
      if (mounted)
        setState(() {
          scanning = false;
          ticket = null;
        });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    if (!foreground) {
      generation++;
      timer?.cancel();
    } else if (mounted) {
      unawaited(create());
    }
  }

  @override
  void dispose() {
    generation++;
    timer?.cancel();
    scanner?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Container(
        width: 236,
        height: 236,
        padding: const EdgeInsets.all(12),
        color: Colors.white,
        child: ticket != null
            ? QrImageView(
                data: ticket!['code'] as String,
                size: 212,
                gapless: true,
              )
            : Center(
                child: working || scanning
                    ? const CircularProgressIndicator()
                    : IconButton(
                        iconSize: 46,
                        tooltip: t('staffQrRefresh'),
                        onPressed: create,
                        icon: const Icon(Icons.refresh),
                      ),
              ),
      ),
      const SizedBox(height: 16),
      Text(t('staffQrHint'), textAlign: TextAlign.center),
      if (message != null)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(t(message!), textAlign: TextAlign.center),
        ),
      TextButton(
        onPressed: working || scanning ? null : create,
        child: Text(t('staffQrRefresh')),
      ),
    ],
  );
}
