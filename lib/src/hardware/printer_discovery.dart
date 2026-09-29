import 'dart:async';

import 'package:flutter/services.dart';

/// Package/USB discovery is not printer readiness or proof of printing.
class PrinterDiscovery {
  const PrinterDiscovery._(
    this.serviceInstalled,
    this.serviceEnabled,
    this.serviceResolvable,
    this.serviceVersion,
    this.usbPrinterCandidates,
  );
  final bool serviceInstalled, serviceEnabled, serviceResolvable;
  final String? serviceVersion;
  final int usbPrinterCandidates;

  factory PrinterDiscovery.parse(Object? value) {
    if (value is! Map ||
        value.length != 5 ||
        value['serviceInstalled'] is! bool ||
        value['serviceEnabled'] is! bool ||
        value['serviceResolvable'] is! bool ||
        value['usbPrinterCandidates'] is! int ||
        (value['usbPrinterCandidates'] as int) < 0 ||
        (value['usbPrinterCandidates'] as int) > 256) {
      throw const FormatException('PRINTER_DISCOVERY_INVALID');
    }
    final version = value['serviceVersion'];
    if (!value.containsKey('serviceVersion') ||
        (version != null &&
            (version is! String ||
                version.isEmpty ||
                version.length > 128 ||
                RegExp(r'[\x00-\x1f\x7f]').hasMatch(version))) ||
        (value['serviceInstalled'] == false &&
            (value['serviceEnabled'] != false ||
                value['serviceResolvable'] != false ||
                version != null)) ||
        (value['serviceResolvable'] == true &&
            value['serviceEnabled'] != true)) {
      throw const FormatException('PRINTER_DISCOVERY_INVALID');
    }
    return PrinterDiscovery._(
      value['serviceInstalled'] as bool,
      value['serviceEnabled'] as bool,
      value['serviceResolvable'] as bool,
      version as String?,
      value['usbPrinterCandidates'] as int,
    );
  }
}

class PrinterDiscoveryClient {
  const PrinterDiscoveryClient();
  static const _channel = MethodChannel(
    'cn.kingclub.cashier/printer-discovery',
  );

  Future<PrinterDiscovery> inspect() async {
    try {
      final raw = await _channel
          .invokeMethod<Object?>('inspect')
          .timeout(const Duration(seconds: 4));
      return PrinterDiscovery.parse(raw);
    } on MissingPluginException {
      throw PlatformException(code: 'PRINTER_DISCOVERY_UNSUPPORTED');
    } on TimeoutException {
      throw PlatformException(code: 'PRINTER_DISCOVERY_TIMEOUT');
    } catch (_) {
      throw PlatformException(code: 'PRINTER_DISCOVERY_FAILED');
    }
  }
}
