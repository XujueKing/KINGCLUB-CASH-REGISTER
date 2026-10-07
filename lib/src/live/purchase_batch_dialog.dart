import 'package:flutter/material.dart';

typedef PurchaseText = String Function(String, String, String, String);

/// Local touch editing; one command saves/submits the whole application.
class PurchaseBatchDialog extends StatefulWidget {
  const PurchaseBatchDialog({
    super.key,
    required this.batch,
    required this.products,
    required this.suppliers,
    required this.locations,
    required this.l,
    required this.canWrite,
    required this.canReview,
    required this.command,
    required this.number,
    this.initialProduct,
    required this.attach,
  });
  final Map<String, dynamic> batch;
  final List<Map<String, dynamic>> products, suppliers;
  final List<String> locations;
  final PurchaseText l;
  final bool canWrite, canReview;
  final Map<String, dynamic>? initialProduct;
  final Future<Map<String, dynamic>> Function(Map<String, dynamic>) command;
  final Future<int?> Function(String, int, {bool cents}) number;
  final Future<Map<String, dynamic>?> Function(Map<String, dynamic>) attach;
  @override
  State<PurchaseBatchDialog> createState() => _PurchaseBatchDialogState();
}

class _PurchaseBatchDialogState extends State<PurchaseBatchDialog> {
  static const green = Color(0xFF183E35), muted = Color(0xFF748078);
  late Map<String, dynamic> batch;
  late List<Map<String, dynamic>> items;
  late final TextEditingController title;
  final search = TextEditingController();
  String query = '';
  bool busy = false, dirty = false;
  String? error;
  String t(String zh, String en, String tw, String th) =>
      widget.l(zh, en, tw, th);
  String get status => '${batch['status']}';
  bool get editable => status == 'draft' && widget.canWrite;
  String name(dynamic map) => map is Map
      ? t(
          '${map['zh-CN'] ?? map.values.firstOrNull ?? ''}',
          '${map['en'] ?? map['zh-CN'] ?? ''}',
          '${map['zh-TW'] ?? map['zh-CN'] ?? ''}',
          '${map['th'] ?? map['zh-CN'] ?? ''}',
        )
      : '';
  String productTitle(Map p) =>
      '${name(p['names'])} ${name(p['specifications'])}'.trim();
  String money(dynamic cents) => cents == null
      ? t('待询价', 'Ask for quote', '待詢價', 'สอบถามราคา')
      : '¥ ${((cents as num) / 100).toStringAsFixed(2)}';
  List<Map<String, dynamic>> quotes(Map p) => (p['quotes'] as List? ?? [])
      .map((x) => Map<String, dynamic>.from(x as Map))
      .toList();
  List<Map<String, dynamic>> get activeSuppliers => widget.suppliers
      .where((s) => s['active'] == 1 || s['active'] == true)
      .toList();
  @override
  void initState() {
    super.initState();
    batch = {...widget.batch};
    items = (batch['items'] as List? ?? [])
        .map((x) => Map<String, dynamic>.from(x as Map))
        .toList();
    title = TextEditingController(text: '${batch['title']}');
    if (widget.initialProduct != null && status == 'draft') {
      add(widget.initialProduct!, notify: false);
    }
  }

  @override
  void dispose() {
    title.dispose();
    search.dispose();
    super.dispose();
  }

  void priceFor(Map<String, dynamic> line, Map product, String supplier) {
    final candidates =
        quotes(product).where((q) => q['supplierRef'] == supplier).toList()
          ..sort(
            (a, b) => (a['unitCostCents'] as num? ?? double.infinity).compareTo(
              b['unitCostCents'] as num? ?? double.infinity,
            ),
          );
    final quote = candidates.firstOrNull;
    line['supplierRef'] = supplier;
    line['supplierName'] =
        activeSuppliers
            .where((s) => s['supplierRef'] == supplier)
            .firstOrNull?['name'] ??
        supplier;
    line['unitCostCents'] = quote?['unitCostCents'];
    line['quoteKey'] = quote?['key'];
    line['quote'] = quote;
    line['manualCost'] = false;
  }

