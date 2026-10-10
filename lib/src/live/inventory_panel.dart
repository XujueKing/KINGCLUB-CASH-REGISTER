import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../auth/staff_auth_controller.dart';
import '../hardware/scanner_input.dart';
import '../network/cashier_realtime_client.dart';
import '../network/ccsop_client.dart';
import '../scan_icon.dart';
import '../strings.dart';
import 'supplier_catalog_dialog.dart';
import 'purchase_batch_dialog.dart';
import 'retail_price_dialog.dart';
import 'workspace_read_cache.dart';
import 'inventory_page_cache.dart';

class InventoryPanel extends StatefulWidget {
  const InventoryPanel({
    super.key,
    required this.auth,
    required this.language,
    this.enableRealtime = true,
  });
  final StaffAuthController auth;
  final UiLanguage language;
  final bool enableRealtime;
  @override
  State<InventoryPanel> createState() => _InventoryPanelState();
}

class _InventoryPanelState extends State<InventoryPanel> {
  static const green = Color(0xFF183E35),
      paper = Color(0xFFF5F4EF),
      muted = Color(0xFF748078);
  final search = TextEditingController();
  String category = '', stockFilter = 'all', movementFilter = 'all';
  List<Map<String, dynamic>> get visibleProducts => rows('products')
      .where(
        (p) =>
            (category.isEmpty ||
                (category == '_uncategorized'
                    ? p['categoryRef'] == null
                    : p['categoryRef'] == category)) &&
            (stockFilter == 'all' ||
                (stockFilter == 'empty'
                    ? (p['available'] as num? ?? 0) <= 0
                    : p['lowStock'] == true || p['lowStock'] == 1)) &&
            '${name(p['names'])} ${name(p['specifications'])}'
                .toLowerCase()
                .contains(search.text.trim().toLowerCase()),
      )
      .toList();
  void filterChanged(VoidCallback change) => setState(() {
    change();
    if (!visibleProducts.any((p) => p['productRef'] == selected)) selected = '';
  });
  Widget productFilters({bool categoryRail = false}) {
    final categories = rows('categories')
      ..sort(
        (a, b) => (a['sortOrder'] as num? ?? 0).compareTo(
          b['sortOrder'] as num? ?? 0,
        ),
      );
    final options = <(String, String)>[
      ('', l('全部', 'All', '全部', 'ทั้งหมด')),
      for (final c in categories) ('${c['categoryRef']}', name(c['names'])),
      if (rows('products').any((p) => p['categoryRef'] == null))
        ('_uncategorized', l('未分类', 'Uncategorized', '未分類', 'ไม่มีหมวด')),
    ];
    Widget choice(String key, String title, bool active, VoidCallback action) =>
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: ChoiceChip(
            key: ValueKey(key),
            label: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Text(title),
            ),
            selected: active,
            onSelected: (_) => filterChanged(action),
          ),
        );
    if (categoryRail) {
      return SizedBox(
        width: 126,
        child: Material(
          color: const Color(0xFFECEEE8),
          borderRadius: BorderRadius.circular(12),
          clipBehavior: Clip.antiAlias,
          child: ListView(
            key: const ValueKey('inventory-category-rail'),
            children: [
              for (final c in options)
                Material(
                  color: category == c.$1 ? Colors.white : Colors.transparent,
                  child: InkWell(
                    key: ValueKey('inventory-category-${c.$1}'),
                    onTap: () => filterChanged(() => category = c.$1),
                    child: Container(
                      constraints: const BoxConstraints(minHeight: 60),
                      alignment: Alignment.center,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 16,
                      ),
                      decoration: BoxDecoration(
                        border: Border(
                          left: BorderSide(
                            color: category == c.$1
                                ? green
                                : Colors.transparent,
                            width: 4,
                          ),
                        ),
                      ),
                      child: Text(
                        c.$2,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 16,
                          color: category == c.$1 ? green : muted,
                          fontWeight: category == c.$1
                              ? FontWeight.bold
                              : FontWeight.normal,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              for (final s in [
                ('all', l('所有库存', 'All stock', '所有庫存', 'สต็อกทั้งหมด')),
                ('low', l('库存不足', 'Low stock', '庫存不足', 'สต็อกต่ำ')),
                ('empty', l('无库存', 'Out of stock', '無庫存', 'สินค้าหมด')),
              ])
                choice(
                  'inventory-stock-${s.$1}',
                  s.$2,
                  stockFilter == s.$1,
                  () => stockFilter = s.$1,
                ),
              const Spacer(),
              label(
                '${visibleProducts.length} ${l('款', 'items', '款', 'รายการ')}',
                color: muted,
              ),
            ],
          ),
        ],
      ),
    );
  }

  final countDraft = <String, Map<String, dynamic>>{};
  final storage = const FlutterSecureStorage();
  Map<String, dynamic>? data, pending;
  String selected = '', countType = 'count', countNote = '';
  int tab = 0, epoch = 0;
  bool loading = false, working = false;
  String? error;
  late String scope;
  CashierRealtimeClient? realtime;
  int revision = 0;
  Timer? refreshTimer;
  Object? cacheIdentity;
  Object? credentialsIdentity;
  final pageCache = const InventoryPageCache();
  Future<void>? cacheRestore;
  Future<void>? draftRestore;
  Future<Map<String, dynamic>>? procurementRead;
  String get displayScope {
    final session = widget.auth.session;
    final permissions = session?.permissions.toList() ?? [];
    permissions.sort();
    return '$identity|${permissions.join(',')}';
  }

  void connectRealtime() {
    if (!widget.enableRealtime || widget.auth.busy) return;
    final session = widget.auth.session;
    if (identical(session, realtime?.session)) return;
    realtime?.removeListener(onRealtime);
    realtime?.dispose();
    revision = 0;
    realtime = session == null ? null : CashierRealtimeClient(session);
    realtime?.addListener(onRealtime);
    realtime?.start();
  }

  void onRealtime() {
    if (revision == realtime?.revision) return;
    revision = realtime?.revision ?? 0;
    procurementRead = null;
    if (data?['procurementProducts'] is List) {
      data = {...data!}..remove('procurementProducts');
    }
    refreshTimer?.cancel();
    refreshTimer = Timer(const Duration(milliseconds: 500), () {
      if (mounted && !working && !loading) unawaited(load());
    });
  }

  String l(String zh, String en, String tw, String th) =>
      [zh, en, tw, th][widget.language.index];
  String get identity =>
      '${widget.auth.session?.base}|${widget.auth.session?.storeRef}|${widget.auth.session?.employeeRef}';
  bool get canWrite =>
      widget.auth.session?.permissions.contains('shift.manage') == true;
  String get draftKey => 'inventory-draft:$identity';
  String uid() {
    final r = Random.secure(), b = List.generate(16, (_) => r.nextInt(256));
    b[6] = (b[6] & 15) | 64;
    b[8] = (b[8] & 63) | 128;
    final h = b.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
  }

  List<Map<String, dynamic>> rows(String key) => (data?[key] as List? ?? [])
      .map((v) => Map<String, dynamic>.from(v as Map))
      .toList();
  String name(dynamic v) {
    if (v is! Map) return '—';
    return '${v[['zh-CN', 'en', 'zh-TW', 'th'][widget.language.index]] ?? v['zh-CN'] ?? v.values.firstOrNull ?? '—'}';
  }

  String productName(String ref) {
    final p = rows('products').where((p) => p['productRef'] == ref).firstOrNull;
    return p == null ? ref : '${name(p['names'])} ${name(p['specifications'])}';
  }

  String money(dynamic c) => c == null
      ? l('成本未知', 'Unknown cost', '成本未知', 'ไม่ทราบต้นทุน')
      : '¥ ${((c as num) / 100).toStringAsFixed(2)}';
  String time(dynamic value) {
    final d = DateTime.tryParse('$value')
        ?.toUtc()
        .add(const Duration(hours: 8));
    return d == null
        ? '—'
        : d.toIso8601String().substring(0, 16).replaceFirst('T', ' ');
  }

  Map<String, dynamic>? get current =>
      rows('products').where((p) => p['productRef'] == selected).firstOrNull;
  List<String> get locations =>
      (data?['locations'] as List? ?? []).cast<String>();
  @override
  void initState() {
    super.initState();
    scope = identity;
    cacheIdentity = widget.auth.workspaceIdentity;
    credentialsIdentity = widget.auth.session;
    data = WorkspaceReadCache.read<Map<String, dynamic>>(
      cacheIdentity,
      'inventory:0',
      maxAge: const Duration(minutes: 5),
    );
    widget.auth.addListener(authChanged);
    connectRealtime();
    cacheRestore = restoreDisplay();
    draftRestore = restore();
    unawaited(load());
  }

  Future<void> restoreDisplay() async {
    final oldScope = displayScope, oldIdentity = cacheIdentity;
    if (data != null) return;
    final saved = await pageCache.read(oldScope);
    if (!mounted ||
        oldScope != displayScope ||
        !identical(oldIdentity, cacheIdentity) ||
        data != null ||
        saved == null)
      return;
    if (saved['storeRef'] != widget.auth.session?.storeRef) return;
    setState(() => data = saved);
    WorkspaceReadCache.put(cacheIdentity, 'inventory:0', saved);
  }

  void authChanged() {
    if (widget.auth.busy) return;
    connectRealtime();
    if (scope == identity &&
        identical(cacheIdentity, widget.auth.workspaceIdentity)) {
      if (!identical(credentialsIdentity, widget.auth.session)) {
        credentialsIdentity = widget.auth.session;
        unawaited(load());
      }
      return;
    }
    scope = identity;
    cacheIdentity = widget.auth.workspaceIdentity;
    credentialsIdentity = widget.auth.session;
    epoch++;
    data = null;
    selected = '';
    category = '';
    stockFilter = 'all';
    search.clear();
    countDraft.clear();
    pending = null;
    procurementRead = null;
    cacheRestore = restoreDisplay();
    draftRestore = restore();
    unawaited(load());
  }

  @override
  void dispose() {
    epoch++;
    widget.auth.removeListener(authChanged);
    refreshTimer?.cancel();
    realtime?.removeListener(onRealtime);
    realtime?.dispose();
    search.dispose();
    super.dispose();
  }

  Future<void> restore() async {
    final old = scope;
    try {
      final raw = await storage.read(key: draftKey);
      if (!mounted || old != scope || raw == null) return;
      final v = jsonDecode(raw) as Map;
      setState(() {
        countType = v['type'] as String? ?? 'count';
        countNote = v['note'] as String? ?? '';
        for (final x in v['items'] as List? ?? []) {
          final m = Map<String, dynamic>.from(x as Map);
          countDraft[m['productRef'] as String] = m;
        }
        pending = v['pending'] == null
            ? null
            : Map<String, dynamic>.from(v['pending'] as Map);
      });
    } catch (_) {}
  }

  Future<void> saveDraft() => storage.write(
    key: draftKey,
    value: jsonEncode({
      'type': countType,
      'note': countNote,
      'items': countDraft.values.toList(),
      'pending': pending == null
          ? null
          : ({...pending!}..remove('identityCode')),
    }),
  );
  Future<void> load({int before = 0}) async {
    if (working || widget.auth.busy) return;
    final request = ++epoch;
    final identity = cacheIdentity;
    setState(() => loading = true);
    try {
      if (data == null) await cacheRestore;
      await draftRestore;
      if (!mounted || request != epoch) return;
      final command = {
        'action': 'context',
        'before': before,
        'view': 'stock',
        if (before == 0 &&
            data?['view'] == 'stock' &&
            data?['version'] is String)
          'knownVersion': data!['version'],
        if (pending?['requestId'] is String)
          'pendingRequestId': pending!['requestId'],
      };
      final v = identity == null
          ? await widget.auth.inventory(command)
          : await WorkspaceReadCache.readOnce<Map<String, dynamic>>(
              identity,
              'inventory:$before',
              () => widget.auth.inventory(command),
            );
      if (!mounted || request != epoch) return;
      final next = (v['notModified'] == true || v['notModified'] == 1)
          ? {...?data, ...v}
          : v;
      if (v['notModified'] != true && v['notModified'] != 1)
        procurementRead = null;
      if (next['products'] is! List)
        throw const FormatException('Inventory display missing');
      final status = v['pendingStatus'];
      final acknowledged =
          status is Map &&
          status['requestId'] == pending?['requestId'] &&
          ['applied', 'cancelled'].contains(status['state']);
      WorkspaceReadCache.put(identity, 'inventory:$before', next);
      setState(() {
        data = next;
        error = null;
        if (acknowledged) pending = null;
      });
      if (acknowledged) await saveDraft();
      unawaited(pageCache.write(displayScope, next));
    } catch (failure) {
      debugPrint('cashier_inventory_read_failed: ${failure.runtimeType}');
      if (failure is CcsopFailure) {
        debugPrint('cashier_inventory_code: ${failure.code}');
      }
      if (mounted && request == epoch) {
        setState(
          () => error = l(
            '库存未能读取，请重试',
            'Could not read inventory',
            '庫存未能讀取，請重試',
            'อ่านคลังไม่สำเร็จ',
          ),
        );
      }
    } finally {
      if (mounted && request == epoch) setState(() => loading = false);
    }
  }

  Future<bool> submit(Map<String, dynamic> command) async {
    if (working) return false;
    final request = epoch;
    if (pending != null && command['requestId'] != pending!['requestId']) {
      message(
        l(
          '上一笔结果未确认，请先重试原操作',
          'Retry the unresolved operation first',
          '上一筆結果未確認，請先重試原操作',
          'ลองรายการที่ยังไม่ยืนยันก่อน',
        ),
      );
      return false;
    }
    setState(() => working = true);
    pending = {...command, 'requestId': command['requestId'] ?? uid()};
    try {
      await saveDraft();
      if (!mounted || request != epoch) return false;
      final v = await widget.auth.inventory(pending!);
      if (!mounted || request != epoch) return false;
      WorkspaceReadCache.put(cacheIdentity, 'inventory:0', v);
      unawaited(pageCache.write(displayScope, v));
      setState(() {
        data = v;
        pending = null;
        error = null;
        if (['count', 'opening', 'handover'].contains(command['action'])) {
          countDraft.clear();
        }
      });
      await saveDraft();
      message(l('已保存', 'Saved', '已儲存', 'บันทึกแล้ว'));
      return true;
    } catch (e) {
      if (mounted && request == epoch) {
        final raw = e.toString();
        final known =
            raw.contains('INVENTORY_') ||
            raw.contains('CASHIER_') ||
            raw.contains('PROCUREMENT_') ||
            (e is CcsopFailure &&
                e.code == 'SESSION_REQUIRED' &&
                !e.deliveryUncertain);
        setState(() {
          error = raw.contains('INVENTORY_PRICE_CHANGED')
              ? l(
                  '售价已被更新，请刷新后重新修改',
                  'Price changed. Refresh before editing again.',
                  '售價已更新，請重新整理後修改',
                  'ราคาเปลี่ยนแล้ว กรุณาโหลดใหม่ก่อนแก้ไข',
                )
              : raw.contains('INVENTORY_COST_REQUIRED')
              ? l(
                  '请先补齐每项商品的进货价格',
                  'Complete each unit cost before submitting',
                  '請先補齊每項商品的進貨價格',
                  'กรอกราคาทุกรายการ',
                )
              : raw.contains('INVENTORY_QUOTE_CHANGED')
              ? l(
                  '供应商报价已变化，请重新选择商品报价',
                  'Supplier quote changed; select it again',
                  '供應商報價已變化，請重新選擇商品報價',
                  'ราคาเปลี่ยน โปรดเลือกใหม่',
                )
              : raw.contains('INVENTORY_PURCHASE_CHANGED')
              ? l(
                  '采购批次已变化，请重新打开批次',
                  'Purchase batch changed; reopen it',
                  '採購批次已變化，請重新打開批次',
                  'ชุดเปลี่ยน โปรดเปิดใหม่',
                )
              : raw.contains('INVENTORY_APPROVAL_REQUIRED')
              ? l(
                  '该批次需要先批准，再采购',
                  'Approval is required before ordering',
                  '該批次需要先批准，再採購',
                  'ต้องอนุมัติก่อนซื้อ',
                )
              : raw.contains('INVENTORY_CHANGED')
              ? l(
                  '库存已发生变化，请重新盘点受影响商品',
                  'Stock changed. Recount affected items.',
                  '庫存已發生變化，請重新盤點受影響商品',
                  'สต็อกเปลี่ยน โปรดตรวจนับใหม่',
                )
              : raw.contains('INVENTORY_RESERVED')
              ? l(
                  '数量涉及已预留商品，不能直接扣减',
                  'Quantity includes reserved goods',
                  '數量涉及已預留商品，不能直接扣減',
                  'จำนวนรวมสินค้าที่จองไว้',
                )
              : l(
                  '未完成，请检查数量、柜格、授权或刷新会员码后重试',
                  'Not completed. Check quantity, location, permission or refresh member QR.',
                  '未完成，請檢查數量、櫃格、授權或刷新會員碼後重試',
                  'ไม่สำเร็จ ตรวจจำนวน ช่องเก็บ สิทธิ์ หรือ QR สมาชิก',
                );
          if (known) pending = null;
        });
        await saveDraft();
      }
      return false;
    } finally {
      if (mounted && request == epoch) setState(() => working = false);
    }
  }

  void message(String value) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(value)));
    }
  }

  Future<bool> resolvePending() async {
    final previous = pending;
    if (previous == null) return true;
    if (working) return false;
    final request = epoch;
    setState(() => working = true);
    try {
      final v = await widget.auth.inventory({
        'action': 'resolve_pending',
        'requestId': previous['requestId'],
        'originalAction': previous['action'],
        if (previous['productRef'] != null)
          'productRef': previous['productRef'],
        'cancelIfUnsent': true,
      });
      if (!mounted || request != epoch) return false;
      final status = v['pendingStatus'];
      if (status is! Map ||
          status['requestId'] != previous['requestId'] ||
          !['applied', 'cancelled'].contains(status['state']))
        return false;
      setState(() {
        data = v;
        pending = null;
        error = null;
      });
      WorkspaceReadCache.put(cacheIdentity, 'inventory:0', v);
      await saveDraft();
      unawaited(pageCache.write(displayScope, v));
      return true;
    } catch (_) {
      if (mounted)
        message(
          l(
            '暂时无法核对，请稍后再试',
            'Unable to check the previous operation',
            '暫時無法核對，請稍後再試',
            'ยังตรวจสอบไม่ได้ โปรดลองใหม่',
          ),
        );
      return false;
    } finally {
      if (mounted && request == epoch) setState(() => working = false);
    }
  }

  Future<void> ensureProcurementProducts() async {
    if (data?['procurementProducts'] is List) return;
    if (data?['view'] != 'stock') return;
    final identity = cacheIdentity;
    Map<String, dynamic> v;
    try {
      v = await (procurementRead ??= widget.auth.inventory({
        'action': 'context',
        'view': 'full',
      }));
    } catch (_) {
      procurementRead = null;
      rethrow;
    }
    if (!mounted || !identical(identity, cacheIdentity)) return;
    setState(
      () => data = {
        ...?data,
        'procurementProducts': v['procurementProducts'] ?? v['products'],
      },
    );
  }

  Widget label(
    String value, {
    double size = 14,
    Color color = green,
    FontWeight weight = FontWeight.normal,
  }) => Text(
    value,
    overflow: TextOverflow.ellipsis,
    maxLines: 2,
    style: TextStyle(fontSize: size, color: color, fontWeight: weight),
  );
  Widget box(Widget child) => Material(
    color: Colors.white,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(14),
      side: const BorderSide(color: Color(0xFFE1E5DF)),
    ),
    child: Padding(padding: const EdgeInsets.all(16), child: child),
  );
  Widget button(String title, VoidCallback? action, {bool primary = false}) =>
      Padding(
        padding: const EdgeInsets.only(right: 8, bottom: 8),
        child: FilledButton.tonal(
          onPressed: working ? null : action,
          style: FilledButton.styleFrom(
            minimumSize: const Size(92, 48),
            backgroundColor: primary ? green : null,
            foregroundColor: primary ? Colors.white : null,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
          child: Text(title),
        ),
      );
  Widget numberField(
    String title,
    int value,
    void Function(int) change, {
    bool cents = false,
  }) => OutlinedButton(
    onPressed: () => number(title, value, cents: cents).then((v) {
      if (v != null) change(v);
    }),
    style: OutlinedButton.styleFrom(
      minimumSize: const Size(150, 64),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        label(title, size: 12, color: muted),
        label(
          cents ? money(value) : '$value',
          size: 24,
          weight: FontWeight.bold,
        ),
      ],
    ),
  );
  Future<int?> number(String title, int initial, {bool cents = false}) async {
    var value = cents ? (initial / 100).toStringAsFixed(2) : '$initial',
        fresh = true;
    return showDialog<int>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, set) => Dialog(
          child: SizedBox(
            width: 380,
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: label(title, size: 20, weight: FontWeight.bold),
                      ),
                      IconButton(
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Align(
                    alignment: Alignment.centerRight,
                    child: label(value, size: 34, weight: FontWeight.bold),
                  ),
                  const SizedBox(height: 16),
                  GridView.count(
                    crossAxisCount: 3,
                    shrinkWrap: true,
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 8,
                    childAspectRatio: 1.8,
                    children: [
                      for (final key in [
                        '1',
                        '2',
                        '3',
                        '4',
                        '5',
                        '6',
                        '7',
                        '8',
                        '9',
                        cents ? '.' : '清除',
                        '0',
                        '⌫',
                      ])
                        FilledButton.tonal(
                          onPressed: () => set(() {
                            if (key == '⌫') {
                              value = value.length > 1
                                  ? value.substring(0, value.length - 1)
                                  : '0';
                              fresh = false;
                            } else if (key == '清除') {
                              value = '0';
                              fresh = true;
                            } else {
                              if (fresh) {
                                value = key == '.' ? '0.' : key;
                                fresh = false;
                              } else if (key != '.' || !value.contains('.')) {
                                final next = value == '0' && key != '.'
                                    ? key
                                    : value + key;
                                if (next.length <= 10 &&
                                    (!next.contains('.') ||
                                        next.split('.').last.length <= 2)) {
                                  value = next;
                                }
                              }
                            }
                          }),
                          child: Text(
                            key,
                            style: const TextStyle(fontSize: 24),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: button(l('确定', 'Confirm', '確定', 'ยืนยัน'), () {
                      final v = double.tryParse(value);
                      if (v != null && v >= 0) {
                        Navigator.pop(context, (cents ? v * 100 : v).round());
                      }
                    }, primary: true),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<bool?> confirm(String title, String body) => showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(l('取消', 'Cancel', '取消', 'ยกเลิก')),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text(l('确认', 'Confirm', '確認', 'ยืนยัน')),
        ),
      ],
    ),
  );
  Future<void> scan(String title, Map<String, dynamic> command) async {
    StreamSubscription<String>? subscription;
    bool scanning = false;
    String? failure;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, set) {
          subscription ??= ScannerInput.codes.listen((code) async {
            if (scanning ||
                !dialogContext.mounted ||
                ModalRoute.of(dialogContext)?.isCurrent != true) {
              return;
            }
            if (!RegExp(r'^KC:M:[0-9A-F]{32}$').hasMatch(code)) return;
            scanning = true;
            set(() => failure = null);
            final ok = await submit({...command, 'identityCode': code});
            if (!dialogContext.mounted) return;
            if (ok) {
              Navigator.pop(dialogContext);
            } else {
              set(() => failure = error);
              scanning = false;
            }
          });
          return Dialog(
            child: SizedBox(
              width: 480,
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: label(
                            title,
                            size: 22,
                            weight: FontWeight.bold,
                          ),
                        ),
                        IconButton(
                          onPressed: scanning
                              ? null
                              : () => Navigator.pop(context),
                          icon: const Icon(Icons.close),
                        ),
                      ],
                    ),
                    const SizedBox(height: 30),
                    const ScanIcon(size: 76, color: green),
                    const SizedBox(height: 20),
                    label(
                      l(
                        '出示本人 KING 会员码',
                        'Present your KING member QR',
                        '出示本人 KING 會員碼',
                        'แสดง QR สมาชิก KING ของตน',
                      ),
                      size: 18,
                    ),
                    const SizedBox(height: 12),
                    label(
                      l(
                        '扫码确认身份并登记，无需点击输入框',
                        'Scan to identify and record; no input field',
                        '掃碼確認身份並登記，無需點擊輸入框',
                        'สแกนเพื่อยืนยันและบันทึก ไม่ต้องแตะช่องกรอก',
                      ),
                      color: muted,
                    ),
                    if (failure != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 16),
                        child: label(failure!, color: Colors.red),
                      ),
                    const SizedBox(height: 30),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
    await subscription?.cancel();
  }

  Future<void> productAction(String action, Map<String, dynamic> p) async {
    var quantity = action == 'count'
        ? (countDraft[p['productRef']]?['quantity'] as int? ??
              (p['onHand'] as num).toInt())
        : 1;
    final saved = action == 'count' ? countDraft[p['productRef']] : null;
    int? unitCost = saved?['unitCostCents'] as int?;
    String location =
            saved?['location'] as String? ?? locations.firstOrNull ?? '',
        note = saved?['note'] as String? ?? '';
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, set) => Dialog(
          child: SizedBox(
            width: 560,
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: label(
                          productName('${p['productRef']}'),
                          size: 20,
                          weight: FontWeight.bold,
                        ),
                      ),
                      IconButton(
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  label(
                    '${l('账面', 'On hand', '帳面', 'คงคลัง')} ${p['onHand']}    ${l('预留', 'Reserved', '預留', 'จอง')} ${p['reserved']}    ${l('可售', 'Available', '可售', 'ขายได้')} ${p['available']}',
                    color: muted,
                  ),
                  const SizedBox(height: 18),
                  Row(
                    children: [
                      Expanded(
                        child: numberField(
                          action == 'count'
                              ? l(
                                  '实盘数量',
                                  'Counted units',
                                  '實盤數量',
                                  'จำนวนตรวจนับ',
                                )
                              : l('数量', 'Quantity', '數量', 'จำนวน'),
                          quantity,
                          (v) => set(() => quantity = v),
                        ),
                      ),
                      if (action == 'count') ...[
                        const SizedBox(width: 12),
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () =>
                                number(
                                  l(
                                    '盘盈商品单价（元）',
                                    'Cost of added units',
                                    '盤盈商品單價（元）',
                                    'ต้นทุนสินค้าที่เพิ่ม',
                                  ),
                                  unitCost ?? 0,
                                  cents: true,
                                ).then((v) {
                                  if (v != null) set(() => unitCost = v);
                                }),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                label(
                                  l(
                                    '盘盈成本',
                                    'Cost of added units',
                                    '盤盈成本',
                                    'ต้นทุนส่วนเพิ่ม',
                                  ),
                                  size: 12,
                                  color: muted,
                                ),
                                Text(money(unitCost)),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  if (action == 'count') ...[
                    const SizedBox(height: 16),
                    DropdownButtonFormField<String>(
                      initialValue: locations.contains(location)
                          ? location
                          : null,
                      items: locations
                          .map(
                            (s) => DropdownMenuItem(value: s, child: Text(s)),
                          )
                          .toList(),
                      onChanged: (v) => set(() => location = v ?? ''),
                      decoration: InputDecoration(
                        labelText: l('存放柜格', 'Cabinet', '存放櫃格', 'ช่องเก็บ'),
                        border: const OutlineInputBorder(),
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  TextFormField(
                    initialValue: note,
                    onChanged: (v) => note = v,
                    maxLength: 500,
                    decoration: InputDecoration(
                      labelText: l(
                        '备注 / 原因',
                        'Note / reason',
                        '備註 / 原因',
                        'หมายเหตุ / เหตุผล',
                      ),
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: button(
                      action == 'borrow'
                          ? l(
                              '扫借酒人会员码',
                              'Scan borrower',
                              '掃借酒人會員碼',
                              'สแกนผู้ยืม',
                            )
                          : l('确定', 'Confirm', '確定', 'ยืนยัน'),
                      () => Navigator.pop(context, true),
                      primary: true,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    if (ok != true || !mounted) return;
    if (action == 'count') {
      setState(
        () => countDraft['${p['productRef']}'] = {
          'productRef': p['productRef'],
          'quantity': quantity,
          'expectedOnHand': p['onHand'],
          'expectedReserved': p['reserved'],
          'location': location,
          'unitCostCents': unitCost,
          'note': note,
        },
      );
      await saveDraft();
      return;
    }
    final command = {
      'action': action,
      'productRef': p['productRef'],
      'quantity': quantity,
      'note': note,
    };
    if (action == 'borrow') {
      await scan(l('借酒登记', 'Register loan', '借酒登記', 'บันทึกยืม'), command);
    } else {
      await submit(command);
    }
  }

  Future<void> receive(Map<String, dynamic> p) async {
    var q = (p['quantity'] as num).toInt() - (p['received'] as num).toInt();
    var loc = locations.firstOrNull ?? '';
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, set) => AlertDialog(
          title: Text(l('进货入库', 'Receive goods', '進貨入庫', 'รับสินค้า')),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                label(productName('${p['productRef']}')),
                const SizedBox(height: 16),
                numberField(
                  l('本次到货', 'Received now', '本次到貨', 'รับครั้งนี้'),
                  q,
                  (v) => set(() => q = v),
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  initialValue: locations.contains(loc) ? loc : null,
                  decoration: InputDecoration(
                    labelText: l('入库柜格', 'Cabinet', '入庫櫃格', 'ช่องรับเข้า'),
                  ),
                  items: locations
                      .map((s) => DropdownMenuItem(value: s, child: Text(s)))
                      .toList(),
                  onChanged: (v) => loc = v ?? '',
                ),
              ],
            ),
          ),
          actions: [
            button(
              l('取消', 'Cancel', '取消', 'ยกเลิก'),
              () => Navigator.pop(context),
            ),
            button(
              l('确认入库', 'Receive', '確認入庫', 'ยืนยันรับ'),
              () => Navigator.pop(context, true),
              primary: true,
            ),
          ],
        ),
      ),
    );
    if (ok == true) {
      await submit({
        'action': 'receive',
        'relatedRef': p['purchaseRef'],
        'quantity': q,
        'location': loc,
      });
    }
  }

  Future<Map<String, dynamic>> batchCommand(
    Map<String, dynamic> command,
  ) async {
    if (!await submit(command)) {
      throw StateError(
        error ?? l('未保存，请重试', 'Not saved. Retry.', '未儲存，請重試', 'ยังไม่บันทึก'),
      );
    }
    final batch = (data?['receipt'] as Map?)?['batch'];
    if (batch is! Map) {
      throw StateError(
        l(
          '批次未返回，请刷新',
          'Batch unavailable. Refresh.',
          '批次未返回，請重新整理',
          'รีเฟรชชุดสินค้า',
        ),
      );
    }
    return Map<String, dynamic>.from(batch);
  }

  Future<void> openBatch(
    Map<String, dynamic> batch, {
    Map<String, dynamic>? initialProduct,
    bool receiving = false,
  }) async {
    try {
      await ensureProcurementProducts();
      if (!mounted) return;
      final detail = batch['items'] is List
          ? batch
          : await widget.auth.inventory({
              'action': 'purchase_batch',
              'batchRef': batch['batchRef'],
            });
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => PurchaseBatchDialog(
          categories: rows('categories'),
          language: widget.language,
          batch: detail,
          products: data?['procurementProducts'] is List
              ? rows('procurementProducts')
              : rows('products'),
          suppliers: rows('suppliers'),
          locations: locations,
          l: l,
          canWrite: canWrite,
          receiving: receiving,
          initialProduct: initialProduct,
          command: batchCommand,
          number: number,
          attach: batchDocument,
        ),
      );
    } catch (_) {
      if (mounted) {
        message(
          error ??
              l(
                '无法读取采购批次，请重试',
                'Cannot read purchase batch',
                '無法讀取採購批次，請重試',
                'อ่านชุดสินค้าไม่ได้',
              ),
        );
      }
    }
  }

  Future<void> deletePurchaseDraft(Map<String, dynamic> batch) async {
    if (working || !canWrite) return;
    if ((batch['itemCount'] as num? ?? 0) > 0) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: Text(
            l(
              '删除采购草稿？',
              'Delete purchase draft?',
              '刪除採購草稿？',
              'ลบร่างคำขอซื้อ?',
            ),
          ),
          content: Text('${batch['title']}'),
          actions: [
            button(
              l('取消', 'Cancel', '取消', 'ยกเลิก'),
              () => Navigator.pop(context, false),
            ),
            button(
              l('删除', 'Delete', '刪除', 'ลบ'),
              () => Navigator.pop(context, true),
              primary: true,
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }
    await submit({
      'action': 'purchase_batch_delete',
      'batchRef': batch['batchRef'],
      'revision': batch['revision'],
    });
  }

  Future<void> manualPurchase({Map<String, dynamic>? initialProduct}) async {
    if (rows('suppliers').where((s) => s['active'] == 1).isEmpty) {
      message(
        l('请先登记供应商', 'Add a supplier first', '請先登記供應商', 'เพิ่มผู้ขายก่อน'),
      );
      setState(() => tab = 6);
      return;
    }
    final now = DateTime.now();
    try {
      final batch = <String, dynamic>{
        'batchRef': uid(),
        'revision': 0,
        'status': 'draft',
        'title': l(
          '${now.month}月${now.day}日进货申请',
          'Purchase request ${now.month}/${now.day}',
          '${now.month}月${now.day}日進貨申請',
          'คำขอซื้อ ${now.month}/${now.day}',
        ),
        'items': <Map<String, dynamic>>[],
      };
      if (mounted) await openBatch(batch, initialProduct: initialProduct);
    } catch (_) {
      if (mounted) {
        message(
          error ??
              l(
                '申请未创建，请重试',
                'Application not created',
                '申請未建立，請重試',
                'ยังไม่สร้างคำขอ',
              ),
        );
      }
    }
  }

  Future<void> purchase(Map<String, dynamic> product) async {
    final drafts = rows('purchaseBatches')
        .where((b) => b['status'] == 'draft')
        .toList();
    if (drafts.isEmpty) {
      await manualPurchase(initialProduct: product);
      return;
    }
    final choice = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          l(
            '添加到采购批次',
            'Add to a purchase batch',
            '添加到採購批次',
            'เพิ่มในชุดสินค้า',
          ),
        ),
        content: SizedBox(
          width: 520,
          height: 320,
          child: ListView(
            children: [
              for (final b in drafts)
                ListTile(
                  minVerticalPadding: 16,
                  title: Text('${b['title']}'),
                  subtitle: Text(
                    '${b['itemCount']} ${l('项商品', 'items', '項商品', 'รายการ')}',
                  ),
                  onTap: () => Navigator.pop(ctx, b),
                ),
            ],
          ),
        ),
        actions: [
          button(
            l('新建批次', 'New batch', '新建批次', 'ชุดใหม่'),
            () => Navigator.pop(ctx, <String, dynamic>{}),
          ),
          button(l('取消', 'Cancel', '取消', 'ยกเลิก'), () => Navigator.pop(ctx)),
        ],
      ),
    );
    if (choice == null || !mounted) return;
    if (choice.isEmpty) {
      await manualPurchase(initialProduct: product);
    } else {
      await openBatch(choice, initialProduct: product);
    }
  }

  Future<Map<String, dynamic>?> batchDocument(Map<String, dynamic> old) async {
    var number = '${old['number'] ?? ''}';
    final ids = (old['fileIds'] as List? ?? []).map((i) => '$i').toList();
    bool uploading = false;
    String? failure;
    return showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: Text(
            l(
              '采购凭证 · 可后补',
              'Purchase documents · optional',
              '採購憑證 · 可後補',
              'เอกสารการซื้อ',
            ),
          ),
          content: SizedBox(
            width: 520,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  initialValue: number,
                  onChanged: (v) => number = v,
                  decoration: InputDecoration(
                    labelText: l(
                      '底单号（选填）',
                      'Document number (optional)',
                      '底單號（選填）',
                      'เลขเอกสาร',
                    ),
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  l(
                    '选择照片或 PDF，也可由手机或接口上传后关联到此批次。',
                    'Choose a photo or PDF; API uploads may also be attached to this batch.',
                    '選擇照片或 PDF，也可由手機或介面上傳後關聯到此批次。',
                    'เลือกรูปหรือ PDF หรืออัปโหลดผ่าน API',
                  ),
                ),
                const SizedBox(height: 14),
                for (final id in ids)
                  TextButton.icon(
                    onPressed: () => document(id),
                    icon: const Icon(Icons.description_outlined),
                    label: Text(l('查看凭证', 'View document', '查看憑證', 'ดูเอกสาร')),
                  ),
                if (failure != null)
                  Text(failure!, style: const TextStyle(color: Colors.red)),
                FilledButton.tonal(
                  onPressed: uploading || ids.length >= 8
                      ? null
                      : () async {
                          set(() => uploading = true);
                          try {
                            final file = await const MethodChannel(
                              'cn.kingclub.cashier/inventory-document',
                            ).invokeMapMethod<String, dynamic>('choose');
                            if (file != null) {
                              final result = await widget.auth.inventory({
                                'action': 'upload_document',
                                ...file,
                              });
                              if (ctx.mounted) {
                                set(() => ids.add('${result['fileId']}'));
                              }
                            }
                          } catch (_) {
                            if (ctx.mounted) {
                              set(
                                () => failure = l(
                                  '请选择 1MB 内的 JPG、PNG 或 PDF',
                                  'Choose a JPG, PNG or PDF up to 1MB',
                                  '請選擇 1MB 內的 JPG、PNG 或 PDF',
                                  'เลือกไฟล์ไม่เกิน 1MB',
                                ),
                              );
                            }
                          } finally {
                            if (ctx.mounted) set(() => uploading = false);
                          }
                        },
                  child: Text(
                    uploading
                        ? l('正在上传', 'Uploading', '正在上傳', 'อัปโหลด')
                        : l(
                            '选择并上传凭证',
                            'Select and upload',
                            '選擇並上傳憑證',
                            'เลือกและอัปโหลด',
                          ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            button(
              l('取消', 'Cancel', '取消', 'ยกเลิก'),
              uploading ? null : () => Navigator.pop(ctx),
            ),
            button(
              l('保存凭证', 'Save documents', '儲存憑證', 'บันทึกเอกสาร'),
              uploading
                  ? null
                  : () =>
                        Navigator.pop(ctx, {'number': number, 'fileIds': ids}),
              primary: true,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> supplier([Map<String, dynamic>? saved]) async {
    String name = '${saved?['name'] ?? ''}',
        contact = '${saved?['contact'] ?? ''}',
        phone = '${saved?['phone'] ?? ''}',
        note = '${saved?['notes'] ?? ''}';
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l('供应商资料', 'Supplier', '供應商資料', 'ข้อมูลผู้ขาย')),
        content: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final f in [
                (l('名称', 'Name', '名稱', 'ชื่อ'), name, (String v) => name = v),
                (
                  l('联系人', 'Contact', '聯絡人', 'ผู้ติดต่อ'),
                  contact,
                  (String v) => contact = v,
                ),
                (
                  l('电话', 'Phone', '電話', 'โทรศัพท์'),
                  phone,
                  (String v) => phone = v,
                ),
                (
                  l('备注', 'Notes', '備註', 'หมายเหตุ'),
                  note,
                  (String v) => note = v,
                ),
              ])
                Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: TextFormField(
                    initialValue: f.$2,
                    onChanged: f.$3,
                    decoration: InputDecoration(
                      labelText: f.$1,
                      border: const OutlineInputBorder(),
                    ),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          button(
            l('取消', 'Cancel', '取消', 'ยกเลิก'),
            () => Navigator.pop(context),
          ),
          button(
            l('保存', 'Save', '儲存', 'บันทึก'),
            () => Navigator.pop(context, true),
            primary: true,
          ),
        ],
      ),
    );
    if (ok == true) {
      await submit({
        'action': 'supplier',
        'supplierRef': saved?['supplierRef'] ?? uid(),
        'revision': saved?['revision'] ?? 0,
        'name': name,
        'contact': contact,
        'phone': phone,
        'note': note,
      });
    }
  }

  Future<void> policy(Map<String, dynamic> p) async {
    final old = p['policy'] as Map?;
    var enabled = old?['enabled'] != false,
        warning = (old?['warning'] as num? ?? 0).toInt(),
        target = (old?['target'] as num? ?? 1).toInt();
    String? supplier = old?['supplierRef'] as String?;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, set) => AlertDialog(
          title: Text(
            l(
              '预警与自动补货建议',
              'Stock warning & reorder',
              '預警與自動補貨建議',
              'เตือนสต็อกและแนะนำซื้อ',
            ),
          ),
          content: SizedBox(
            width: 500,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SwitchListTile(
                  title: Text(
                    l(
                      '自动生成预采购清单',
                      'Generate purchase suggestions',
                      '自動生成預採購清單',
                      'สร้างรายการแนะนำซื้อ',
                    ),
                  ),
                  value: enabled,
                  onChanged: (v) => set(() => enabled = v),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: numberField(
                        l(
                          '可售 ≤ 此数时提醒',
                          'Warn at or below',
                          '可售 ≤ 此數時提醒',
                          'เตือนเมื่อเหลือไม่เกิน',
                        ),
                        warning,
                        (v) => set(() => warning = v),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: numberField(
                        l('补足到', 'Target stock', '補足到', 'เติมถึง'),
                        target,
                        (v) => set(() => target = v),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  initialValue: supplier,
                  items: [
                    DropdownMenuItem(
                      value: '',
                      child: Text(
                        l(
                          '采购时选择供应商',
                          'Choose supplier later',
                          '採購時選擇供應商',
                          'เลือกผู้ขายภายหลัง',
                        ),
                      ),
                    ),
                    ...rows('suppliers').map(
                      (s) => DropdownMenuItem(
                        value: '${s['supplierRef']}',
                        child: Text('${s['name']}'),
                      ),
                    ),
                  ],
                  onChanged: (v) => supplier = v == '' ? null : v,
                  decoration: InputDecoration(
                    labelText: l(
                      '默认供应商',
                      'Preferred supplier',
                      '預設供應商',
                      'ผู้ขายหลัก',
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                label(
                  l(
                    '已订未到的数量会自动扣除，避免重复采购。阈值设 0 即缺货补货。',
                    'Outstanding purchases reduce suggestions. Set warning to 0 for out-of-stock only.',
                    '已訂未到的數量會自動扣除，避免重複採購。閾值設 0 即缺貨補貨。',
                    'หักจำนวนที่สั่งแล้วเพื่อไม่ซื้อซ้ำ ตั้ง 0 เพื่อเตือนของหมด',
                  ),
                  color: muted,
                ),
              ],
            ),
          ),
          actions: [
            button(
              l('取消', 'Cancel', '取消', 'ยกเลิก'),
              () => Navigator.pop(context),
            ),
            button(
              l('保存', 'Save', '儲存', 'บันทึก'),
              () => Navigator.pop(context, true),
              primary: true,
            ),
          ],
        ),
      ),
    );
    if (ok == true) {
      await submit({
        'action': 'policy',
        'productRef': p['productRef'],
        'supplierRef': ?supplier,
        'policy': {
          if (old?['procurementQuote'] != null)
            'procurementQuote': old!['procurementQuote'],
          'enabled': enabled,
          'warning': warning,
          'target': target,
          'supplierRef': ?supplier,
        },
      });
    }
  }

  Future<void> cabinets() async {
    final chosen = [...locations];
    final input = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, set) => AlertDialog(
          title: Text(l('库存柜格', 'Stock locations', '庫存櫃格', 'ช่องเก็บสินค้า')),
          content: SizedBox(
            width: 620,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  label(
                    l(
                      '与存酒共用柜号；有在库物品的柜格不能删除。',
                      'Shared cabinet codes; occupied locations cannot be removed.',
                      '與存酒共用櫃號；有在庫物品的櫃格不能刪除。',
                      'ใช้รหัสช่องร่วมกัน ลบช่องที่มีสินค้าไม่ได้',
                    ),
                  ),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final code in chosen)
                        InputChip(
                          label: Text(code),
                          onDeleted: () => set(() => chosen.remove(code)),
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: input,
                          maxLength: 32,
                          decoration: const InputDecoration(
                            labelText: 'A1-1',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      button(l('添加', 'Add', '添加', 'เพิ่ม'), () {
                        final v = input.text.trim().toUpperCase();
                        if (RegExp(r'^[A-Z0-9_-]{1,32}$').hasMatch(v) &&
                            !chosen.contains(v)) {
                          set(() {
                            chosen.add(v);
                            input.clear();
                          });
                        }
                      }),
                    ],
                  ),
                ],
              ),
            ),
          ),
          actions: [
            button(
              l('取消', 'Cancel', '取消', 'ยกเลิก'),
              () => Navigator.pop(context),
            ),
            button(
              l('保存', 'Save', '儲存', 'บันทึก'),
              chosen.isEmpty ? null : () => Navigator.pop(context, true),
              primary: true,
            ),
          ],
        ),
      ),
    );
    if (ok == true) await submit({'action': 'locations', 'locations': chosen});
    // The route may animate after this future completes; keep its controller alive until disposal.
  }

  Future<void> document(String id) async {
    try {
      final v = await widget.auth.inventory({
        'action': 'document',
        'fileId': id,
      });
      if (!mounted) return;
      final base = widget.auth.session!.base.toString().replaceFirst(
        RegExp(r'/$'),
        '',
      );
      final url = '$base${v['path']}';
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('${v['name']}'),
          content: SizedBox(
            width: 650,
            height: 440,
            child: v['contentType'] == 'application/pdf'
                ? Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      QrImageView(data: url, size: 260),
                      label(
                        l(
                          '扫码查看底单 · 5分钟内有效',
                          'Scan to view PDF · valid for 5 minutes',
                          '掃碼查看底單 · 5分鐘內有效',
                          'สแกนดูเอกสาร ภายใน 5 นาที',
                        ),
                      ),
                    ],
                  )
                : InteractiveViewer(
                    child: Image.network(
                      url,
                      fit: BoxFit.contain,
                      errorBuilder: (_, error, stack) => Center(
                        child: label(
                          l(
                            '底单暂时无法读取',
                            'Document unavailable',
                            '底單暫時無法讀取',
                            'อ่านเอกสารไม่ได้',
                          ),
                        ),
                      ),
                    ),
                  ),
          ),
          actions: [
            button(l('关闭', 'Close', '關閉', 'ปิด'), () => Navigator.pop(context)),
          ],
        ),
      );
    } catch (_) {
      message(
        l('底单暂时无法读取', 'Document unavailable', '底單暫時無法讀取', 'อ่านเอกสารไม่ได้'),
      );
    }
  }

  Future<void> returnLoan(Map<String, dynamic> loan) async {
    final details = Map<String, dynamic>.from(loan['items'] as Map),
        returns = loan['returns'] as List? ?? [];
    final left =
        (details['quantity'] as num).toInt() -
        returns.fold<int>(0, (n, r) => n + (r['quantity'] as num).toInt());
    var q = left, loc = locations.firstOrNull ?? '', condition = 'sealed';
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, set) => AlertDialog(
          title: Text(l('归还验收', 'Accept return', '歸還驗收', 'รับคืน')),
          content: SizedBox(
            width: 500,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                label(
                  '${loan['member'] ?? loan['userAccount']} · ${productName('${details['productRef']}')}',
                ),
                const SizedBox(height: 18),
                numberField(
                  l('本次归还', 'Return units', '本次歸還', 'จำนวนคืน'),
                  q,
                  (v) => set(() => q = v),
                ),
                const SizedBox(height: 16),
                Wrap(
                  children: [
                    for (final entry in [
                      ('sealed', l('完好整瓶', 'Sealed', '完好整瓶', 'ขวดปิดสมบูรณ์')),
                      ('opened', l('已开瓶', 'Opened', '已開瓶', 'เปิดแล้ว')),
                      ('damaged', l('破损', 'Damaged', '破損', 'เสียหาย')),
                    ])
                      ChoiceChip(
                        label: Text(entry.$2),
                        selected: condition == entry.$1,
                        onSelected: (_) => set(() => condition = entry.$1),
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  initialValue: locations.contains(loc) ? loc : null,
                  items: locations
                      .map((v) => DropdownMenuItem(value: v, child: Text(v)))
                      .toList(),
                  onChanged: (v) => loc = v ?? '',
                  decoration: InputDecoration(
                    labelText: l(
                      '收回存放柜格',
                      'Return cabinet',
                      '收回存放櫃格',
                      'ช่องเก็บคืน',
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                label(
                  condition == 'sealed'
                      ? l(
                          '验收后恢复可售库存',
                          'Restore saleable stock after acceptance',
                          '驗收後恢復可售庫存',
                          'คืนสต็อกพร้อมขายหลังตรวจ',
                        )
                      : l(
                          '仅记录去向，不恢复可售库存',
                          'Record only; not saleable',
                          '僅記錄去向，不恢復可售庫存',
                          'บันทึกเท่านั้น ไม่คืนสต็อกขาย',
                        ),
                  color: muted,
                ),
              ],
            ),
          ),
          actions: [
            button(
              l('取消', 'Cancel', '取消', 'ยกเลิก'),
              () => Navigator.pop(context),
            ),
            button(
              l('扫收酒人会员码', 'Scan receiver', '掃收酒人會員碼', 'สแกนผู้รับคืน'),
              () => Navigator.pop(context, true),
              primary: true,
            ),
          ],
        ),
      ),
    );
    if (ok == true) {
      await scan(l('确认收酒人', 'Identify receiver', '確認收酒人', 'ยืนยันผู้รับ'), {
        'action': 'return',
        'relatedRef': loan['operationRef'],
        'productRef': details['productRef'],
        'quantity': q,
        'location': loc,
        'condition': condition,
      });
    }
  }

  Future<void> retailPrice(Map<String, dynamic> product) async {
    final snapshot = Map<String, dynamic>.from(product);
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => RetailPriceDialog(
        product: snapshot,
        language: widget.language,
        savePack: (unitRef, cents) => submit({
          'action': 'retail_price',
          'productRef': snapshot['productRef'],
          'revision': snapshot['revision'],
          'priceCents': cents,
          'saleUnitRef': unitRef,
        }),
        save: (cents) => submit({
          'action': 'retail_price',
          'productRef': snapshot['productRef'],
          'revision': snapshot['revision'],
          'priceCents': cents,
        }),
      ),
    );
  }

  Widget stockList() => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Expanded(
        flex: 3,
        child: box(
          Column(
            children: [
              Row(
                children: [
                  Expanded(
                    flex: 4,
                    child: label(
                      l(
                        '商品 / 规格',
                        'Product / size',
                        '商品 / 規格',
                        'สินค้า / ขนาด',
                      ),
                      color: muted,
                    ),
                  ),
                  for (final s in [
                    l('账面', 'On hand', '帳面', 'คงคลัง'),
                    l('预留', 'Reserved', '預留', 'จอง'),
                    l('可售', 'Available', '可售', 'ขายได้'),
                  ])
                    Expanded(child: label(s, color: muted)),
                ],
              ),
              const Divider(),
              Expanded(
                child: ListView(
                  children: [
                    if (visibleProducts.isEmpty)
                      Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          l(
                            '没有符合条件的商品',
                            'No matching products',
                            '沒有符合條件的商品',
                            'ไม่มีสินค้าที่ตรงกัน',
                          ),
                        ),
                      ),
                    for (final p in visibleProducts)
                      Material(
                        color: selected == p['productRef']
                            ? const Color(0xFFE4EEE8)
                            : Colors.transparent,
                        child: InkWell(
                          onTap: () =>
                              setState(() => selected = '${p['productRef']}'),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              vertical: 15,
                              horizontal: 8,
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  flex: 4,
                                  child: label(
                                    productName('${p['productRef']}'),
                                    weight: FontWeight.w600,
                                  ),
                                ),
                                for (final key in [
                                  'onHand',
                                  'reserved',
                                  'available',
                                ])
                                  Expanded(
                                    child: label(
                                      '${p[key]}',
                                      color:
                                          key == 'available' &&
                                              (p[key] as num) <= 0
                                          ? Colors.red
                                          : green,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      const SizedBox(width: 14),
      Expanded(
        flex: 2,
        child: box(
          current == null
              ? Center(
                  child: label(
                    l(
                      '点击商品，管理库存',
                      'Choose a product',
                      '點擊商品，管理庫存',
                      'เลือกสินค้าเพื่อจัดการ',
                    ),
                  ),
                )
              : SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      label(
                        productName(selected),
                        size: 21,
                        weight: FontWeight.bold,
                      ),
                      if ((current!['policy'] as Map?)?['procurementQuote']
                          case final Map quote) ...[
                        const SizedBox(height: 10),
                        label(
                          '${l('采购参考', 'Supplier quote', '採購參考', 'ราคาอ้างอิง')} · ${money(quote['quoteCents'])} / ${quote['quoteUnit']}',
                          color: muted,
                        ),
                        label(
                          '${quote['name']} · ${quote['specification']}',
                          color: muted,
                        ),
                      ],
                      const SizedBox(height: 20),
                      if (current!['priceCents'] is num) ...[
                        label(
                          '${l('本店零售价', 'Store retail price', '本店零售價', 'ราคาขายของร้าน')}  ${money(current!['priceCents'])}',
                          size: 20,
                          weight: FontWeight.bold,
                        ),
                        const SizedBox(height: 12),
                        button(
                          l(
                            '修改零售价',
                            'Edit retail price',
                            '修改零售價',
                            'แก้ไขราคาขาย',
                          ),
                          !working &&
                                  widget.auth.session?.permissions.contains(
                                        'price.adjust',
                                      ) ==
                                      true
                              ? () async {
                                  if (await resolvePending() &&
                                      mounted &&
                                      current != null)
                                    await retailPrice(current!);
                                }
                              : null,
                        ),
                        const SizedBox(height: 12),
                      ],
                      Wrap(
                        children: [
                          button(
                            l('采购', 'Purchase', '採購', 'ซื้อ'),
                            canWrite ? () => purchase(current!) : null,
                            primary: true,
                          ),
                          button(
                            l('借酒', 'Loan', '借酒', 'ยืม'),
                            canWrite
                                ? () => productAction('borrow', current!)
                                : null,
                          ),
                          button(
                            l('破损', 'Damage', '破損', 'เสียหาย'),
                            canWrite
                                ? () => productAction('damage', current!)
                                : null,
                          ),
                          button(
                            l('遗失', 'Loss', '遺失', 'สูญหาย'),
                            canWrite
                                ? () => productAction('loss', current!)
                                : null,
                          ),
                          button(
                            l('预警设置', 'Stock warning', '預警設定', 'ตั้งการเตือน'),
                            canWrite ? () => policy(current!) : null,
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),
                      label(
                        l('现存批次', 'Available batches', '現存批次', 'ล็อตคงเหลือ'),
                        size: 17,
                        weight: FontWeight.bold,
                      ),
                      const Divider(),
                      for (final b in rows(
                        'batches',
                      ).where((b) => b['productRef'] == selected))
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: label(
                            '${b['location'] ?? l('未分配柜格', 'Unassigned', '未分配櫃格', 'ยังไม่กำหนดช่อง')} · ${b['quantity']}',
                          ),
                          subtitle: label(
                            '${b['batchNumber'] ?? b['batchRef']} · ${b['supplierName'] ?? ''}\n${time(b['createdAt'])} · ${money(b['unitCostCents'])}',
                            size: 12,
                            color: muted,
                          ),
                        ),
                    ],
                  ),
                ),
        ),
      ),
    ],
  );
  Widget counts() => box(
    Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          children: [
            for (final entry in [
              ('opening', l('首次清点', 'Opening count', '首次清點', 'นับเริ่มต้น')),
              ('count', l('每周盘点', 'Weekly count', '每週盤點', 'นับประจำสัปดาห์')),
              ('handover', l('交接盘点', 'Handover count', '交接盤點', 'นับส่งมอบ')),
            ])
              button(
                entry.$2,
                () => setState(() {
                  countType = entry.$1;
                  unawaited(saveDraft());
                }),
                primary: countType == entry.$1,
              ),
          ],
        ),
        TextFormField(
          initialValue: countNote,
          onChanged: (v) {
            countNote = v;
            unawaited(saveDraft());
          },
          decoration: InputDecoration(
            labelText: l(
              '盘点备注 / 交接人员',
              'Count note / handover staff',
              '盤點備註 / 交接人員',
              'หมายเหตุ / ผู้ส่งมอบ',
            ),
          ),
        ),
        const SizedBox(height: 10),
        label(
          '${l('上次盘点', 'Last count', '上次盤點', 'นับล่าสุด')}: ${time(data?['lastCountAt'])}',
          color: muted,
        ),
        const SizedBox(height: 10),
        Expanded(
          child: ListView(
            children: [
              if (visibleProducts.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    l(
                      '没有符合条件的商品',
                      'No matching products',
                      '沒有符合條件的商品',
                      'ไม่มีสินค้าที่ตรงกัน',
                    ),
                  ),
                ),
              for (final p in visibleProducts)
                ListTile(
                  onTap: canWrite ? () => productAction('count', p) : null,
                  leading: Icon(
                    countDraft.containsKey(p['productRef'])
                        ? Icons.check_circle
                        : Icons.radio_button_unchecked,
                    color: countDraft.containsKey(p['productRef'])
                        ? green
                        : muted,
                  ),
                  title: label(productName('${p['productRef']}')),
                  subtitle: label(
                    '${l('账面', 'Book', '帳面', 'บัญชี')} ${p['onHand']}  ·  ${l('预留', 'Reserved', '預留', 'จอง')} ${p['reserved']}',
                    size: 12,
                    color: muted,
                  ),
                  trailing: label(
                    countDraft.containsKey(p['productRef'])
                        ? '${l('实盘', 'Counted', '實盤', 'นับได้')} ${countDraft[p['productRef']]!['quantity']}'
                        : '—',
                    size: 21,
                  ),
                ),
            ],
          ),
        ),
        Row(
          children: [
            Expanded(
              child: label(
                '${countDraft.length} / ${rows('products').length} ${l('款已盘', 'counted', '款已盤', 'รายการนับแล้ว')}',
                color: muted,
              ),
            ),
            button(
              l('提交已盘商品', 'Submit counted items', '提交已盤商品', 'ส่งรายการที่นับ'),
              !canWrite || countDraft.isEmpty
                  ? null
                  : () async {
                      if (await confirm(
                            l(
                              '确认盘点差异',
                              'Confirm count',
                              '確認盤點差異',
                              'ยืนยันผลนับ',
                            ),
                            l(
                              '只调整已录入的商品，未盘商品不会归零。库存变化时需要重核。',
                              'Only counted products change. Other goods remain untouched. Stock changes require recount.',
                              '只調整已錄入的商品，未盤商品不會歸零。庫存變化時需要重核。',
                              'ปรับเฉพาะสินค้าที่นับ รายการอื่นไม่เปลี่ยน หากสต็อกเปลี่ยนต้องนับใหม่',
                            ),
                          ) !=
                          true) {
                        return;
                      }
                      if (await submit({
                        'action': countType,
                        'items': countDraft.values.toList(),
                        'note': countNote,
                      })) {
                        setState(() => countDraft.clear());
                        await saveDraft();
                      }
                    },
              primary: true,
            ),
          ],
        ),
      ],
    ),
  );
  Widget loans() => box(
    ListView(
      children: [
        label(
          l('借出未归还', 'Outstanding loans', '借出未歸還', 'ยืมค้างคืน'),
          size: 20,
          weight: FontWeight.bold,
        ),
        const SizedBox(height: 12),
        label(
          l(
            '从库存商品中点击“借酒”登记；归还时由收酒人扫码。',
            'Register a loan from a stock item. Scan the receiver when returning.',
            '從庫存商品中點擊「借酒」登記；歸還時由收酒人掃碼。',
            'ยืมจากหน้าสินค้า สแกนผู้รับเมื่อนำคืน',
          ),
          color: muted,
        ),
        for (final loan in rows('loans')) ...loanRow(loan),
      ],
    ),
  );
  List<Widget> loanRow(Map<String, dynamic> loan) {
    final d = loan['items'] as Map;
    final returns = loan['returns'] as List? ?? [];
    final left =
        (d['quantity'] as num).toInt() -
        returns.fold<int>(0, (n, r) => n + (r['quantity'] as num).toInt());
    if (left <= 0) return [];
    return [
      const Divider(),
      ListTile(
        title: label(
          '${loan['member'] ?? loan['userAccount']} · ${productName('${d['productRef']}')}',
        ),
        subtitle: label(
          '${time(loan['createdAt'])} · ${loan['userAccount']}',
          color: muted,
          size: 12,
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            label('${l('未还', 'Outstanding', '未還', 'ค้าง')} $left'),
            const SizedBox(width: 20),
            button(
              l('还酒', 'Return', '還酒', 'คืน'),
              canWrite ? () => returnLoan(loan) : null,
            ),
          ],
        ),
      ),
    ];
  }

  String purchaseState(String status) => switch (status) {
    'draft' => l('草稿', 'Draft', '草稿', 'ร่าง'),
    'pending' => l('待批准', 'Awaiting approval', '待批准', 'รออนุมัติ'),
    'approved' => l(
      '已批准 · 待采购',
      'Approved · awaiting purchase',
      '已批准 · 待採購',
      'รอซื้อ',
    ),
    'ordered' => l(
      '已采购 · 待入库',
      'Ordered · awaiting receipt',
      '已採購 · 待入庫',
      'รอรับ',
    ),
    'received' => l('已收齐', 'Received', '已收齊', 'รับครบ'),
    _ => l('已取消', 'Cancelled', '已取消', 'ยกเลิก'),
  };
  Widget purchases({bool receiving = false}) => box(
    ListView(
      children: [
        Row(
          children: [
            Expanded(
              child: label(
                receiving
                    ? l('收货入库', 'Receive stock', '收貨入庫', 'รับสินค้า')
                    : l(
                        '采购申请批次',
                        'Purchase applications',
                        '採購申請批次',
                        'คำขอซื้อ',
                      ),
                size: 20,
                weight: FontWeight.bold,
              ),
            ),
            if (!receiving)
              button(
                l('新增采购申请', 'New purchase request', '新增採購申請', 'คำขอซื้อใหม่'),
                canWrite ? () => manualPurchase() : null,
                primary: true,
              ),
          ],
        ),
        label(
          l(
            receiving
                ? '选择已采购批次 → 逐项确认到货数量和柜格；凭证可后补。'
                : '草稿可以跨天追加，确定后提交；老板在手机批准，授权人员在 APP 采购。',
            receiving
                ? 'Select an ordered batch and receive each item into a cabinet.'
                : 'Keep adding to a saved draft. Submit to owner approval and purchase in APP.',
            receiving
                ? '選擇已採購批次 → 逐項確認到貨數量和櫃格；憑證可後補。'
                : '草稿可以跨天追加，確定後提交；老闆在手機批准，授權人員在 APP 採購。',
            receiving ? 'เลือกชุดที่ซื้อแล้ว รับแต่ละรายการเข้าช่องเก็บ' : 'เพิ่มสินค้าลงร่างข้ามวัน ส่งให้เจ้าของอนุมัติและซื้อผ่าน APP',
          ),
          color: muted,
        ),
        const SizedBox(height: 16),
        for (final b
            in (rows('purchaseBatches')
                .where(
                  (b) =>
                      !(b['status'] == 'cancelled' &&
                          b['applicationNumber'] == null) &&
                      (!receiving ||
                          ['ordered', 'received'].contains(b['status'])),
                )
                .toList()
              ..sort(
                (a, b) => '${b['createdAt']}'.compareTo('${a['createdAt']}'),
              )))
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Material(
              color: const Color(0xFFF1F4EE),
              borderRadius: BorderRadius.circular(12),
              child: ListTile(
                key: ValueKey('purchase-batch-${b['batchRef']}'),
                minVerticalPadding: 16,
                title: label(
                  '${b['title']}',
                  size: 18,
                  weight: FontWeight.w600,
                ),
                subtitle: label(
                  '${b['batchNumber'] ?? '—'} · ${b['itemCount']} ${l('项商品', 'items', '項商品', 'รายการ')} · ${money(b['totalCostCents'])} · ${time(b['createdAt'])}',
                  color: muted,
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    label(
                      purchaseState('${b['status']}'),
                      color: b['status'] == 'pending'
                          ? Colors.orange.shade800
                          : green,
                    ),
                    const SizedBox(width: 10),
                    if (!receiving &&
                        b['status'] == 'draft' &&
                        b['applicationNumber'] == null &&
                        canWrite)
                      IconButton(
                        key: ValueKey('delete-purchase-draft-${b['batchRef']}'),
                        tooltip: l('删除草稿', 'Delete draft', '刪除草稿', 'ลบร่าง'),
                        constraints: const BoxConstraints(
                          minWidth: 48,
                          minHeight: 48,
                        ),
                        onPressed: working
                            ? null
                            : () => deletePurchaseDraft(b),
                        icon: const Icon(Icons.delete_outline),
                      ),
                    const Icon(Icons.chevron_right),
                  ],
                ),
                onTap: () => openBatch(b, receiving: receiving),
              ),
            ),
          ),
        if (!receiving) ...[
          const Divider(height: 32),
          label(
            l(
              '自动补货建议',
              'Replenishment suggestions',
              '自動補貨建議',
              'แนะนำเติมสินค้า',
            ),
            size: 18,
            weight: FontWeight.bold,
          ),
          for (final p in rows(
            'products',
          ).where((p) => (p['suggested'] as num? ?? 0) > 0))
            ListTile(
              title: label(productName('${p['productRef']}')),
              subtitle: label(
                '${l('建议补货', 'Suggested units', '建議補貨', 'จำนวนแนะนำ')} ${p['suggested']}',
              ),
              trailing: button(
                l('加入批次', 'Add to batch', '加入批次', 'เพิ่มในชุด'),
                canWrite ? () => purchase(p) : null,
              ),
            ),
        ],
        if (receiving &&
            rows('purchases').any((p) => p['applicationBatchRef'] == null)) ...[
          const Divider(height: 32),
          label(
            l(
              '之前采购 · 待入库',
              'Legacy purchases · awaiting receipt',
              '之前採購 · 待入庫',
              'รายการเดิมรอรับ',
            ),
            size: 18,
            weight: FontWeight.bold,
          ),
          for (final p in rows(
            'purchases',
          ).where((p) => p['applicationBatchRef'] == null))
            ListTile(
              title: label(productName('${p['productRef']}')),
              subtitle: label(
                '${p['received']} / ${p['quantity']} · ${money(p['unitCostCents'])}',
                color: muted,
              ),
              trailing: button(
                l('入库', 'Receive', '入庫', 'รับเข้า'),
                canWrite ? () => receive(p) : null,
                primary: true,
              ),
            ),
        ],
      ],
    ),
  );
  String actionName(String a) => switch (a) {
    'retail_price' => l(
      '零售价修改',
      'Retail price change',
      '零售價修改',
      'เปลี่ยนราคาขาย',
    ),
    'opening' => l('首次清点', 'Opening count', '首次清點', 'นับเริ่มต้น'),
    'count' => l('盘点', 'Count', '盤點', 'ตรวจนับ'),
    'handover' => l('交接盘点', 'Handover', '交接盤點', 'ส่งมอบ'),
    'borrow' => l('借酒', 'Loan', '借酒', 'ยืม'),
    'return' => l('还酒', 'Return', '還酒', 'คืน'),
    'damage' => l('破损', 'Damage', '破損', 'เสียหาย'),
    'loss' => l('遗失', 'Loss', '遺失', 'สูญหาย'),
    'order_paid' => l('销售扣库', 'Sale stock deduction', '銷售扣庫', 'ตัดสต็อกขาย'),
    'test_stock' => l('测试库存', 'Test stock', '測試庫存', 'สต็อกทดสอบ'),
    'sale' => l('销售出库', 'Sale', '銷售出庫', 'ขาย'),
    'refund' => l('退款退库', 'Refund return', '退款退庫', 'คืนสินค้าคืนเงิน'),
    'purchase_receive' => l('采购入库', 'Purchase receipt', '採購入庫', 'รับซื้อเข้า'),
    'purchase_batch_save' => l('采购申请', 'Purchase request', '採購申請', 'คำขอซื้อ'),
    'purchase_batch_delete' => l(
      '删除采购草稿',
      'Delete purchase draft',
      '刪除採購草稿',
      'ลบร่างคำขอซื้อ',
    ),
    'purchase_batch_review' => l(
      '申请审批',
      'Application review',
      '申請審批',
      'อนุมัติคำขอ',
    ),
    'purchase_batch_order' => l(
      '确认采购',
      'Purchase confirmed',
      '確認採購',
      'ยืนยันซื้อ',
    ),
    'purchase_batch_document' => l(
      '采购凭证',
      'Purchase document',
      '採購憑證',
      'เอกสารซื้อ',
    ),
    'purchase' => l('采购', 'Purchase', '採購', 'ซื้อ'),
    'receive' => l('入库', 'Receive', '入庫', 'รับเข้า'),
    'policy' => l('预警设置', 'Stock warning', '預警設定', 'การเตือน'),
    'supplier' => l('供应商', 'Supplier', '供應商', 'ผู้ขาย'),
    'locations' => l('柜格设置', 'Cabinets', '櫃格設定', 'ช่องเก็บ'),
    'cancel_purchase' => l('取消采购', 'Cancel purchase', '取消採購', 'ยกเลิกซื้อ'),
    _ => a,
  };
  Widget history() => box(
    ListView(
      children: [
        label(
          l(
            '库存单据 · 最近 50 笔',
            'Inventory documents · latest 50',
            '庫存單據 · 最近 50 筆',
            'เอกสารคลัง · ล่าสุด 50',
          ),
          size: 20,
          weight: FontWeight.bold,
        ),
        for (final h in rows(
          'history',
        )..sort((a, b) => (b['rowId'] as num).compareTo(a['rowId'] as num)))
          ListTile(
            title: label(
              '${actionName('${h['type']}')} · ${time(h['createdAt'])}',
            ),
            subtitle: label(
              '${h['member'] ?? h['employee']} · ${(h['details'] as Map?)?['note'] ?? ''}',
              color: muted,
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => showDialog<void>(
              context: context,
              builder: (context) => AlertDialog(
                title: Text(actionName('${h['type']}')),
                content: SizedBox(
                  width: 620,
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        label(time(h['createdAt'])),
                        label(
                          '${l('经办', 'Operator', '經辦', 'ผู้ดำเนินการ')}: ${h['employee']}',
                        ),
                        if (h['member'] != null)
                          label('${h['member']} · ${h['userAccount']}'),
                        const Divider(),
                        if ((h['details'] as Map?)?['productRef'] != null)
                          label(productName('${h['details']['productRef']}')),
                        if (h['type'] == 'retail_price')
                          label(
                            '${l('零售价', 'Retail price', '零售價', 'ราคาขาย')}: '
                            '${money((h['receipt'] as Map?)?['oldPriceCents'])}'
                            ' → ${money((h['receipt'] as Map?)?['priceCents'])}',
                          ),
                        if ((h['details'] as Map?)?['quantity'] != null)
                          label(
                            '${l('数量', 'Units', '數量', 'จำนวน')}: ${h['details']['quantity']}',
                          ),
                        for (final item
                            in (h['details'] as Map?)?['items'] as List? ?? [])
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: label(
                              '${productName('${item['productRef']}')}\n${item['expectedOnHand']} → ${item['quantity']} · ${item['location']}',
                            ),
                          ),
                        label('${(h['details'] as Map?)?['note'] ?? ''}'),
                        if ((h['details'] as Map?)?['document'] != null)
                          label(
                            '${l('底单号', 'Document number', '底單號', 'เลขเอกสาร')}: ${h['details']['document']['number'] ?? ''}',
                          ),
                        for (final id
                            in ((h['details'] as Map?)?['document']
                                        as Map?)?['fileIds']
                                    as List? ??
                                [])
                          button(
                            l('查看底单', 'View document', '查看底單', 'ดูเอกสาร'),
                            () => document('$id'),
                          ),
                      ],
                    ),
                  ),
                ),
                actions: [
                  button(
                    l('关闭', 'Close', '關閉', 'ปิด'),
                    () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
          ),
        if (rows('history').length == 50)
          button(
            l('更早记录', 'Earlier records', '更早記錄', 'ก่อนหน้า'),
            () => load(
              before: rows('history')
                  .map((h) => (h['rowId'] as num).toInt())
                  .reduce(min),
            ),
          ),
        const Divider(height: 30),
        label(
          l(
            '最近出入库流水（含销售）',
            'Recent movements including sales',
            '最近出入庫流水（含銷售）',
            'เคลื่อนไหวล่าสุดรวมการขาย',
          ),
          size: 18,
          weight: FontWeight.bold,
        ),
        Wrap(
          spacing: 8,
          children: [
            for (final f in [
              ('all', l('全部', 'All', '全部', 'ทั้งหมด')),
              ('in', l('进货 / 入库', 'Incoming', '進貨 / 入庫', 'รับเข้า')),
              ('out', l('出货 / 去向', 'Outgoing', '出貨 / 去向', 'จ่ายออก')),
            ])
              ChoiceChip(
                label: Text(f.$2),
                selected: movementFilter == f.$1,
                onSelected: (_) => setState(() => movementFilter = f.$1),
              ),
          ],
        ),
        for (final m in rows('movements').where(
          (m) =>
              movementFilter == 'all' ||
              (movementFilter == 'in'
                  ? (m['quantity'] as num) > 0
                  : (m['quantity'] as num) < 0),
        ))
          ListTile(
            title: label(productName('${m['productRef']}')),
            subtitle: label(
              '${time(m['createdAt'])} · ${actionName('${m['type']}')}\n${m['location'] ?? ''} · ${m['batchNumber'] ?? m['batchRef']} · ${m['supplierName'] ?? ''}\n${m['sourceRef'] ?? ''}',
              size: 12,
              color: muted,
            ),
            trailing: label(
              '${(m['quantity'] as num) > 0 ? '+' : ''}${m['quantity']}',
            ),
          ),
      ],
    ),
  );
  Widget suppliers() => box(
    Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: label(
                l('供应商', 'Suppliers', '供應商', 'ผู้ขาย'),
                size: 20,
                weight: FontWeight.bold,
              ),
            ),
            button(
              l('新增供应商', 'Add supplier', '新增供應商', 'เพิ่มผู้ขาย'),
              canWrite ? () => supplier() : null,
              primary: true,
            ),
          ],
        ),
        Expanded(
          child: ListView(
            children: [
              for (final s in rows('suppliers'))
                ListTile(
                  onTap: canWrite ? () => supplier(s) : null,
                  title: label('${s['name']}'),
                  subtitle: label(
                    '${s['contact']}  ${s['phone']}\n${s['notes']}',
                    color: muted,
                  ),
                  trailing: TextButton.icon(
                    onPressed: () => showDialog<void>(
                      context: context,
                      builder: (_) => SupplierCatalogDialog(
                        name: '${s['name']}',
                        l: l,
                        load: () => widget.auth.inventory({
                          'action': 'supplier_catalog',
                          'supplierRef': s['supplierRef'],
                        }),
                      ),
                    ),
                    icon: const Icon(Icons.menu_book_outlined),
                    label: Text(
                      l('采购备选', 'Procurement catalog', '採購備選', 'รายการจัดซื้อ'),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    ),
  );
  @override
  Widget build(BuildContext context) {
    final titles = [
      l('库存', 'Stock', '庫存', 'สต็อก'),
      l('盘点', 'Count', '盤點', 'ตรวจนับ'),
      l('借还酒', 'Loans', '借還酒', 'ยืม / คืน'),
      l('采购申请', 'Purchase requests', '採購申請', 'คำขอซื้อ'),
      l('收货入库', 'Receive stock', '收貨入庫', 'รับสินค้า'),
      l('流水', 'History', '流水', 'ประวัติ'),
      l('供应商', 'Suppliers', '供應商', 'ผู้ขาย'),
    ];
    return ColoredBox(
      color: paper,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                label(
                  l('库存管理', 'Inventory', '庫存管理', 'จัดการคลัง'),
                  size: 24,
                  weight: FontWeight.bold,
                ),
                const SizedBox(width: 24),
                Expanded(
                  child: TextField(
                    controller: search,
                    onChanged: (_) => filterChanged(() {}),
                    decoration: InputDecoration(
                      hintText: l(
                        '查找商品 / 规格',
                        'Search product / size',
                        '查找商品 / 規格',
                        'ค้นหาสินค้า / ขนาด',
                      ),
                      prefixIcon: const Icon(Icons.search),
                      isDense: true,
                      border: const OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                IconButton(
                  tooltip: l(
                    '柜格设置',
                    'Cabinet settings',
                    '櫃格設定',
                    'ตั้งค่าช่องเก็บ',
                  ),
                  onPressed: canWrite && !working ? cabinets : null,
                  icon: const Icon(Icons.shelves),
                ),
                if (loading || working)
                  const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                IconButton(
                  onPressed: working || loading ? null : () => load(),
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Wrap(
              children: [
                for (var i = 0; i < titles.length; i++)
                  KeyedSubtree(
                    key: ValueKey('inventory-tab-$i'),
                    child: button(
                      titles[i],
                      () => setState(() => tab = i),
                      primary: tab == i,
                    ),
                  ),
              ],
            ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: label(error!, color: Colors.red),
              ),
            if (pending != null)
              Row(
                children: [
                  Expanded(
                    child: label(
                      l(
                        '上次操作未完成',
                        'Previous operation needs checking',
                        '上次操作未完成',
                        'ต้องตรวจสอบรายการก่อนหน้า',
                      ),
                      color: Colors.orange.shade800,
                    ),
                  ),
                  button(l('重试', 'Retry', '重試', 'ลองใหม่'), () {
                    final p = {...pending!};
                    if (p['action'] == 'borrow' || p['action'] == 'return') {
                      unawaited(
                        scan(l('重新扫码', 'Scan again', '重新掃碼', 'สแกนใหม่'), p),
                      );
                    } else {
                      unawaited(submit(p));
                    }
                  }),
                ],
              ),
            if (pending != null)
              Align(
                alignment: Alignment.centerRight,
                child: button(
                  l('重新编辑', 'Edit again', '重新編輯', 'แก้ไขใหม่'),
                  working ? null : () => unawaited(resolvePending()),
                ),
              ),
            Expanded(
              child: data == null
                  ? Center(
                      child: label(
                        l(
                          '正在读取库存',
                          'Loading inventory',
                          '正在讀取庫存',
                          'กำลังโหลดคลัง',
                        ),
                      ),
                    )
                  : switch (tab) {
                      0 || 1 => Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          productFilters(categoryRail: true),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              children: [
                                productFilters(),
                                Expanded(
                                  child: tab == 0 ? stockList() : counts(),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      2 => loans(),
                      3 => purchases(),
                      4 => purchases(receiving: true),
                      5 => history(),
                      _ => suppliers(),
                    },
            ),
          ],
        ),
      ),
    );
  }
}
