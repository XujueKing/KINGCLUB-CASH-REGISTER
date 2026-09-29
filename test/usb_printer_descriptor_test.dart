import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/hardware/printer_discovery.dart';
import 'package:kingclub_cash_register/src/hardware/usb_printer_descriptor.dart';

import 'printer_discovery_test.dart' as p;

// Explicit synthetic descriptors, not a claim about a connected device.
Map<String, Object?> endpoint() => {
  'address': 1,
  'type': 2,
  'maxPacketSize': 64,
};
Map<String, Object?> usbInterface() => {
  'id': 0,
  'alternate': 0,
  'class': 7,
  'subclass': 1,
  'protocol': 2,
  'endpoints': [endpoint()],
};
Map<String, Object?> descriptor() => {
  'deviceId': 100,
  'vendorId': 0x1234,
  'productId': 0x5678,
  'deviceClass': 0,
  'hasPermission': false,
  'interfaces': [usbInterface()],
};

void main() {
  test(
    'descriptor exposes permission separately from a bulk output candidate',
    () {
      final usb = UsbPrinterDescriptor.parse(descriptor());
      expect(usb.vendorProduct, '1234:5678');
      expect(usb.hasPermission, false);
      expect(usb.interfaces.single.hasBulkOutput, true);
      expect(() => usb.interfaces.clear(), throwsUnsupportedError);
      expect(
        () => usb.interfaces.single.endpoints.clear(),
        throwsUnsupportedError,
      );
    },
  );

  test(
    'input, interrupt, protocol and class mismatches are not output candidates',
    () {
      for (final i in [
        {
          ...usbInterface(),
          'endpoints': [
            {...endpoint(), 'address': 129},
          ],
        },
        {
          ...usbInterface(),
          'endpoints': [
            {...endpoint(), 'type': 3},
          ],
        },
        {...usbInterface(), 'class': 255},
        {...usbInterface(), 'subclass': 0},
        {...usbInterface(), 'protocol': 3},
        {...usbInterface(), 'endpoints': <Object?>[]},
      ]) {
        expect(UsbPrinterInterface.parse(i).hasBulkOutput, false);
      }
    },
  );

  test(
    'reject malformed endpoints, duplicate addresses and interface alternates',
    () {
      for (final value in [
        {...endpoint(), 'address': 0},
        {...endpoint(), 'address': 16},
        {...endpoint(), 'address': 256},
        {...endpoint(), 'type': 4},
        {...endpoint(), 'maxPacketSize': 0},
        {...endpoint(), 'type': 2.0},
        {...endpoint(), 'serial': 'TEST_PRIVATE'},
      ]) {
        expect(() => UsbPrinterEndpoint.parse(value), throwsFormatException);
      }
      expect(
        () => UsbPrinterInterface.parse({
          ...usbInterface(),
          'endpoints': [endpoint(), endpoint()],
        }),
        throwsFormatException,
      );
      expect(
        () => UsbPrinterDescriptor.parse({
          ...descriptor(),
          'interfaces': [usbInterface(), usbInterface()],
        }),
        throwsFormatException,
      );
      final alternates = UsbPrinterDescriptor.parse({
        ...descriptor(),
        'interfaces': [
          usbInterface(),
          {...usbInterface(), 'alternate': 1},
        ],
      });
      expect(alternates.interfaces.length, 2);
    },
  );

  test(
    'unknown fields, malformed IDs and non-printer descriptors are rejected',
    () {
      for (final value in [
        null,
        {},
        {...descriptor(), 'deviceId': -1},
        {...descriptor(), 'vendorId': 65536},
        {...descriptor(), 'productId': '123'},
        {...descriptor(), 'hasPermission': 1},
        {...descriptor(), 'serialNumber': 'TEST_PRIVATE'},
        {...descriptor(), 'interfaces': <Object?>[]},
        {...descriptor(), 'interfaces': List.filled(33, usbInterface())},
      ]) {
        expect(() => UsbPrinterDescriptor.parse(value), throwsFormatException);
      }
    },
  );

  test('discovery count, exact schema and attachment IDs must match', () {
    final result = PrinterDiscovery.parse({
      ...p.observation(),
      'usbPrinterCandidates': 1,
      'usbPrinters': [descriptor()],
    });
    expect(result.usbPrinters.single.vendorProduct, '1234:5678');
    for (final value in [
      {
        ...p.observation(),
        'usbPrinters': [descriptor()],
      },
      {...p.observation(), 'usbPrinterCandidates': 1},
      {
        ...p.observation(),
        'usbPrinterCandidates': 2,
        'usbPrinters': [descriptor(), descriptor()],
      },
    ]) {
      expect(() => PrinterDiscovery.parse(value), throwsFormatException);
    }
    final sameModel = PrinterDiscovery.parse({
      ...p.observation(),
      'usbPrinterCandidates': 2,
      'usbPrinters': [
        descriptor(),
        {...descriptor(), 'deviceId': 101},
      ],
    });
    expect(sameModel.usbPrinters.length, 2);
  });
}