  void add(Map<String, dynamic> product, {bool notify = true}) {
    if (busy) return;
    void update() {
      final preferred = (product['policy'] as Map?)?['supplierRef'];
      final supplier =
          activeSuppliers
              .where((s) => s['supplierRef'] == preferred)
              .firstOrNull?['supplierRef'] ??
          quotes(product).firstOrNull?['supplierRef'] ??
          activeSuppliers.firstOrNull?['supplierRef'];
      if (supplier == null) {
        error = t(
          '请先登记供应商',
          'Add a supplier first',
          '請先登記供應商',
          'เพิ่มผู้ขายก่อน',
        );
        return;
      }
      final existing = items
          .where(
            (i) =>
                i['productRef'] == product['productRef'] &&
                i['supplierRef'] == supplier,
          )
          .firstOrNull;
      if (existing != null) {
        existing['quantity'] = (existing['quantity'] as num).toInt() + 1;
      } else {
        final line = <String, dynamic>{
          'productRef': product['productRef'],
          'quantity': 1,
          'names': product['names'],
          'specifications': product['specifications'],
        };
        priceFor(line, product, '$supplier');
        items.add(line);
      }
      dirty = true;
      error = null;
    }

    if (notify) {
      setState(update);
    } else {
      update();
    }
  }

  Future<void> run(Map<String, dynamic> input) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      final result = await widget.command({
        ...input,
        if ('${input['action']}'.startsWith('purchase_batch_')) ...{
          'batchRef': batch['batchRef'],
          'revision': batch['revision'],
        },
      });
      if (!mounted) return;
      setState(() {
        batch = result;
        items = (batch['items'] as List? ?? [])
            .map((i) => Map<String, dynamic>.from(i as Map))
            .toList();
        dirty = false;
        error = null;
      });
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> save(bool submit) => run({
    'action': 'purchase_batch_save',
    'title': title.text.trim(),
    'submit': submit,
    'items': [
      for (final i in items)
        {
          'productRef': i['productRef'],
          'supplierRef': i['supplierRef'],
          'quantity': i['quantity'],
          'unitCostCents': i['unitCostCents'],
          'manualCost': i['manualCost'] ?? false,
          if (i['quoteKey'] != null) 'quoteKey': i['quoteKey'],
        },
    ],
  });
  Future<void> close() async {
    if (busy) return;
    if (dirty) {
      await save(false);
      if (dirty || !mounted) return;
    }
    if (mounted) Navigator.pop(context);
  }

