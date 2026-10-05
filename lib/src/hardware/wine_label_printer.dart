import 'dart:ui' as ui;
import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import 'print_attempt_journal.dart';

import 'package:flutter/painting.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../auth/staff_auth_controller.dart';
import 'escpos_raster.dart';
import 'paid_receipt_printer.dart';
import 'receipt_print_identity.dart';

class WineLabel {
  WineLabel(Map<String, dynamic> value)
    : itemRef = value['itemRef'] as String,
      code = value['bottleCode'] as String,
      name = value['name'] as String,
      nickname = value['nickname'] as String,
      memberNumber = value['memberNumber'] as String,
      location = value['locationCode'] as String,
      specification = value['specification'] as String? ?? '',
      percent = (value['remainingPercent'] as num).toDouble(),
      expiresAt = DateTime.parse(value['expiresAt'] as String) {
    if (!RegExp(r'^KC:W:[0-9A-F]{32}$').hasMatch(code) ||
        name.isEmpty ||
        name.length > 128 ||
        nickname.length > 64 ||
        memberNumber.isEmpty ||
        memberNumber.length > 64 ||
        !RegExp(r'^[A-Z][1-9][0-9]*-[1-9][0-9]*$').hasMatch(location) ||
        percent <= 0 ||
        percent > 100) {
      throw const FormatException('WINE_LABEL_INVALID');
    }
  }
  final String itemRef,
      code,
      name,
      nickname,
      memberNumber,
      location,
      specification;
  final double percent;
  final DateTime expiresAt;

  /// 576 printable dots on existing 80mm paper, 216 content dots = 27mm at 203dpi, leaving cutter feed within a 35-40mm label.
  /// Firmware feed-to-cutter is additional and must be checked on the device.
  Future<MonochromeRaster> render({String? fontFamily}) async {
    final recorder = ui.PictureRecorder(), canvas = Canvas(recorder);
    canvas.drawRect(
      const Rect.fromLTWH(0, 0, 576, 216),
      Paint()..color = const Color(0xffffffff),
    );
    void line(
      String text,
      double y, {
      double size = 22,
      bool bold = false,
      int lines = 1,
    }) {
      final painter = TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(
            color: const Color(0xff000000),
            fontSize: size,
            fontFamily: fontFamily,
            fontWeight: bold ? FontWeight.bold : FontWeight.normal,
            height: 1.15,
          ),
        ),
        textDirection: TextDirection.ltr,
        maxLines: lines,
        ellipsis: '…',
      )..layout(maxWidth: 352);
      painter.paint(canvas, Offset(12, y));
      painter.dispose();
    }

    line('存酒  $location', 6, size: 26, bold: true);
    line(nickname.isEmpty ? '会员' : nickname, 37, size: 20, bold: true);
    line(memberNumber, 62, size: 18);
    line(name, 86, size: 20, bold: true, lines: 2);
    line(
      '$specification  剩余 ${percent.toStringAsFixed(percent == percent.roundToDouble() ? 0 : 1)}%',
      135,
      size: 18,
    );
    final expiry = expiresAt
        .toUtc()
        .add(const Duration(hours: 8))
        .toIso8601String()
        .substring(0, 16)
        .replaceFirst('T', ' ');
    line('到期 $expiry', 160, size: 17);
    line('取酒请扫瓶身码', 186, size: 16);
    final painter = QrPainter(
      data: code,
      version: QrVersions.auto,
      errorCorrectionLevel: QrErrorCorrectLevel.M,
      gapless: true,
      eyeStyle: const QrEyeStyle(
        eyeShape: QrEyeShape.square,
        color: Color(0xff000000),
      ),
      dataModuleStyle: const QrDataModuleStyle(
        dataModuleShape: QrDataModuleShape.square,
        color: Color(0xff000000),
      ),
    );
    // White quiet zone around all four edges.
    canvas.save();
    canvas.translate(386, 24);
    painter.paint(canvas, const Size(168, 168));
    canvas.restore();
    final picture = recorder.endRecording(),
        image = await picture.toImage(576, 216);
    final bytes = await image.toByteData(
      format: ui.ImageByteFormat.rawStraightRgba,
    );
    image.dispose();
    picture.dispose();
    if (bytes == null) throw const FormatException('WINE_LABEL_RENDER_FAILED');
    return MonochromeRaster.fromStraightRgba(
      width: 576,
      height: 216,
      rgba: bytes.buffer.asUint8List(),
    );
  }
}

Future<String> printWineLabel({
  required StaffAuthController auth,
  required WineLabel label,
  required bool Function() stillCurrent,
  bool reprint = false,
}) async {
  final identity = auth.session;
  if (identity == null) return 'checkoutPrintFailed';
  final printIdentity = ReceiptPrintIdentity.wineLabel(
    base: identity.base.toString(),
    storeRef: identity.storeRef,
    itemRef: label.itemRef,
  );
  if (!reprint) {
    final hash = await Sha256().hash(utf8.encode(printIdentity.canonical));
    final digest = hash.bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    final entries = await PrintAttemptJournal().load();
    final attempts = entries.where((e) => e.documentHash == digest).toList();
    if (attempts.isNotEmpty && attempts.last.state == 'transport_accepted')
      return 'checkoutPrintSent';
  }
  return printRasterDocument(
    render: () async => [await label.render()],
    printIdentity: ReceiptPrintIdentity.wineLabel(
      base: identity.base.toString(),
      storeRef: identity.storeRef,
      itemRef: label.itemRef,
    ),
    current: () =>
        stillCurrent() &&
        identical(identity, auth.session) &&
        identity.expiresAt.isAfter(DateTime.now()),
    reprint: reprint,
  );
}
