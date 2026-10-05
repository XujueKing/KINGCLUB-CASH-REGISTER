import 'dart:ui' as ui;
import 'dart:math' as math;

import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';

import '../live/receipt_document.dart';
import '../live/table_checkout_command.dart';
import '../live/table_snapshot.dart';
import '../strings.dart';
import 'raster_preview.dart';

/// Display-only metadata; no internal references are substituted for missing names.
class ReceiptCaption {
  const ReceiptCaption({this.storeName, this.tableName, this.partySize});
  final String? storeName, tableName;
  final int? partySize;
}

class _Row {
  const _Row(
    this.cells, {
    this.size = 24,
    this.bold = false,
    this.center = false,
    this.rule = false,
    this.gap = 7,
  });
  final List<String> cells;
  final double size, gap;
  final bool bold, center, rule;
  String get text => cells.join('  ');
}

class ReceiptRasterPlan {
  ReceiptRasterPlan._(
    this.widthDots,
    this.fontFamily,
    this._header,
    this._pages,
  );
  final int widthDots;
  final String? fontFamily;
  final List<_Row> _header;
  final List<List<_Row>> _pages;
  List<String> get header => List.unmodifiable(_header.map((r) => r.text));
  List<List<String>> get pages => List.unmodifiable(
    _pages.map((p) => List<String>.unmodifiable(p.map((r) => r.text))),
  );
  static const maxRows = 2048;
  static const _logoHeight = 116.0;
  static const _rule = _Row([], rule: true, gap: 18);

  static String _label(
    UiLanguage l,
    String zh,
    String en,
    String tw,
    String th,
  ) => [zh, en, tw, th][l.index];
  static String _time(DateTime value) {
    // This store's business clock is China Standard Time, regardless of host TZ.
    final local = value.toUtc().add(const Duration(hours: 8));
    return local.toIso8601String().substring(0, 19).replaceFirst('T', ' ');
  }

  static List<_Row> _head(
    UiLanguage l,
    ReceiptCaption c,
    String title, {
    String? status,
    bool reprint = false,
  }) => [
    _Row([title], size: 40, bold: true, center: true),
    _Row(
      [c.storeName?.trim().isNotEmpty == true ? c.storeName! : 'KINGCLUB'],
      size: 28,
      bold: true,
      center: true,
    ),
    _Row(
      [_label(l, '[堂食]', '[Dine-in]', '[堂食]', '[ทานที่ร้าน]')],
      size: 28,
      center: true,
    ),
    if (reprint) _Row([tr(l, 'receiptReprint')], size: 20, center: true),
    if (status != null) _Row([status], size: 22, center: true),
    _rule,
    if (c.tableName != null)
      _Row(
        ['${_label(l, '桌号', 'Table', '桌號', 'โต๊ะ')}: ${c.tableName}'],
        size: 38,
        bold: true,
      ),
    if (c.partySize != null)
      _Row(['${_label(l, '人数', 'Guests', '人數', 'จำนวนคน')}: ${c.partySize}']),
  ];
  static _Row _money(String label, int cents, {bool large = false}) =>
      _Row([label, formatCents(cents)], size: large ? 34 : 24, bold: large);
  static _Row _columns(UiLanguage l) => _Row(
    [
      _label(l, '商品名称', 'Item', '商品名稱', 'สินค้า'),
      _label(l, '数量', 'Qty', '數量', 'จำนวน'),
      _label(l, '金额', 'Amount', '金額', 'ยอดเงิน'),
    ],
    size: 22,
    bold: true,
  );
  static _Row _item(
    UiLanguage language,
    String name,
    String spec,
    int qty,
    int price,
    int subtotal,
  ) => _Row([
    '$name${spec.isEmpty ? '' : '\n$spec'}\n${_label(language, '单价', 'Unit price', '單價', 'ราคาต่อหน่วย')} ${formatCents(price)}',
    '$qty',
    formatCents(subtotal),
  ], gap: 14);
  static _Row _footer(UiLanguage l) => _Row(
    [
      _label(
        l,
        '谢谢惠顾，欢迎下次光临',
        'Thank you. See you again!',
        '謝謝惠顧，歡迎下次光臨',
        'ขอบคุณที่ใช้บริการ',
      ),
    ],
    center: true,
    size: 22,
  );

