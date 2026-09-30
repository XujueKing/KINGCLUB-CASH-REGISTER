
import 'package:flutter/services.dart';

import 'raster_print_coordinator.dart';
import 'usb_printer_permission.dart';

/// Only used by the durable coordinator after user confirmation. Native build
/// has its own default-off gate; this class never requests USB authorization.
class NativeRasterPrintTransport implements RasterPrintTransport {
  const NativeRasterPrintTransport({
    this.enabled = const bool.fromEnvironment(
      'CASHIER_USB_RASTER_OUTPUT',
      defaultValue: false,
    ),
  });
  final bool enabled;
  static const channel = MethodChannel('cn.kingclub.cashier/usb-raster-output');
  @override
  Future<int> send(
    UsbPrinterSelection target,
    Uint8List bytes,
    String attemptId,
  ) async {
    if (!enabled) throw const FormatException('USB_OUTPUT_DISABLED');
    if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(attemptId) ||
        bytes.isEmpty ||
        bytes.length > 1000000) {
      throw const FormatException('USB_OUTPUT_INVALID');
    }
    try {
      final raw = await channel
          .invokeMethod<Object?>('send', {
            'attemptId': attemptId,
            'bytes': bytes,
            'deviceId': target.device.deviceId,
            'vendorId': target.device.vendorId,
            'productId': target.device.productId,
            'deviceClass': target.device.deviceClass,
            'interfaceId': target.interface.id,
            'alternate': target.interface.alternate,
            'protocol': target.interface.protocol,
            'endpointAddress': target.endpoint.address,
            'maxPacketSize': target.endpoint.maxPacketSize,
          })
          .timeout(const Duration(seconds: 25));
      if (raw is! Map ||
          raw.length != 2 ||
          raw['attemptId'] != attemptId ||
          raw['acceptedBytes'] is! int ||
          (raw['acceptedBytes'] as int) < 0 ||
          (raw['acceptedBytes'] as int) > bytes.length) {
        throw const FormatException();
      }
      return raw['acceptedBytes'] as int;
    } catch (_) {
      throw const FormatException('USB_OUTPUT_UNKNOWN');
    }
  }
}
