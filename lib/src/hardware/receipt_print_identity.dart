import 'dart:convert';

/// Stable logical receipt scope; intentionally excludes language, width,
/// observation time, refund status, employee and printer choice.
class ReceiptPrintIdentity {
  ReceiptPrintIdentity({
    required this.base,
    required this.storeRef,
    required this.orderRef,
  }) : isTable = false {
    final uri = Uri.tryParse(base);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        !RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(storeRef) ||
        !RegExp(r'^D[0-9]{11}$').hasMatch(orderRef)) {
      throw const FormatException('RECEIPT_PRINT_SCOPE_INVALID');
    }
  }
  ReceiptPrintIdentity.forTable({
    required this.base,
    required this.storeRef,
    required String checkoutRef,
  }) : orderRef = checkoutRef,
       isTable = true {
    final uri = Uri.tryParse(base);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        !RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(storeRef) ||
        !RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        ).hasMatch(checkoutRef)) {
      throw const FormatException('RECEIPT_PRINT_SCOPE_INVALID');
    }
  }
  ReceiptPrintIdentity.unpaid({
    required this.base,
    required this.storeRef,
    required String fingerprint,
  }) : orderRef = 'unpaid:$fingerprint',
       isTable = false {
    final uri = Uri.tryParse(base);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        !RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(storeRef) ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(fingerprint)) {
      throw const FormatException('RECEIPT_PRINT_SCOPE_INVALID');
    }
  }
  ReceiptPrintIdentity.wineLabel({
    required this.base,
    required this.storeRef,
    required String itemRef,
  }) : orderRef = 'wine-label:$itemRef',
       isTable = false {
    final uri = Uri.tryParse(base);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        !RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(storeRef) ||
        !RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        ).hasMatch(itemRef)) {
      throw const FormatException('WINE_LABEL_SCOPE_INVALID');
    }
  }
  final bool isTable;
  final String base, storeRef, orderRef;
  String get canonical => jsonEncode([
    isTable ? 'table-receipt-v1' : 'receipt-v1',
    base,
    storeRef,
    orderRef,
  ]);
}
