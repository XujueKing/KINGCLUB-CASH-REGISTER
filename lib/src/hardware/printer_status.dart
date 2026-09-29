import 'dart:async';

import 'package:flutter/services.dart';

/// Raw service observations only. Neither code proves that a receipt printed.
/// Paper codes are deliberately not interpreted as physical millimetres here.
class PrinterStatus {
  const PrinterStatus._(this.statusCode, this.paperCode);
  final int? statusCode;
  final int? paperCode;

  /// The service's instantaneous report, not print completion or permission.
  String get stateLabelKey => switch (statusCode) {
    1 => 'printerStateNormal',
    2 => 'printerStatePreparing',
    3 => 'printerStateCommunication',
    4 => 'printerStateNoPaper',
    5 => 'printerStateHot',
    6 => 'printerStateCover',
    7 => 'printerStateCutterError',
    8 => 'printerStateCutterRecovered',
    9 => 'printerStateBlackMark',
    505 => 'printerStateNotDetected',
    507 => 'printerStateFirmware',
    _ => 'printerUnknown',
  };

  factory PrinterStatus.parse(Object? value) {
    if (value is! Map ||
        value.length != 2 ||
        !value.containsKey('statusCode') ||
        !value.containsKey('paperCode')) {
      throw const FormatException('PRINTER_STATUS_INVALID');
    }
    for (final key in ['statusCode', 'paperCode']) {
      final code = value[key];
      if (code != null &&
          (code is! int || code < -2147483648 || code > 2147483647)) {
        throw const FormatException('PRINTER_STATUS_INVALID');
      }
    }
    return PrinterStatus._(
      value['statusCode'] as int?,
      value['paperCode'] as int?,
    );
  }
}

class PrinterStatusClient {
  const PrinterStatusClient();
  static const _channel = MethodChannel('cn.kingclub.cashier/printer-status');

  Future<PrinterStatus> inspect() async {
    try {
      final raw = await _channel
          .invokeMethod<Object?>('inspect')
          .timeout(const Duration(seconds: 4));
      return PrinterStatus.parse(raw);
    } on MissingPluginException {
      throw PlatformException(code: 'PRINTER_STATUS_UNSUPPORTED');
    } on TimeoutException {
      throw PlatformException(code: 'PRINTER_STATUS_TIMEOUT');
    } catch (_) {
      throw PlatformException(code: 'PRINTER_STATUS_FAILED');
    }
  }
}