  factory ReceiptRasterPlan.forTable(
    TableReceiptDocument d, {
    required UiLanguage language,
    required int widthDots,
    String? fontFamily,
    bool reprint = false,
    ReceiptCaption caption = const ReceiptCaption(),
  }) {
    String t(String key) => tr(language, key);
    final tender = d.tender;
    final rows = <_Row>[
      _Row([
        '${_label(language, '结账时间', 'Paid at', '結帳時間', 'เวลาชำระ')}: ${_time(d.settledAt)}',
      ], size: 22),
      _rule,
      _columns(language),
      for (final order in d.orders) ...[
        _Row([
          '${_label(language, '订单', 'Order', '訂單', 'คำสั่งซื้อ')}: ${order.orderRef}',
        ], size: 20),
        for (final item in order.items)
          _item(
            language,
            item.name(language),
            item.specification(language),
            item.quantity,
            item.priceCents,
            item.subtotalCents,
          ),
      ],
      _rule,
      _money(t('orderPreviewTotal'), d.totalCents),
      _money(
        _label(language, '实收金额', 'Amount paid', '實收金額', 'ยอดชำระแล้ว'),
        d.totalCents,
        large: true,
      ),
      _money(
        tender.channel == 'bank_code' ? _label(language, '银行码收款', 'Bank QR receipt', '銀行碼收款', 'รับเงินผ่าน QR ธนาคาร') : t(
          tender.channel == 'cash'
              ? 'receiptCash'
              : 'provider_${tender.channel}',
        ),
        d.totalCents,
      ),
      if (tender.receivedCents != null)
        _money(t('cashReceived'), tender.receivedCents!),
      if (tender.changeCents != null)
        _money(t('cashChange'), tender.changeCents!),
      if (tender.accountType != null) ...[
        _Row([t('balance_${tender.accountType}')]),
        _money(t('receiptPrincipal'), tender.principalCents!),
        _money(t('receiptGift'), tender.giftCents!),
      ],
      _rule,
      _footer(language),
    ];
    return _paginate(
      _head(
        language,
        caption,
        _label(language, '结账单', 'Receipt', '結帳單', 'ใบเสร็จ'),
        reprint: reprint,
      ),
      rows,
      widthDots,
      fontFamily,
    );
  }

  factory ReceiptRasterPlan.create(
    ReceiptDocument d, {
    required UiLanguage language,
    required int widthDots,
    String? fontFamily,
    ReceiptCaption caption = const ReceiptCaption(),
  }) {
    String t(String key) => tr(language, key);
    return _paginate(
      _head(
        language,
        caption,
        _label(language, '结账单', 'Receipt', '結帳單', 'ใบเสร็จ'),
        status: t(
          d.partiallyRefunded
              ? 'receiptPartialRefund'
              : d.refunded
              ? 'liveRefunded'
              : 'order_paid',
        ),
      ),
      [
        _Row([d.orderRef], size: 22),
        _Row(['${t('receiptConfirmedAt')}: ${_time(d.confirmedAt)}'], size: 22),
        _rule,
        _columns(language),
        for (final item in d.items)
          _item(
            language,
            item.name(language),
            item.specification(language),
            item.quantity,
            item.priceCents,
            item.subtotalCents,
          ),
        _rule,
        _money(t('orderPreviewTotal'), d.totalCents),
        _money(
          t(d.channel == 'cash' ? 'receiptCash' : 'provider_${d.channel}'),
          d.totalCents,
        ),
        if (d.receivedCents != null)
          _money(t('cashReceived'), d.receivedCents!),
        if (d.changeCents != null) _money(t('cashChange'), d.changeCents!),
        if (d.accountType != null) ...[
          _Row([t('balance_${d.accountType}')]),
          _money(t('receiptPrincipal'), d.principalCents!),
          _money(t('receiptGift'), d.giftCents!),
        ],
        if (d.refundedCents > 0)
          _money(t('receiptRefundedAmount'), d.refundedCents),
        _money(t('receiptNetAmount'), d.netPaidCents, large: true),
        for (final refund in d.refunds) ...[
          _Row([
            '${t('liveRefunded')}: ${d.items.singleWhere((i) => i.productRef == refund.productRef).name(language)} x ${refund.quantity}',
          ], size: 22),
          _Row([_time(refund.refundedAt)], size: 20),
          _money(t('receiptRefundedAmount'), refund.totalCents),
          _money(t('refundPrincipal'), refund.principalCents),
          _money(t('refundGift'), refund.giftCents),
        ],
        _rule,
        _footer(language),
      ],
      widthDots,
      fontFamily,
    );
  }

