import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'escpos_raster.dart';
import 'print_attempt_journal.dart';
import 'usb_printer_permission.dart';
import 'receipt_print_identity.dart';

/// Must revalidate current attachment, interface, permission and foreground state
/// before writing, with bounded USB operations. Never retries a partial write.
abstract interface class RasterPrintTransport {
  Future<int> send(
    UsbPrinterSelection target,
    Uint8List bytes,
    String attemptId,
  );
}

/// No default transport or automatic activation. A printer model's raster support
/// and buffer preconditions must be verified before enabling this coordinator.
class RasterPrintCoordinator {
  RasterPrintCoordinator({
    required this.transport,
    PrintAttemptJournal? journal,
    this.enabled = false,
  }) : journal = journal ?? PrintAttemptJournal();
  final RasterPrintTransport transport;
  final PrintAttemptJournal journal;
  final bool enabled;
  static bool _busy = false;

  Future<PrintAttempt> printRaster({
    required MonochromeRaster raster,
    required UsbPrinterSelection target,
    required bool confirmed,
    required bool compatibilityVerified,
    required bool Function() stillCurrent,
  }) => printRasters(rasters: [raster], target: target, confirmed: confirmed,
    compatibilityVerified: compatibilityVerified, stillCurrent: stillCurrent);

  /// All pages share one durable send fence. Stops at the first short/unknown
  /// response; never acknowledges earlier pages as a completed document.
  Future<PrintAttempt> printRasters({
    ReceiptPrintIdentity? documentIdentity,
    required List<MonochromeRaster> rasters,
    required UsbPrinterSelection target,
    required bool confirmed,
    required bool compatibilityVerified,
    required bool Function() stillCurrent,
  }) async {
    if (!enabled || !confirmed || !compatibilityVerified || !stillCurrent()) {
      throw const FormatException('PRINT_NOT_AUTHORIZED');
    }
    if (_busy) throw const FormatException('PRINT_IN_PROGRESS');
    _busy = true;
    try {
      // Immutable encoder output only; callers cannot inject cut/drawer commands.
      if (rasters.isEmpty || rasters.length > 32 ||
          rasters.any((page) => page.width != rasters.first.width || (rasters.length > 1 && page.height > 2048))) {
        throw const FormatException('PRINT_DOCUMENT_INVALID');
      }
      // Copy the caller's page collection synchronously before the first await.
      // Encoder buffers are immutable and are not persisted with customer data.
      final pages = List<Uint8List>.unmodifiable(rasters.map(encodeGsV0));
      final byteCount = pages.fold<int>(0, (sum, page) => sum + page.length);
      if (byteCount > PrintAttempt.maxDocumentBytes) throw const FormatException('PRINT_DOCUMENT_TOO_LARGE');
      final combined = BytesBuilder(copy: false);
      for (final page in pages) { combined.add(page); }
      final contentHash = await _hash(combined.takeBytes());
      final documentHash = documentIdentity == null ? null : await _hash(utf8.encode(documentIdentity.canonical));
      final targetHash = await _hash(
        utf8.encode(
          jsonEncode({
            'deviceId': target.device.deviceId,
            'vendorId': target.device.vendorId,
            'productId': target.device.productId,
            'deviceClass': target.device.deviceClass,
            'interfaceId': target.interface.id,
            'alternate': target.interface.alternate,
            'class': target.interface.classCode,
            'subclass': target.interface.subclass,
            'protocol': target.interface.protocol,
            'endpoint': target.endpoint.address,
            'type': target.endpoint.type,
            'maxPacketSize': target.endpoint.maxPacketSize,
          }),
        ),
      );
      if (!stillCurrent()) throw const FormatException('PRINT_CONTEXT_CHANGED');
      final random = Random.secure();
      final id = List.generate(
        16,
        (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();
      await journal.prepare(
        id: id,
        contentHash: contentHash,
        targetHash: targetHash,
        byteCount: byteCount,
        documentHash: documentHash,
      );
      if (!stillCurrent()) {
        await journal.cancelPrepared(id);
        throw const FormatException('PRINT_CONTEXT_CHANGED');
      }
      await journal.beginSend(
        id,
        contentHash: contentHash,
        targetHash: targetHash,
        confirmed: confirmed,
      );
      int? accepted;
      try {
        accepted = 0;
        final clock = Stopwatch()..start();
        try {
          for (var index = 0; index < pages.length; index++) {
            // Native duplicate guards need distinct page IDs, derived from the
            // durable group ID rather than independent random retry commands.
            final pageId = pages.length == 1 ? id :
              (await _hash(utf8.encode('$id:$index'))).substring(0, 32);
            if (!stillCurrent()) throw const FormatException('PRINT_CONTEXT_CHANGED');
            final remaining = const Duration(seconds: 120) - clock.elapsed;
            if (remaining <= Duration.zero) throw const FormatException('PRINT_DOCUMENT_TIMEOUT');
            final timeout = remaining < const Duration(seconds: 30) ? remaining : const Duration(seconds: 30);
            final count = await transport.send(target, pages[index], pageId).timeout(timeout);
            if (count != pages[index].length) throw const FormatException('PRINT_PARTIAL_PAGE');
            accepted = accepted! + count;
          }
        } finally { clock.stop(); }
      } catch (_) {
        // Includes errors reporting zero output. A late transport completion must
        // never automatically retry or upgrade an unknown durable result.
        accepted = null;
      }
      await journal.finish(id, acceptedBytes: accepted);
      final saved = (await journal.load()).where((e) => e.id == id).toList();
      if (saved.length != 1) {
        throw const FormatException('PRINT_RESULT_UNAVAILABLE');
      }
      return saved.single;
    } catch (_) {
      // Native/storage exceptions can contain paths or customer information.
      throw const FormatException('PRINT_ATTEMPT_REVIEW_REQUIRED');
    } finally {
      _busy = false;
    }
  }

  static Future<String> _hash(List<int> bytes) async =>
      (await Sha256().hash(bytes)).bytes
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
}
