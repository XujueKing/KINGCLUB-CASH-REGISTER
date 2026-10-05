import 'package:flutter/foundation.dart';

import '../auth/staff_auth_controller.dart';
import '../live/receipt_document.dart';
import '../live/table_snapshot.dart';
import '../strings.dart';
import 'escpos_raster.dart';
import 'native_raster_print_transport.dart';
import 'printer_discovery.dart';
import 'raster_print_coordinator.dart';
import 'receipt_document_renderer.dart';
import 'receipt_print_identity.dart';
import 'usb_printer_permission.dart';

/// Resolve labels from the existing workbench; never print database IDs as names.
Future<ReceiptCaption> readReceiptCaption(
  StaffAuthController auth,
  String tableRef,
  String sessionRef,
) async {
  final identity = auth.session;
  if (identity == null) return const ReceiptCaption();
  try {
    return await (() async {
      String? after;
      final visited = <String>{};
      for (var page = 0; page < 10; page++) {
        final snapshot = TableSnapshot.parse(
          await auth.readWorkbench(afterTable: after),
          storeRef: identity.storeRef,
          employeeRef: identity.employeeRef,
          afterTable: after,
        );
        if (!identical(identity, auth.session)) break;
        for (final table in snapshot.tables) {
          if (table.reference == tableRef)
            return ReceiptCaption(
              storeName: snapshot.storeName,
              tableName: table.name,
              partySize: table.session?.reference == sessionRef
                  ? table.session?.partySize
                  : null,
            );
        }
        after = snapshot.nextAfterTable;
        if (after == null || !visited.add(after)) break;
      }
      return ReceiptCaption(storeName: identity.storeName);
    })().timeout(const Duration(seconds: 5));
  } catch (_) {
    return ReceiptCaption(storeName: identity.storeName);
  }
}

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
    return await printReceiptPlan(
      plan: ReceiptRasterPlan.forTable(
        document,
        language: language,
        widthDots: 576,
        caption: await readReceiptCaption(auth, tableRef, sessionRef),
        reprint: reprint,
      ),
      printIdentity: ReceiptPrintIdentity.forTable(
        base: identity.base.toString(),
        storeRef: identity.storeRef,
        checkoutRef: checkoutRef,
      ),
      current: current,
      reprint: reprint,
    );
  } catch (_) {
    debugPrint('cashier_print_failed_stage: $stage');
    // Payment remains successful even if receipt read, USB or paper output fails.
    return 'checkoutPrintFailed';
  }
}

/// Fixed 80mm output, shared by paid receipts and unpaid bills. No preview UI.
Future<String> printReceiptPlan({
  required ReceiptRasterPlan plan,
  required ReceiptPrintIdentity printIdentity,
  required bool Function() current,
  bool reprint = false,
}) async {
  return printRasterDocument(
    render: () async => [
      for (var page = 0; page < plan.pages.length; page++)
        (await plan.renderPage(page)).raster,
    ],
    printIdentity: printIdentity,
    current: current,
    reprint: reprint,
  );
}

Future<String> printRasterDocument({
  required Future<List<MonochromeRaster>> Function() render,
  required ReceiptPrintIdentity printIdentity,
  required bool Function() current,
  bool reprint = false,
}) async {
  try {
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
    final rasters = await render();
    if (!current()) return 'checkoutPrintFailed';
    final result =
        await RasterPrintCoordinator(
          transport: const NativeRasterPrintTransport(),
          enabled: const bool.fromEnvironment('CASHIER_USB_RASTER_OUTPUT'),
        ).printRasters(
          rasters: rasters,
          target: targets.single,
          documentIdentity: printIdentity,
          confirmed: true,
          confirmedReprint: reprint,
          cutAtEnd: true,
          compatibilityVerified: true,
          stillCurrent: current,
        );
    debugPrint('cashier_print_state: ${result.state}');
    return result.state == 'transport_accepted'
        ? 'checkoutPrintSent'
        : 'checkoutPrintFailed';
  } catch (_) {
    return 'checkoutPrintFailed';
  }
}

Future<String> printPaidOrderReceipt({
  required StaffAuthController auth,
  required String orderRef,
  required String tableRef,
  required String sessionRef,
  required UiLanguage language,
  required bool Function() stillCurrent,
}) async {
  final identity = auth.session;
  if (identity == null) return 'checkoutPrintFailed';
  bool current() =>
      stillCurrent() &&
      identical(identity, auth.session) &&
      identity.expiresAt.isAfter(DateTime.now());
  try {
    final document = await auth.readReceiptDocument(orderRef);
    if (!current() ||
        document.storeRef != identity.storeRef ||
        document.orderRef != orderRef ||
        document.tableRef != tableRef ||
        document.sessionRef != sessionRef)
      return 'checkoutPrintFailed';
    return await printReceiptPlan(
      plan: ReceiptRasterPlan.create(
        document,
        language: language,
        widthDots: 576,
        caption: await readReceiptCaption(auth, tableRef, sessionRef),
      ),
      printIdentity: ReceiptPrintIdentity(
        base: identity.base.toString(),
        storeRef: identity.storeRef,
        orderRef: orderRef,
      ),
      current: current,
      reprint: true,
    );
  } catch (_) {
    return 'checkoutPrintFailed';
  }
}
