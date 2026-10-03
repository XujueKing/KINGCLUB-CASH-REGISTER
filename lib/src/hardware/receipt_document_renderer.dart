import '../live/table_checkout_command.dart';

import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import '../live/receipt_document.dart';
import '../live/table_snapshot.dart';
import '../strings.dart';
import 'raster_preview.dart';

TextPainter _painter(String text, int width, String? font) => TextPainter(
  text: TextSpan(
    text: text,
    style: TextStyle(
      fontFamily: font,
      fontFamilyFallback: const ['Noto Sans Thai', 'Noto Sans CJK SC'],
      fontSize: 24,
      height: 1.4,
      color: const ui.Color(0xff000000),
    ),
  ),
  textDirection: ui.TextDirection.ltr,
)..layout(maxWidth: width - 32);

/// Memory-only bounded page plan. Render just the selected page on demand; never
/// allocate all full-size bitmap pages together on the ARM32 cashier device.
class ReceiptRasterPlan {
  ReceiptRasterPlan._(this.widthDots, this.fontFamily, this.header, this.pages);
  final int widthDots;
  final String? fontFamily;
  final List<String> header;
  final List<List<String>> pages;
  static const maxRows = 2048;

  factory ReceiptRasterPlan.create(
    ReceiptDocument document, {
    required UiLanguage language,
    required int widthDots,
    String? fontFamily,
  }) {
    if (widthDots < 192 || widthDots > 576 || widthDots % 8 != 0) {
      throw const FormatException('RECEIPT_WIDTH_INVALID');
    }
    String t(String key) => tr(language, key);
    String amount(String key, int cents) =>
        '${t(key)}: CNY ${formatCents(cents)}';
    final header = [
      'KINGCLUB POS',
      t('receiptDocumentTitle'),
      document.orderRef,
      t(
        document.partiallyRefunded
            ? 'receiptPartialRefund'
            : document.refunded
            ? 'liveRefunded'
            : 'order_paid',
      ),
    ];
    final blocks = <String>[
      '${document.storeRef} / ${document.tableRef}',
      document.sessionRef,
      '${t('receiptConfirmedAt')}: UTC ${document.confirmedAt.toIso8601String()}',
      '${t('liveObserved')}: UTC ${document.observedAt.toIso8601String()}',
      for (final item in document.items)
        '${item.name(language)} · ${item.specification(language)}\n'
            '${item.quantity} × CNY ${formatCents(item.priceCents)} = CNY ${formatCents(item.subtotalCents)}',
      t(
        document.channel == 'cash'
            ? 'receiptCash'
            : 'provider_${document.channel}',
      ),
      amount('orderPreviewTotal', document.totalCents),
      if (document.receivedCents != null)
        amount('cashReceived', document.receivedCents!),
      if (document.changeCents != null)
        amount('cashChange', document.changeCents!),
      if (document.accountType != null) ...[
        t('balance_${document.accountType}'),
        amount('receiptPrincipal', document.principalCents!),
        amount('receiptGift', document.giftCents!),
      ],
      amount('receiptRefundedAmount', document.refundedCents),
      amount('receiptNetAmount', document.netPaidCents),
      for (final refund in document.refunds) ...[
        '${t('liveRefunded')}: ${document.items.singleWhere((item) => item.productRef == refund.productRef).name(language)} x ${refund.quantity}',
        '${refund.reference} / UTC ${refund.refundedAt.toIso8601String()}',
        amount('receiptRefundedAmount', refund.totalCents),
        amount('refundPrincipal', refund.principalCents),
        amount('refundGift', refund.giftCents),
      ],
      if (document.refundRef != null) ...[
        '${t('liveRefunded')}: UTC ${document.refundedAt!.toIso8601String()}',
        document.refundRef!,
        amount('refundPrincipal', document.principalCents!),
        amount('refundGift', document.giftCents!),
      ],
      t('receiptPaperNotice'),
    ];
    return ReceiptRasterPlan._paginate(header, blocks, widthDots, fontFamily);
  }

