import 'package:flutter/material.dart';

/// The same store-scoped signed thumbnail used by the APP catalog.
String? productThumbnail(Object? raw, String storeRef) {
  if (raw is! Map ||
      raw['storeRef'] != storeRef ||
      raw['version'] != 'png-contour-v1' ||
      raw['files'] is! Map) {
    return null;
  }
  final link = raw['files']['image'] ?? raw['files']['thumbnail'];
  if (link is! String) return null;
  final uri = Uri.tryParse(link);
  if (uri == null ||
      uri.hasScheme ||
      uri.hasAuthority ||
      uri.hasFragment ||
      !RegExp(r'^/attachments/[a-fA-F0-9-]{36}$').hasMatch(uri.path) ||
      uri.queryParametersAll.length != 1 ||
      uri.queryParametersAll['token']?.length != 1 ||
      (uri.queryParameters['token']?.isEmpty ?? true)) {
    return null;
  }
  return link;
}

class ProductThumbnail extends StatelessWidget {
  const ProductThumbnail({super.key, required this.path, required this.base});
  final String? path;
  final Uri? base;
  @override
  Widget build(BuildContext context) {
    const fallback = Icon(
      Icons.local_bar_outlined,
      color: Color(0xff9aaca2),
      size: 24,
    );
    return Container(
      width: 48,
      height: 56,
      margin: const EdgeInsets.only(right: 8),
      child: path == null || base == null || base!.scheme != 'https'
          ? fallback
          : Image.network(
              productThumbnailUri(base!, path!).toString(),
              fit: BoxFit.contain,
              filterQuality: FilterQuality.high,
              errorBuilder: (_, _, _) => fallback,
            ),
    );
  }
}

Uri productThumbnailUri(Uri base, String path) {
  // The shared gateway routes attachments beneath the KINGCLUB service.
  // An explicitly configured service prefix takes precedence.
  final prefix = base.path.isEmpty || base.path == '/'
      ? const String.fromEnvironment(
          'CASHIER_MEDIA_PATH',
          defaultValue: '/kingclub-v2',
        )
      : base.path.replaceFirst(RegExp(r'/+$'), '');
  final link = Uri.parse(path);
  return base.replace(path: '$prefix${link.path}', query: link.query);
}