  factory ReceiptRasterPlan.unpaid(
    TableCheckoutQuote q, {
    required UiLanguage language,
    required int widthDots,
    ReceiptCaption caption = const ReceiptCaption(),
  }) => _paginate(
    _head(language, caption, tr(language, 'checkoutUnpaidTicket')),
    [
      _Row([_time(q.quotedAt)], size: 22),
      _Row([tr(language, 'checkoutNotPaymentProof')], size: 22),
      _rule,
      _columns(language),
      for (final line in q.lines)
        _item(
          language,
          line.name(language),
          '',
          line.quantity,
          line.priceCents,
          line.quantity * line.priceCents,
        ),
      _rule,
      _money(tr(language, 'checkoutDue'), q.totalCents, large: true),
      _rule,
      _footer(language),
    ],
    widthDots,
    null,
  );

  /// Current consumption list, including local selections. Never a payment proof.
  factory ReceiptRasterPlan.bill({
    required UiLanguage language,
    required ReceiptCaption caption,
    required String filterLabel,
    required List<
      ({
        String name,
        String specification,
        int quantity,
        int priceCents,
        String state,
      })
    >
    items,
  }) {
    final rows = <_Row>[
      _Row([filterLabel], center: true),
      _Row([
        _label(
          language,
          '消费清单，非付款凭证',
          'Bill, not proof of payment',
          '消費清單，非付款憑證',
          'รายการ ไม่ใช่หลักฐานชำระเงิน',
        ),
      ], size: 20),
      _Row([_time(DateTime.now())], size: 20),
      _rule,
      _columns(language),
    ];
    var total = 0;
    for (final item in items) {
      total += item.quantity * item.priceCents;
      rows.add(_Row([item.state], size: 20));
      rows.add(
        _item(
          language,
          item.name,
          item.specification,
          item.quantity,
          item.priceCents,
          item.quantity * item.priceCents,
        ),
      );
    }
    rows.addAll([
      _rule,
      _money(
        _label(language, '清单合计', 'Total', '清單合計', 'รวม'),
        total,
        large: true,
      ),
      _rule,
      _footer(language),
    ]);
    return _paginate(
      _head(
        language,
        caption,
        _label(language, '消费清单', 'Table bill', '消費清單', 'รายการสินค้า'),
      ),
      rows,
      576,
      null,
    );
  }

  static List<TextPainter> _painters(_Row row, int width, String? font) {
    final available = width - 32.0;
    final widths = row.cells.length == 3
        ? [available * .58 - 8, available * .17 - 8, available * .25]
        : row.cells.length == 2
        ? [available * .63 - 8, available * .37]
        : [available];
    return [
      for (var i = 0; i < row.cells.length; i++)
        TextPainter(
          text: TextSpan(
            text: row.cells[i],
            style: TextStyle(
              fontFamily: font,
              fontFamilyFallback: const ['Noto Sans Thai', 'Noto Sans CJK SC'],
              fontSize: row.size,
              height: 1.25,
              fontWeight: row.bold ? FontWeight.w700 : FontWeight.w400,
              color: const ui.Color(0xff000000),
            ),
          ),
          textAlign: row.center
              ? TextAlign.center
              : i == 0
              ? TextAlign.left
              : TextAlign.right,
          textDirection: ui.TextDirection.ltr,
        )..layout(minWidth: widths[i], maxWidth: widths[i]),
    ];
  }

  static double _height(_Row row, int width, String? font) {
    if (row.rule) return row.gap;
    final ps = _painters(row, width, font);
    try {
      return ps.fold<double>(0, (v, p) => math.max(v, p.height)) + row.gap;
    } finally {
      for (final p in ps) {
        p.dispose();
      }
    }
  }