  factory ReceiptRasterPlan.forTable(
    TableReceiptDocument document, {
    required UiLanguage language,
    required int widthDots,
    String? fontFamily,
  }) {
    String t(String key) => tr(language, key);
    String amount(String key, int cents) =>
        '${t(key)}: CNY ${formatCents(cents)}';
    final tender = document.tender;
    final header = [
      'KINGCLUB POS',
      t('tableReceiptTitle'),
      document.checkoutRef,
      t('order_paid'),
    ];
    final blocks = <String>[
      '${document.storeRef} / ${document.tableRef}', document.sessionRef,
      '${t('receiptConfirmedAt')}: UTC ${document.confirmedAt.toIso8601String()}',
      '${t('tableReceiptSettledAt')}: UTC ${document.settledAt.toIso8601String()}',
      '${t('liveObserved')}: UTC ${document.observedAt.toIso8601String()}',
      for (final order in document.orders) ...[
        '${order.orderRef}\n${amount('tableReceiptAllocation', order.allocatedCents)}',
        for (final item in order.items)
          '${item.name(language)} · ${item.specification(language)}\n'
              '${item.quantity} × CNY ${formatCents(item.priceCents)} = CNY ${formatCents(item.subtotalCents)}',
      ],
      // Exactly one parent tender; child amounts are allocations, not payments.
      t(
        tender.channel == 'cash' ? 'receiptCash' : 'provider_${tender.channel}',
      ),
      amount('orderPreviewTotal', document.totalCents),
      if (tender.receivedCents != null)
        amount('cashReceived', tender.receivedCents!),
      if (tender.changeCents != null) amount('cashChange', tender.changeCents!),
      if (tender.accountType != null) ...[
        t('balance_${tender.accountType}'),
        amount('receiptPrincipal', tender.principalCents!),
        amount('receiptGift', tender.giftCents!),
      ],
      t('receiptPaperNotice'),
    ];
    return ReceiptRasterPlan._paginate(header, blocks, widthDots, fontFamily);
  }

  factory ReceiptRasterPlan.unpaid(
    TableCheckoutQuote quote, {
    required UiLanguage language,
    required int widthDots,
  }) {
    String t(String key) => tr(language, key);
    return ReceiptRasterPlan._paginate(
      ['KINGCLUB', t('checkoutUnpaidTicket'), t('checkoutNotPaymentProof')],
      [
        quote.tableRef,
        quote.quotedAt.toLocal().toString(),
        for (final line in quote.lines)
          '${line.name(language)} × ${line.quantity}    ￥ ${formatCents(line.quantity * line.priceCents)}',
        '${t('checkoutDue')}: ￥ ${formatCents(quote.totalCents)}',
        t('checkoutNotPaymentProof'),
      ],
      widthDots,
      null,
    );
  }

  static ReceiptRasterPlan _paginate(
    List<String> header,
    List<String> blocks,
    int widthDots,
    String? fontFamily,
  ) {
    if (widthDots < 192 || widthDots > 576 || widthDots % 8 != 0) {
      throw const FormatException('RECEIPT_WIDTH_INVALID');
    }
    double height(String text) {
      final painter = _painter(text, widthDots, fontFamily);
      try {
        return painter.height + 12;
      } finally {
        painter.dispose();
      }
    }

    // Footer is bounded numeric page count (at most 32/32), not user text.
    final fixed =
        32 +
        header.fold<double>(0, (sum, text) => sum + height(text)) +
        height('32/32');
    final available = maxRows - fixed;
    if (available <= 0) throw const FormatException('RECEIPT_HEADER_TOO_TALL');
    final pages = <List<String>>[];
    var page = <String>[], used = 0.0;
    for (final block in blocks) {
      final rows = height(block);
      if (rows > available) {
        throw const FormatException('RECEIPT_BLOCK_TOO_TALL');
      }
      if (used + rows > available) {
        pages.add(List.unmodifiable(page));
        page = [];
        used = 0;
        if (pages.length >= 32) {
          throw const FormatException('RECEIPT_PAGE_LIMIT');
        }
      }
      page.add(block);
      used += rows;
    }
    if (page.isNotEmpty) pages.add(List.unmodifiable(page));
    if (pages.isEmpty || pages.length > 32) {
      throw const FormatException('RECEIPT_PAGE_LIMIT');
    }
    return ReceiptRasterPlan._(
      widthDots,
      fontFamily,
      List.unmodifiable(header),
      List.unmodifiable(pages),
    );
  }

  Future<RasterPreview> renderPage(int index) async {
    if (index < 0 || index >= pages.length) {
      throw const FormatException('RECEIPT_PAGE_INVALID');
    }
    final painters = <TextPainter>[];
    ui.Picture? picture;
    ui.Image? source;
    try {
      var height = 32.0;
      for (final text in [
        ...header,
        ...pages[index],
        '${index + 1}/${pages.length}',
      ]) {
        final painter = _painter(text, widthDots, fontFamily);
        painters.add(painter);
        height += painter.height + 12;
      }
      final rows = height.ceil();
      if (rows > maxRows) throw const FormatException('RECEIPT_PAGE_TOO_TALL');
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder)
        ..drawColor(const ui.Color(0xffffffff), ui.BlendMode.src);
      var y = 16.0;
      for (final painter in painters) {
        painter.paint(canvas, ui.Offset(16, y));
        y += painter.height + 12;
      }
      picture = recorder.endRecording();
      source = await picture.toImage(widthDots, rows);
      return await rasterPreview(source);
    } finally {
      source?.dispose();
      picture?.dispose();
      for (final painter in painters) {
        painter.dispose();
      }
    }
  }
}
