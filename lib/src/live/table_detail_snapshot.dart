import 'catalog_snapshot.dart';
import 'order_context_snapshot.dart';
import 'order_snapshot.dart';

/// One server snapshot for the bill, table context, wine, member badge and stock.
class TableDetailSnapshot {
  TableDetailSnapshot({
    required this.bill,
    this.context,
    required this.wine,
    required this.members,
    required this.products,
  });
  final OrderSnapshot bill;
  final OrderContextSnapshot? context;
  final List<Map<String, dynamic>> wine;
  final List<Map<String, String?>> members;
  final List<CatalogProduct> products;

  factory TableDetailSnapshot.parse(
    Object? raw, {
    required String storeRef,
    required String tableRef,
    required String sessionRef,
  }) {
    if (raw is! Map || raw['result'] is! Map) throw const FormatException();
    final result = Map<String, dynamic>.from(raw['result'] as Map);
    final workspace = result['workspace'];
    if (workspace is! Map ||
        workspace['storedWine'] is! List ||
        workspace['members'] is! List ||
        workspace['products'] is! List)
      throw const FormatException();
    final bill = OrderSnapshot.parse(
      {'result': result},
      storeRef: storeRef,
      tableRef: tableRef,
      sessionRef: sessionRef,
      maximumOrders: 500,
    );
    if (bill.nextAfterOrder != null) throw const FormatException();
    return TableDetailSnapshot(
      bill: bill,
      context: workspace['context'] == null
          ? null
          : OrderContextSnapshot.parse(
              {'result': workspace['context']},
              storeRef: storeRef,
              tableRef: tableRef,
              sessionRef: sessionRef,
            ),
      wine: List.unmodifiable(
        (workspace['storedWine'] as List).map(
          (v) => Map<String, dynamic>.from(v as Map),
        ),
      ),
      members: List.unmodifiable(
        (workspace['members'] as List).map((v) {
          final row = Map<String, dynamic>.from(v as Map);
          if (row['userAccount'] is! String ||
              !RegExp(r'^[A-Za-z0-9_-]{1,64}$')
                  .hasMatch(row['userAccount'] as String))
            throw const FormatException();
          return <String, String?>{
            'userAccount': row['userAccount'] as String,
            'nickname': row['nickname'] as String?,
            'avatarBase64': row['avatarBase64'] as String?,
          };
        }),
      ),
      products: List.unmodifiable(
        (workspace['products'] as List).map(
          (v) => CatalogProduct(
            Map<String, dynamic>.from(v as Map),
            storeRef: storeRef,
          ),
        ),
      ),
    );
  }
}
