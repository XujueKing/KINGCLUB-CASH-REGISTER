import 'package:flutter/foundation.dart';
import '../auth/staff_auth_controller.dart';
import '../live/receipt_document.dart';
import '../strings.dart';
import 'escpos_raster.dart';
import 'native_raster_print_transport.dart';
import 'printer_discovery.dart';
import 'raster_print_coordinator.dart';
import 'receipt_document_renderer.dart';
import 'receipt_print_identity.dart';
import 'usb_printer_permission.dart';

/// Prints a verified server receipt, never a local cart or payment admission.
/// The existing durable document fence prevents automatic duplicate output.
Future<String> printPaidTableReceipt({
  required StaffAuthController auth,
  required String checkoutRef,
  required String tableRef,
  required String sessionRef,
  required UiLanguage language,
  required bool Function() stillCurrent,
  bool reprint = false,
}) async {
  final identity = auth.session;
  if (identity == null) return 'checkoutPrintFailed';
  bool current() =>
      stillCurrent() &&
      identical(identity, auth.session) &&
      identity.expiresAt.isAfter(DateTime.now());
  var stage = 'receipt';
  try {
    final TableReceiptDocument document = await auth.readTableReceiptDocument(
      checkoutRef,
    );
    if (!current() ||
        document.storeRef != identity.storeRef ||
        document.tableRef != tableRef ||
        document.sessionRef != sessionRef ||
        document.checkoutRef != checkoutRef)
      return 'checkoutPrintFailed';
    stage = 'discovery';
    final discovery = await const PrinterDiscoveryClient().inspect();
    // Installed XP-80U USB printer. Never send raster bytes to a scanner,
    // an unknown printer, or an ambiguous collection of output interfaces.
    final targets = <UsbPrinterSelection>[
      for (final device in discovery.usbPrinters.where(
        (d) => d.vendorId == 1155 && d.productId == 22339 && d.hasPermission,
      ))
        for (final interface in device.interfaces.where(
          (i) => i.alternate == 0 && i.hasBulkOutput,
        ))
          for (final endpoint in interface.endpoints.where(
            (e) => e.type == 2 && e.address > 0 && e.address < 16,
          ))
            UsbPrinterSelection.choose(device, interface, endpoint),
    ];
    if (targets.length != 1 || !current()) return 'checkoutPrintUnavailable';
    stage = 'render';
    final plan = ReceiptRasterPlan.forTable(
      document,
      language: language,
      widthDots: 576,
      reprint: reprint,
    );
    final rasters = <MonochromeRaster>[];
    for (var page = 0; page < plan.pages.length; page++) {
      if (!current()) return 'checkoutPrintFailed';
      rasters.add((await plan.renderPage(page)).raster);
    }
    stage = 'send';
    final result =
        await RasterPrintCoordinator(
          transport: const NativeRasterPrintTransport(),
          enabled: const bool.fromEnvironment('CASHIER_USB_RASTER_OUTPUT'),
        ).printRasters(
          rasters: rasters,
          target: targets.single,
          documentIdentity: ReceiptPrintIdentity.forTable(
            base: identity.base.toString(),
            storeRef: identity.storeRef,
            checkoutRef: checkoutRef,
          ),
          confirmed: true,
          confirmedReprint: reprint,
          compatibilityVerified: true,
          stillCurrent: current,
        );
    debugPrint('cashier_print_state: ${result.state}');
    return result.state == 'transport_accepted'
        ? 'checkoutPrintSent'
        : 'checkoutPrintFailed';
  } catch (_) {
    debugPrint('cashier_print_failed_stage: $stage');
    // Payment remains successful even if receipt read, USB or paper output fails.
    return 'checkoutPrintFailed';
  }
}