  Future<void> edit(Map<String, dynamic> line) async {
    if (busy) return;
    final product = widget.products
        .where((p) => p['productRef'] == line['productRef'])
        .firstOrNull;
    if (product == null) return;
    final copy = {...line};
    copy['quote'] ??= quotes(product)
        .where((q) => q['key'] == copy['quoteKey'])
        .firstOrNull;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: Text(productTitle(line)),
          content: SizedBox(
            width: 500,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<String>(
                  initialValue: '${copy['supplierRef']}',
                  decoration: InputDecoration(
                    labelText: t('供应商', 'Supplier', '供應商', 'ผู้ขาย'),
                    border: const OutlineInputBorder(),
                  ),
                  items: [
                    for (final s in activeSuppliers)
                      DropdownMenuItem(
                        value: '${s['supplierRef']}',
                        child: Text('${s['name']}'),
                      ),
                  ],
                  onChanged: (v) {
                    if (v != null) set(() => priceFor(copy, product, v));
                  },
                ),
                const SizedBox(height: 16),
                if (copy['quote'] is Map)
                  Text(
                    '${t('供应商报价', 'Supplier quote', '供應商報價', 'ราคาอ้างอิง')}: ${money(copy['quote']['quoteCents'])} / ${copy['quote']['quoteUnit']} · ${copy['quote']['specification']}',
                    style: const TextStyle(color: muted),
                  ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: touch(
                        '${t('采购数量', 'Quantity', '採購數量', 'จำนวน')}\n${copy['quantity']}',
                        () async {
                          final v = await widget.number(
                            t('采购数量', 'Quantity', '採購數量', 'จำนวน'),
                            (copy['quantity'] as num).toInt(),
                            cents: false,
                          );
                          if (v != null && v > 0) {
                            set(() => copy['quantity'] = v);
                          }
                        },
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: touch(
                        '${t('进货单价', 'Unit cost', '進貨單價', 'ต้นทุน')}\n${money(copy['unitCostCents'])}',
                        () async {
                          final v = await widget.number(
                            t('进货单价', 'Unit cost', '進貨單價', 'ต้นทุน'),
                            (copy['unitCostCents'] as num? ?? 0).toInt(),
                            cents: true,
                          );
                          if (v != null) {
                            set(() {
                              copy['unitCostCents'] = v;
                              copy['manualCost'] = true;
                            });
                          }
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  t(
                    '按瓶／支等库存单位采购；价格不明时先询价。',
                    'Buy in stock units; confirm an unknown cost first.',
                    '按瓶／支等庫存單位採購；價格不明時先詢價。',
                    'ซื้อเป็นหน่วยสต็อก ตรวจราคาก่อน',
                  ),
                  style: const TextStyle(color: muted),
                ),
              ],
            ),
          ),
          actions: [
            touch(t('取消', 'Cancel', '取消', 'ยกเลิก'), () => Navigator.pop(ctx)),
            touch(
              t('确定', 'Save', '確定', 'บันทึก'),
              () => Navigator.pop(ctx, true),
              primary: true,
            ),
          ],
        ),
      ),
    );
    if (ok == true && mounted) {
      final duplicate = items.any(
        (i) =>
            !identical(i, line) &&
            i['productRef'] == copy['productRef'] &&
            i['supplierRef'] == copy['supplierRef'],
      );
      setState(() {
        if (duplicate) {
          error = t(
            '该供应商的同款已在批次中，请调整原行',
            'This supplier item is already in this batch',
            '該供應商的同款已在批次中，請調整原行',
            'มีสินค้านี้ในชุดแล้ว',
          );
        } else {
          line
            ..clear()
            ..addAll(copy);
          dirty = true;
          error = null;
        }
      });
    }
  }

  Future<void> receive(Map<String, dynamic> line) async {
    int quantity =
        (line['quantity'] as num).toInt() -
        (line['received'] as num? ?? 0).toInt();
    String location = widget.locations.firstOrNull ?? '';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: Text(
            t('确认收货入库', 'Confirm receipt', '確認收貨入庫', 'ยืนยันรับสินค้า'),
          ),
          content: SizedBox(
            width: 480,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  productTitle(line),
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 16),
                touch(
                  '${t('本次收货', 'Receive now', '本次收貨', 'รับครั้งนี้')} $quantity',
                  () async {
                    final v = await widget.number(
                      t('本次收货', 'Receive now', '本次收貨', 'รับครั้งนี้'),
                      quantity,
                      cents: false,
                    );
                    if (v != null) set(() => quantity = v);
                  },
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  initialValue: location.isEmpty ? null : location,
                  decoration: InputDecoration(
                    labelText: t('入库柜格', 'Cabinet', '入庫櫃格', 'ช่องเก็บ'),
                    border: const OutlineInputBorder(),
                  ),
                  items: [
                    for (final l in widget.locations)
                      DropdownMenuItem(value: l, child: Text(l)),
                  ],
                  onChanged: (v) => set(() => location = v ?? ''),
                ),
                const SizedBox(height: 16),
                Text(
                  t(
                    '凭证可后补，不影响本次收货。',
                    'Documents may be added later.',
                    '憑證可後補，不影響本次收貨。',
                    'เพิ่มเอกสารภายหลังได้',
                  ),
                  style: const TextStyle(color: muted),
                ),
              ],
            ),
          ),
          actions: [
            touch(t('取消', 'Cancel', '取消', 'ยกเลิก'), () => Navigator.pop(ctx)),
            touch(
              t('确认入库', 'Receive', '確認入庫', 'รับเข้า'),
              quantity > 0 &&
                      quantity <=
                          (line['quantity'] as num) -
                              (line['received'] as num? ?? 0) &&
                      location.isNotEmpty
                  ? () => Navigator.pop(ctx, true)
                  : null,
              primary: true,
            ),
          ],
        ),
      ),
    );
    if (ok == true) {
      await run({
        'action': 'receive',
        'relatedRef': line['purchaseRef'],
        'quantity': quantity,
        'location': location,
      });
    }
  }

  Widget touch(String text, VoidCallback? action, {bool primary = false}) =>
      FilledButton.tonal(
        onPressed: busy ? null : action,
        style: FilledButton.styleFrom(
          minimumSize: const Size(108, 52),
          backgroundColor: primary ? green : null,
          foregroundColor: primary ? Colors.white : null,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
        child: Text(text, textAlign: TextAlign.center),
      );
  String get statusText => switch (status) {
    'draft' => t('草稿', 'Draft', '草稿', 'ฉบับร่าง'),
    'pending' => t('待批准', 'Awaiting approval', '待批准', 'รออนุมัติ'),
    'approved' => t(
      '已批准 · 待采购',
      'Approved · order next',
      '已批准 · 待採購',
      'อนุมัติแล้ว',
    ),
    'ordered' => t(
      '已采购 · 待入库',
      'Ordered · receive next',
      '已採購 · 待入庫',
      'รอรับสินค้า',
    ),
    'received' => t('已收齐', 'Received', '已收齊', 'รับครบแล้ว'),
    _ => t('已取消', 'Cancelled', '已取消', 'ยกเลิกแล้ว'),
  };
  @override
  Widget build(BuildContext context) {
    final filtered = widget.products
        .where((p) => productTitle(p).toLowerCase().contains(query))
        .toList();
    final total = items.fold<num>(
      0,
      (sum, i) =>
          sum + (i['quantity'] as num) * (i['unitCostCents'] as num? ?? 0),
    );
    return PopScope(
      canPop: !dirty && !busy,
      child: Dialog(
        insetPadding: const EdgeInsets.all(24),
        child: SizedBox(
          width: 1120,
          height: 620,
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: editable
                          ? TextField(
                              controller: title,
                              enabled: !busy,
                              onChanged: (_) => dirty = true,
                              style: const TextStyle(
                                fontSize: 23,
                                fontWeight: FontWeight.bold,
                              ),
                              decoration: const InputDecoration(
                                border: InputBorder.none,
                              ),
                            )
                          : Text(
                              '${batch['title']}',
                              style: const TextStyle(
                                fontSize: 23,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                    ),
                    Text(
                      statusText,
                      style: const TextStyle(
                        fontSize: 16,
                        color: green,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: 12),
                    IconButton(
                      onPressed: busy ? null : close,
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    t(
                      '申请 → 批准 → 采购 → 收货入库',
                      'Apply → approve → order → receive',
                      '申請 → 批准 → 採購 → 收貨入庫',
                      'คำขอ → อนุมัติ → ซื้อ → รับเข้า',
                    ),
                    style: const TextStyle(color: muted),
                  ),
                ),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      error!,
                      style: const TextStyle(color: Colors.red),
                    ),
                  ),
                const SizedBox(height: 16),
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (editable) ...[
                        Expanded(
                          flex: 4,
                          child: Column(
                            children: [
                              TextField(
                                controller: search,
                                onChanged: (v) => setState(
                                  () => query = v.trim().toLowerCase(),
                                ),
                                decoration: InputDecoration(
                                  prefixIcon: const Icon(Icons.search),
                                  hintText: t(
                                    '选择商品添加到批次',
                                    'Add products to this batch',
                                    '選擇商品添加到批次',
                                    'เพิ่มสินค้าในชุด',
                                  ),
                                  border: const OutlineInputBorder(),
                                  isDense: true,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Expanded(
                                child: ListView.builder(
                                  itemCount: filtered.length,
                                  itemBuilder: (ctx, index) {
                                    final p = filtered[index];
                                    return ListTile(
                                      key: ValueKey(
                                        'purchase-product-${p['productRef']}',
                                      ),
                                      contentPadding:
                                          const EdgeInsets.symmetric(
                                            horizontal: 8,
                                            vertical: 8,
                                          ),
                                      title: Text(
                                        productTitle(p),
                                        style: const TextStyle(fontSize: 16),
                                      ),
                                      subtitle: Text(
                                        quotes(p).isEmpty
                                            ? t(
                                                '暂无对应报价',
                                                'No matching quote',
                                                '暫無對應報價',
                                                'ไม่มีราคา',
                                              )
                                            : money(
                                                quotes(p)
                                                    .first['unitCostCents'],
                                              ),
                                      ),
                                      trailing: const Icon(
                                        Icons.add_circle_outline,
                                        color: green,
                                      ),
                                      onTap: () => add(p),
                                    );
                                  },
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 20),
                        const VerticalDivider(width: 1),
                        const SizedBox(width: 20),
                      ],
                      Expanded(
                        flex: 5,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    '${t('采购清单', 'Purchase list', '採購清單', 'รายการซื้อ')} · ${items.length}',
                                    style: const TextStyle(
                                      fontSize: 19,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                                Text(
                                  '${t('预计', 'Estimate', '預計', 'ประมาณ')} ${money(total)}',
                                  style: const TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            Expanded(
                              child: items.isEmpty
                                  ? Center(
                                      child: Text(
                                        t(
                                          '从左侧依次添加需要采购的商品',
                                          'Add products from the left',
                                          '從左側依次添加需要採購的商品',
                                          'เลือกสินค้าจากด้านซ้าย',
                                        ),
                                        style: const TextStyle(color: muted),
                                      ),
                                    )
                                  : ListView.separated(
                                      itemCount: items.length,
                                      separatorBuilder: (_, _) =>
                                          const SizedBox(height: 8),
                                      itemBuilder: (ctx, index) {
                                        final i = items[index];
                                        return Material(
                                          color: const Color(0xFFF1F4EE),
                                          borderRadius: BorderRadius.circular(
                                            12,
                                          ),
                                          child: InkWell(
                                            key: ValueKey(
                                              'purchase-line-${i['productRef']}-${i['supplierRef']}',
                                            ),
                                            onTap: editable && !busy
                                                ? () => edit(i)
                                                : null,
                                            borderRadius: BorderRadius.circular(
                                              12,
                                            ),
                                            child: Padding(
                                              padding: const EdgeInsets.all(14),
                                              child: Row(
                                                children: [
                                                  Expanded(
                                                    child: Column(
                                                      crossAxisAlignment:
                                                          CrossAxisAlignment
                                                              .start,
                                                      children: [
                                                        Text(
                                                          productTitle(i),
                                                          style:
                                                              const TextStyle(
                                                                fontSize: 17,
                                                                fontWeight:
                                                                    FontWeight
                                                                        .w600,
                                                              ),
                                                        ),
                                                        const SizedBox(
                                                          height: 7,
                                                        ),
                                                        Text(
                                                          '${i['supplierName']} · ${money(i['unitCostCents'])} × ${i['quantity']}',
                                                          style:
                                                              const TextStyle(
                                                                color: muted,
                                                              ),
                                                        ),
                                                        if (status ==
                                                                'ordered' ||
                                                            status ==
                                                                'received')
                                                          Text(
                                                            '${t('已收', 'Received', '已收', 'รับแล้ว')} ${i['received'] ?? 0} / ${i['quantity']}',
                                                            style:
                                                                const TextStyle(
                                                                  color: green,
                                                                ),
                                                          ),
                                                      ],
                                                    ),
                                                  ),
                                                  if (editable)
                                                    IconButton(
                                                      onPressed: busy
                                                          ? null
                                                          : () => setState(() {
                                                              items.removeAt(
                                                                index,
                                                              );
                                                              dirty = true;
                                                            }),
                                                      icon: const Icon(
                                                        Icons
                                                            .remove_circle_outline,
                                                      ),
                                                    ),
                                                  if (status == 'ordered' &&
                                                      (i['received'] as num? ??
                                                              0) <
                                                          (i['quantity']
                                                              as num))
                                                    touch(
                                                      t(
                                                        '确认收货',
                                                        'Receive',
                                                        '確認收貨',
                                                        'รับสินค้า',
                                                      ),
                                                      widget.canWrite
                                                          ? () => receive(i)
                                                          : null,
                                                      primary: true,
                                                    ),
                                                ],
                                              ),
                                            ),
                                          ),
                                        );
                                      },
                                    ),
                            ),
                            if ((batch['document'] as Map?)?['number']
                                case final String number)
                              Text(
                                '${t('凭证号', 'Document', '憑證號', 'เอกสาร')}: $number',
                                style: const TextStyle(color: muted),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 18),
                Row(
                  children: [
                    if (widget.canWrite)
                      touch(
                        t('补凭证', 'Add document', '補憑證', 'เพิ่มเอกสาร'),
                        () async {
                          if (dirty) {
                            await save(false);
                            if (dirty || !mounted) return;
                          }
                          final doc = await widget.attach(
                            Map<String, dynamic>.from(
                              batch['document'] as Map? ?? {},
                            ),
                          );
                          if (doc != null) {
                            await run({
                              'action': 'purchase_batch_document',
                              'document': doc,
                            });
                          }
                        },
                      ),
                    const Spacer(),
                    if (busy)
                      const Padding(
                        padding: EdgeInsets.only(right: 18),
                        child: SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    if (editable) ...[
                      touch(
                        t('保存草稿', 'Save draft', '儲存草稿', 'บันทึกร่าง'),
                        () => save(false),
                      ),
                      const SizedBox(width: 12),
                      touch(
                        t('提交申请', 'Submit application', '提交申請', 'ส่งคำขอ'),
                        items.isEmpty ? null : () => save(true),
                        primary: true,
                      ),
                    ],
                    if (status == 'pending' && widget.canReview) ...[
                      touch(
                        t('退回修改', 'Return to draft', '退回修改', 'แก้ไข'),
                        () => run({
                          'action': 'purchase_batch_review',
                          'approved': false,
                        }),
                      ),
                      const SizedBox(width: 12),
                      touch(
                        t('批准采购', 'Approve', '批准採購', 'อนุมัติ'),
                        () => run({
                          'action': 'purchase_batch_review',
                          'approved': true,
                        }),
                        primary: true,
                      ),
                    ],
                    if (status == 'pending' && !widget.canReview)
                      Text(
                        t(
                          '等待管理员批准',
                          'Awaiting administrator approval',
                          '等待管理員批准',
                          'รอผู้ดูแลอนุมัติ',
                        ),
                        style: const TextStyle(color: muted),
                      ),
                    if (status == 'approved' && widget.canWrite)
                      touch(
                        t(
                          '确认已采购',
                          'Confirm ordered',
                          '確認已採購',
                          'ยืนยันสั่งซื้อ',
                        ),
                        () => run({'action': 'purchase_batch_order'}),
                        primary: true,
                      ),
                    if (status == 'ordered')
                      Text(
                        t(
                          '逐项确认收货，支持分批到货',
                          'Receive each line; partial deliveries supported',
                          '逐項確認收貨，支援分批到貨',
                          'รับสินค้าแต่ละรายการได้',
                        ),
                        style: const TextStyle(color: muted),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
