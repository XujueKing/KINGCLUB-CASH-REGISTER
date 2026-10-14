import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

enum UpdateStage {
  idle,
  checking,
  downloading,
  ready,
  current,
  failed,
  unavailable,
}

class AppUpdates extends ChangeNotifier {
  AppUpdates({
    this.channel = const MethodChannel('cn.kingclub.cashier/app-update'),
    this.manifestUrl = const String.fromEnvironment('CASHIER_UPDATE_URL'),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;
  static final instance = AppUpdates();
  final MethodChannel channel;
  final String manifestUrl;
  final DateTime Function() _now;
  UpdateStage stage = UpdateStage.idle;
  String currentVersion = '', nextVersion = '', notes = '';
  int progress = 0;
  bool installing = false, _disposed = false, _started = false;
  bool _foreground = true, _externalInstaller = false, _installerPaused = false;
  DateTime? _nextCheck, _lastAttempt;
  Timer? _timer;
  bool get busy =>
      installing ||
      _externalInstaller ||
      stage == UpdateStage.checking ||
      stage == UpdateStage.downloading;

  void setForeground(bool value) {
    _foreground = value;
    if (!value && _externalInstaller) _installerPaused = true;
    if (value && _installerPaused) {
      _externalInstaller = false;
      _installerPaused = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> start() async {
    if (_started || _disposed) return;
    _started = true;
    if (manifestUrl.isEmpty ||
        kIsWeb ||
        defaultTargetPlatform != TargetPlatform.android) {
      stage = UpdateStage.unavailable;
      notifyListeners();
      return;
    }
    channel.setMethodCallHandler((call) async {
      if (call.method == 'progress' && !_disposed) {
        stage = UpdateStage.downloading;
        progress = (call.arguments as int).clamp(0, 100);
        notifyListeners();
      }
    });
    try {
      final info = await channel.invokeMapMethod<String, dynamic>('info');
      currentVersion =
          '${info?['versionName'] ?? ''} (${info?['versionCode'] ?? ''})';
    } catch (_) {
      /* Update failure must never block login or sales. */
    }
    if (_disposed) return;
    await check();
    if (!_disposed) {
      _timer = Timer.periodic(
        const Duration(minutes: 15),
        (_) => unawaited(check()),
      );
    }
  }

  Future<void> check({bool force = false}) async {
    if (_disposed ||
        !_foreground ||
        busy ||
        manifestUrl.isEmpty ||
        stage == UpdateStage.unavailable) {
      return;
    }
    final now = _now();
    if (_lastAttempt != null &&
        now.difference(_lastAttempt!) < const Duration(seconds: 15)) {
      return;
    }
    if (!force && _nextCheck != null && now.isBefore(_nextCheck!)) return;
    _lastAttempt = now;
    stage = UpdateStage.checking;
    notifyListeners();
    try {
      final data = await channel.invokeMapMethod<String, dynamic>('check', {
        'url': manifestUrl,
      });
      if (_disposed) return;
      if (data?['status'] == 'ready') {
        nextVersion = data?['versionName'] as String? ?? '';
        notes = data?['notes'] as String? ?? '';
        stage = UpdateStage.ready;
      } else if (data?['status'] == 'current') {
        stage = UpdateStage.current;
        nextVersion = '';
        notes = '';
      } else {
        throw const FormatException('Unknown update result');
      }
      _nextCheck = now.add(const Duration(hours: 1));
    } catch (_) {
      if (_disposed) return;
      stage = UpdateStage.failed;
      _nextCheck = now.add(const Duration(minutes: 15));
    }
    notifyListeners();
  }

  // Only an explicit action in the update dialog may open the system installer.
  Future<String> install() async {
    if (_disposed || !_foreground || busy || stage != UpdateStage.ready)
      return 'failed';
    installing = true;
    _externalInstaller = true;
    _installerPaused = false;
    notifyListeners();
    try {
      final result = await channel.invokeMapMethod<String, dynamic>('install');
      final status = result?['status'];
      if (status != 'permission' && status != 'installer')
        _externalInstaller = false;
      return status == 'permission' || status == 'installer'
          ? status as String
          : 'failed';
    } catch (_) {
      _externalInstaller = false;
      return 'failed';
    } finally {
      installing = false;
      if (!_disposed) notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    channel.setMethodCallHandler(null);
    super.dispose();
  }
}
