import 'dart:async';
import 'dart:math';

import 'package:flutter/services.dart';

import 'usb_printer_descriptor.dart';

/// Explicit device/interface/endpoint selection. Never an automatic default.
class UsbPrinterSelection {
  UsbPrinterSelection._(this.device, this.interface, this.endpoint);
  final UsbPrinterDescriptor device;
  final UsbPrinterInterface interface;
  final UsbPrinterEndpoint endpoint;

  factory UsbPrinterSelection.choose(
    UsbPrinterDescriptor device,
    UsbPrinterInterface interface,
    UsbPrinterEndpoint endpoint,
  ) {
    if (!device.interfaces.contains(interface) ||
        !interface.endpoints.contains(endpoint) ||
        !interface.hasBulkOutput ||
        endpoint.type != 2 ||
        endpoint.address >= 128) {
      throw const FormatException('USB_PRINTER_SELECTION_INVALID');
    }
    return UsbPrinterSelection._(device, interface, endpoint);
  }

  Map<String, Object> _payload(String requestId) => {
    'requestId': requestId,
    'deviceId': device.deviceId,
    'vendorId': device.vendorId,
    'productId': device.productId,
    'deviceClass': device.deviceClass,
    'interfaceId': interface.id,
    'alternate': interface.alternate,
    'protocol': interface.protocol,
    'endpointAddress': endpoint.address,
    'maxPacketSize': endpoint.maxPacketSize,
  };
}

/// One explicit OS authorization attempt; granting access never starts printing.
class UsbPrinterPermissionRequest {
  UsbPrinterPermissionRequest(this.selection) : requestId = _id();
  final UsbPrinterSelection selection;
  final String requestId;
  bool _started = false, _cancelled = false;
  static const _channel = MethodChannel(
    'cn.kingclub.cashier/usb-printer-permission',
  );
  static String _id() {
    final random = Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  Future<bool> request({required bool confirmed}) async {
    if (!confirmed || _started || _cancelled) {
      throw PlatformException(code: 'USB_PERMISSION_NOT_CONFIRMED_OR_USED');
    }
    _started = true;
    try {
      final raw = await _channel
          .invokeMethod<Object?>('request', selection._payload(requestId))
          .timeout(const Duration(seconds: 65));
      if (_cancelled ||
          raw is! Map ||
          raw.length != 2 ||
          raw['requestId'] != requestId ||
          raw['granted'] is! bool) {
        throw const FormatException('USB_PERMISSION_INVALID_REPLY');
      }
      return raw['granted'] as bool;
    } on MissingPluginException {
      throw PlatformException(code: 'USB_PERMISSION_UNSUPPORTED');
    } on TimeoutException {
      unawaited(cancel());
      throw PlatformException(code: 'USB_PERMISSION_TIMEOUT');
    } catch (_) {
      throw PlatformException(code: 'USB_PERMISSION_FAILED');
    }
  }

  /// Stops our observation, not the OS dialog or an already granted permission.
  Future<void> cancel() async {
    if (_cancelled) return;
    _cancelled = true;
    if (!_started) return;
    try {
      await _channel
          .invokeMethod<void>('cancel', requestId)
          .timeout(const Duration(seconds: 4));
    } catch (_) {
      // The native attempt has its own deadline; never claim permission revoked.
    }
  }
}
