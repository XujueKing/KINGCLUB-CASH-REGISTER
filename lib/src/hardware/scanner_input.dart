import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// One shared native subscription; only the foreground scan route handles values.
class ScannerInput {
  static const _channel = EventChannel('kingclub/scanner');
  static final _events = _channel
      .receiveBroadcastStream()
      .where((value) => value is String)
      .cast<String>();
  static Stream<String> get codes =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android
      ? _events
      : const Stream<String>.empty();
}
