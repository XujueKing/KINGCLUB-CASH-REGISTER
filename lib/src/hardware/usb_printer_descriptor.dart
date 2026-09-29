/// Descriptor evidence only; IDs identify an attachment, not a permanent device.
/// No VID/PID alone proves the brand, ESC/POS support, or permission to print.
class UsbPrinterDescriptor {
  UsbPrinterDescriptor._(
    this.deviceId,
    this.vendorId,
    this.productId,
    this.deviceClass,
    this.hasPermission,
    this.interfaces,
  );
  final int deviceId, vendorId, productId, deviceClass;
  final bool hasPermission;
  final List<UsbPrinterInterface> interfaces;

  String get vendorProduct =>
      '${vendorId.toRadixString(16).padLeft(4, '0')}:${productId.toRadixString(16).padLeft(4, '0')}';

  factory UsbPrinterDescriptor.parse(Object? value) {
    final data = _fields(value, {
      'deviceId',
      'vendorId',
      'productId',
      'deviceClass',
      'hasPermission',
      'interfaces',
    });
    final permission = data['hasPermission'];
    if (permission is! bool) _invalid();
    final interfaces = _list(
      data['interfaces'],
      32,
    ).map(UsbPrinterInterface.parse).toList();
    final keys = interfaces.map((i) => '${i.id}:${i.alternate}').toSet();
    final deviceClass = _int(data['deviceClass'], 255);
    if (keys.length != interfaces.length ||
        (deviceClass != 7 && !interfaces.any((i) => i.classCode == 7))) {
      _invalid();
    }
    return UsbPrinterDescriptor._(
      _int(data['deviceId'], 2147483647),
      _int(data['vendorId'], 65535),
      _int(data['productId'], 65535),
      deviceClass,
      permission,
      List.unmodifiable(interfaces),
    );
  }
}

class UsbPrinterInterface {
  UsbPrinterInterface._(
    this.id,
    this.alternate,
    this.classCode,
    this.subclass,
    this.protocol,
    this.endpoints,
  );
  final int id, alternate, classCode, subclass, protocol;
  final List<UsbPrinterEndpoint> endpoints;

  /// A candidate path, not claimed/opened, never proof of ESC/POS support.
  bool get hasBulkOutput =>
      classCode == 7 &&
      subclass == 1 &&
      (protocol == 1 || protocol == 2) &&
      endpoints.any((e) => e.type == 2 && e.address < 128);

  factory UsbPrinterInterface.parse(Object? value) {
    final data = _fields(value, {
      'id',
      'alternate',
      'class',
      'subclass',
      'protocol',
      'endpoints',
    });
    final endpoints = _list(
      data['endpoints'],
      32,
    ).map(UsbPrinterEndpoint.parse).toList();
    if (endpoints.map((e) => e.address).toSet().length != endpoints.length) {
      _invalid();
    }
    return UsbPrinterInterface._(
      _int(data['id'], 255),
      _int(data['alternate'], 255),
      _int(data['class'], 255),
      _int(data['subclass'], 255),
      _int(data['protocol'], 255),
      List.unmodifiable(endpoints),
    );
  }
}

class UsbPrinterEndpoint {
  UsbPrinterEndpoint._(this.address, this.type, this.maxPacketSize);
  final int address, type, maxPacketSize;
  factory UsbPrinterEndpoint.parse(Object? value) {
    final data = _fields(value, {'address', 'type', 'maxPacketSize'});
    final address = _int(data['address'], 255);
    final size = _int(data['maxPacketSize'], 65535);
    if (address & 0x70 != 0 || address & 0x0f == 0 || size == 0) _invalid();
    return UsbPrinterEndpoint._(address, _int(data['type'], 3), size);
  }
}

Never _invalid() =>
    throw const FormatException('USB_PRINTER_DESCRIPTOR_INVALID');
Map _fields(Object? value, Set<String> keys) {
  if (value is! Map ||
      value.length != keys.length ||
      !keys.every(value.containsKey)) {
    _invalid();
  }
  return value;
}

int _int(Object? value, int max) {
  if (value is! int || value < 0 || value > max) _invalid();
  return value;
}

List _list(Object? value, int max) {
  if (value is! List || value.length > max) _invalid();
  return value;
}