  static ReceiptRasterPlan _paginate(
    List<_Row> header,
    List<_Row> rows,
    int width,
    String? font,
  ) {
    if (width < 192 || width > 576 || width % 8 != 0)
      throw const FormatException('RECEIPT_WIDTH_INVALID');
    final available =
        maxRows -
        72 -
        _logoHeight -
        header.fold<double>(0, (v, r) => v + _height(r, width, font));
    if (available <= 0) throw const FormatException('RECEIPT_HEADER_TOO_TALL');
    final pages = <List<_Row>>[];
    var page = <_Row>[], used = 0.0;
    for (final r in rows) {
      final h = _height(r, width, font);
      if (h > available) throw const FormatException('RECEIPT_BLOCK_TOO_TALL');
      if (used + h > available) {
        pages.add(List.unmodifiable(page));
        page = [];
        used = 0;
      }
      page.add(r);
      used += h;
    }
    if (page.isNotEmpty) pages.add(List.unmodifiable(page));
    if (pages.isEmpty || pages.length > 32)
      throw const FormatException('RECEIPT_PAGE_LIMIT');
    return ReceiptRasterPlan._(
      width,
      font,
      List.unmodifiable(header),
      List.unmodifiable(pages),
    );
  }

  Future<RasterPreview> renderPage(int index) async {
    if (index < 0 || index >= _pages.length)
      throw const FormatException('RECEIPT_PAGE_INVALID');
    final rows = [
      ..._header,
      ..._pages[index],
      if (_pages.length > 1)
        _Row(['${index + 1}/${_pages.length}'], center: true, size: 20),
    ];
    final height =
        (40 +
                _logoHeight +
                rows.fold<double>(
                  0,
                  (v, r) => v + _height(r, widthDots, fontFamily),
                ))
            .ceil();
    if (height > maxRows) throw const FormatException('RECEIPT_PAGE_TOO_TALL');
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder)
      ..drawColor(const ui.Color(0xffffffff), ui.BlendMode.src);
    final logoData = await rootBundle.load('assets/brand/kingclub-gold.png');
    final codec = await ui.instantiateImageCodec(
      logoData.buffer.asUint8List(
        logoData.offsetInBytes,
        logoData.lengthInBytes,
      ),
    );
    final logo = (await codec.getNextFrame()).image;
    try {
      const logoWidth = 192.0;
      final w = math.min(logoWidth, widthDots - 32.0);
      final h = w * logo.height / logo.width;
      canvas.drawImageRect(
        logo,
        ui.Rect.fromLTWH(0, 0, logo.width.toDouble(), logo.height.toDouble()),
        ui.Rect.fromLTWH((widthDots - w) / 2, 8, w, h),
        ui.Paint()
          ..filterQuality = ui.FilterQuality.high
          ..colorFilter = const ui.ColorFilter.mode(
            ui.Color(0xff000000),
            ui.BlendMode.srcIn,
          ),
      );
    } finally {
      logo.dispose();
      codec.dispose();
    }
    var y = 12.0 + _logoHeight;
    for (final row in rows) {
      if (row.rule) {
        final pen = ui.Paint()
          ..color = const ui.Color(0xff000000)
          ..strokeWidth = 1;
        for (var x = 16.0; x < widthDots - 16; x += 12) {
          canvas.drawLine(
            ui.Offset(x, y + 8),
            ui.Offset(math.min(x + 7, widthDots - 16.0), y + 8),
            pen,
          );
        }
        y += row.gap;
        continue;
      }
      final ps = _painters(row, widthDots, fontFamily);
      try {
        var x = 16.0;
        for (final p in ps) {
          p.paint(canvas, ui.Offset(x, y));
          x += p.width + 8;
        }
        y += ps.fold<double>(0, (v, p) => math.max(v, p.height)) + row.gap;
      } finally {
        for (final p in ps) {
          p.dispose();
        }
      }
    }
    final picture = recorder.endRecording();
    ui.Image? source;
    try {
      source = await picture.toImage(widthDots, height);
      return await rasterPreview(source);
    } finally {
      source?.dispose();
      picture.dispose();
    }
  }
}
