import 'dart:io';

import 'package:flutter/services.dart';

/// The visible scan page owns the subscription; no scan values are persisted.
class ScannerInput {
  static const _channel = EventChannel('kingclub/scanner');
  static Stream<String> get codes => Platform.isAndroid
      ? _channel
            .receiveBroadcastStream()
            .where((value) => value is String)
            .cast<String>()
      : const Stream<String>.empty();
}
