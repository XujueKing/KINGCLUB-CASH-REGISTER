import 'package:flutter/material.dart';

class SupplierCatalogDialog extends StatefulWidget {
  const SupplierCatalogDialog({
    super.key,
    required this.name,
    required this.load,
    required this.l,
  });
  final String name;
  final Future<Map<String, dynamic>> Function() load;
  final String Function(String, String, String, String) l;
  @override
  State<SupplierCatalogDialog> createState() => _SupplierCatalogDialogState();
}

class _SupplierCatalogDialogState extends State<SupplierCatalogDialog> {
  late final future = widget.load();
  String query = '', category = '';
  @override
  Widget build(BuildContext context) {
    final l = widget.l;
    return Dialog(
      backgroundColor: const Color(0xFFF5F4EF),
      child: SizedBox(
        width: 1040,
        height: 680,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${widget.name} · ${l('采购备选', 'Procurement catalog', '採購備選', 'รายการจัดซื้อ')}',
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                    tooltip: l('关闭', 'Close', '關閉', 'ปิด'),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              TextField(
                onChanged: (v) =>
                    setState(() => query = v.trim().toLowerCase()),
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search),
                  hintText: l(
                    '搜索名称或规格',
                    'Search name or size',
                    '搜尋名稱或規格',
                    'ค้นหาชื่อหรือขนาด',
                  ),
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              Expanded(
                child: FutureBuilder<Map<String, dynamic>>(
                  future: future,
                  builder: (context, snapshot) {
                    if (snapshot.hasError) {
                      return Center(
                        child: Text(
                          l(
                            '采购目录暂时无法读取',
                            'Could not load catalog',
                            '採購目錄暫時無法讀取',
                            'ไม่สามารถโหลดรายการได้',
                          ),
                        ),
                      );
                    }
                    if (!snapshot.hasData) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    final catalog =
                        snapshot.data!['catalog'] as Map<String, dynamic>?;
                    final sharedProducts =
                        snapshot.data!['sharedProducts'] as Map?;
                    final items = (catalog?['items'] as List? ?? [])
                        .whereType<Map>()
                        .map((e) => Map<String, dynamic>.from(e))
                        .toList();
                    if (items.isEmpty) {
                      return Center(
                        child: Text(
                          l(
                            '暂无采购备选商品',
                            'No procurement candidates',
                            '暫無採購備選商品',
                            'ยังไม่มีรายการจัดซื้อ',
                          ),
                        ),
                      );
                    }
                    final categories = items
                        .map((e) => '${e['category']}')
                        .toSet()
                        .toList();
                    final filtered = items
                        .where(
                          (e) =>
                              (category.isEmpty || e['category'] == category) &&
                              '${e['name']} ${e['specification']}'
                                  .toLowerCase()
                                  .contains(query),
                        )
                        .toList();
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          catalog?['complete'] == true
                              ? l(
                                  '供应商报价 · 仅供采购参考',
                                  'Supplier quotes · Procurement reference',
                                  '供應商報價 · 僅供採購參考',
                                  'ราคาอ้างอิงจากผู้จำหน่าย',
                                )
                              : l(
                                  '供应商报价 · 目录正在补齐',
                                  'Supplier quotes · Collection in progress',
                                  '供應商報價 · 目錄正在補齊',
                                  'กำลังรวบรวมรายการสินค้า',
                                ),
                          style: const TextStyle(color: Color(0xFF748078)),
                        ),
                        const SizedBox(height: 12),
                        Expanded(
                          child: Row(
                            children: [
                              SizedBox(
                                width: 132,
                                child: ListView(
                                  children: [
                                    for (final c in ['', ...categories])
                                      Padding(
                                        padding: const EdgeInsets.only(
                                          bottom: 8,
                                        ),
                                        child: Material(
                                          color: category == c
                                              ? const Color(0xFF183E35)
                                              : Colors.white,
                                          borderRadius: BorderRadius.circular(
                                            10,
                                          ),
                                          child: InkWell(
                                            onTap: () =>
                                                setState(() => category = c),
                                            child: Padding(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    vertical: 20,
                                                    horizontal: 12,
                                                  ),
                                              child: Text(
                                                c.isEmpty
                                                    ? l(
                                                        '全部',
                                                        'All',
                                                        '全部',
                                                        'ทั้งหมด',
                                                      )
                                                    : c,
                                                style: TextStyle(
                                                  color: category == c
                                                      ? Colors.white
                                                      : Colors.black87,
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 16),
                              Expanded(
                                child: ListView.separated(
                                  itemCount: filtered.length,
                                  separatorBuilder: (_, _) =>
                                      const SizedBox(height: 8),
                                  itemBuilder: (context, index) {
                                    final item = filtered[index];
                                    final quote = item['quoteCents'] as num?;
                                    final shared =
                                        sharedProducts?[item['sharedProductKey']]
                                            as Map?;
                                    final names = shared?['names'] as Map?;
                                    final fallback = '${item['name']}';
                                    final displayName = names == null
                                        ? fallback
                                        : l(
                                            '${names['zh-CN'] ?? fallback}',
                                            '${names['en'] ?? names['zh-CN'] ?? fallback}',
                                            '${names['zh-TW'] ?? names['zh-CN'] ?? fallback}',
                                            '${names['th'] ?? names['zh-CN'] ?? fallback}',
                                          );
                                    return Container(
                                      padding: const EdgeInsets.all(16),
                                      decoration: BoxDecoration(
                                        color: Colors.white,
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      child: Row(
                                        children: [
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  displayName,
                                                  style: const TextStyle(
                                                    fontSize: 18,
                                                    fontWeight: FontWeight.w600,
                                                  ),
                                                ),
                                                const SizedBox(height: 6),
                                                Text(
                                                  '${displayName == fallback ? '' : '$fallback · '}${item['specification']}',
                                                  style: const TextStyle(
                                                    color: Color(0xFF748078),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                          const SizedBox(width: 20),
                                          Text(
                                            quote == null
                                                ? l(
                                                    '待询价',
                                                    'Ask for quote',
                                                    '待詢價',
                                                    'สอบถามราคา',
                                                  )
                                                : '¥${(quote / 100).toStringAsFixed(2)} / ${item['quoteUnit']}',
                                            style: const TextStyle(
                                              fontSize: 19,
                                              fontWeight: FontWeight.bold,
                                              color: Color(0xFF183E35),
                                            ),
                                          ),
                                        ],
                                      ),
                                    );
                                  },
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
