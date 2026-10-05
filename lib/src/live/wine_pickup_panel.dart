import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';

import '../auth/staff_auth_controller.dart';
import '../auth/session_vault.dart';
import '../hardware/scanner_input.dart';
import '../strings.dart';

class WinePickupPanel extends StatefulWidget {
  const WinePickupPanel({
    super.key,
    required this.auth,
    required this.language,
    required this.tableRef,
    required this.sessionRef,
    this.scannerEvents,
    this.storage,
    this.initialCode,
    this.bottleItem,
    this.onDone,
    this.fillHeight = false,
  });
  final StaffAuthController auth;
  final UiLanguage language;
  final String? tableRef, sessionRef;
  final Stream<String>? scannerEvents;
  final SecretStorage? storage;
  final String? initialCode;
  final Map<String, dynamic>? bottleItem;
  final VoidCallback? onDone;
  final bool fillHeight;
  @override
  State<WinePickupPanel> createState() => _WinePickupPanelState();
}

class _WinePickupPanelState extends State<WinePickupPanel>
    with WidgetsBindingObserver {
  late final vault = widget.storage ?? PlatformSecretStorage();
  StreamSubscription<String>? scanner;
  List<Map<String, dynamic>> items = [];
  List<String> locations = [];
  String? message, key;
  Map<String, dynamic>? pending;
  bool busy = false, foreground = true, initializing = true;
  bool initialHandled = false, armed = false;
  String t(List<String> values) => values[widget.language.index];
  Map<String, dynamic> get scope => {
    'tableRef': widget.tableRef,
    'sessionRef': widget.sessionRef,
  };
  bool get current =>
      mounted && foreground && ModalRoute.of(context)?.isCurrent == true;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    scanner = (widget.scannerEvents ?? ScannerInput.codes).listen((code) {
      if (current && !busy && !initializing) unawaited(scan(code.trim()));
    });
    unawaited(restore());
  }

  @override
  void dispose() {
    scanner?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    if (foreground && !busy) unawaited(restore());
  }

  Future<void> restore() async {
    final identity = widget.auth.session;
    if (identity == null ||
        widget.tableRef == null ||
        widget.sessionRef == null) {
      if (mounted) setState(() => initializing = false);
      return;
    }
    try {
      final digest = await Sha256().hash(
        utf8.encode(
          jsonEncode([
            identity.base.toString(),
            identity.storeRef,
            identity.employeeRef,
            scope,
          ]),
        ),
      );
      key =
          'wine_pickup_${digest.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';
      final saved = await vault.read(key!);
      if (saved != null) {
        pending = Map<String, dynamic>.from(jsonDecode(saved) as Map);
        await recover();
      }
    } catch (_) {
      if (mounted)
        message = t([
          '取酒结果待查询，请点重试',
          'Check pickup result before retrying',
          '取酒結果待查詢，請點重試',
          'ตรวจสอบผลการรับไวน์อีกครั้ง',
        ]);
    } finally {
      if (mounted) setState(() => initializing = false);
    }
    if (current && !initialHandled && widget.initialCode != null) {
      initialHandled = true;
      await scan(widget.initialCode!);
    }
  }

  String requestId() {
    final bytes = List.generate(16, (_) => Random.secure().nextInt(256));
    bytes[6] = (bytes[6] & 15) | 64;
    bytes[8] = (bytes[8] & 63) | 128;
    final h = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
  }

  Future<bool> recover() async {
    if (pending == null) return false;
    final result = await widget.auth.wineStorage({
      ...scope,
      'action': pending!['action'] == 'requestPickup'
          ? 'requestLookup'
          : 'collectionLookup',
      'requestId': pending!['requestId'],
    });
    if (!current) return true;
    if (result['state'] == 'confirmed' || result['state'] == 'requested') {
      locations = List<String>.from(result['locations'] as List? ?? locations);
      await accept(Map<String, dynamic>.from(result['receipt'] as Map));
      return true;
    }
    if (result['state'] != 'not_observed') throw const FormatException();
    // Definitive not observed: the next physical scan gets a new id. The server
    // locks the holding too, so an older late arrival cannot collect it twice.
    await vault.delete(key!);
    pending = null;
    return false;
  }

  Future<void> accept(Map<String, dynamic> receipt) async {
    if (receipt['served'] == false && receipt['paid'] == true) {
      await vault.delete(key!);
      pending = null;
      if (mounted)
        setState(() {
          items.removeWhere((r) => r['itemRef'] == receipt['itemRef']);
          items.add(receipt);
          message = null;
        });
      return;
    }
    if (receipt['served'] != true || receipt['collectedQuantity'] != 1)
      throw const FormatException();
    await vault.delete(key!);
    pending = null;
    if (widget.bottleItem?['itemRef'] == receipt['itemRef'] && mounted) {
      Navigator.pop(context, true);
      return;
    }
    if (mounted)
      setState(() {
        items.removeWhere((r) => r['itemRef'] == receipt['itemRef']);
        message =
            t([
              '已出库、已上：',
              'Collected and served: ',
              '已出庫、已上：',
              'รับและเสิร์ฟแล้ว: ',
            ]) +
            '${receipt['name']}';
      });
  }

  Future<void> scan(String code) async {
    if (!current || busy || initializing || key == null) return;
    final identity = widget.auth.session;
    setState(() => busy = true);
    try {
      if (pending != null && await recover()) return;
      final isPickup = RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(code);
      final isBottle = RegExp(r'^KC:W:[0-9A-F]{32}$').hasMatch(code);
      if (isBottle &&
          (widget.bottleItem == null ||
              !armed ||
              widget.bottleItem!['served'] == true)) {
        message = t([
          '请点击右侧存酒卡片，选择上酒',
          'Open the stored wine card and tap Serve',
          '請點存酒卡片上酒',
          'Open wine card and tap Serve',
        ]);
        return;
      }
      if (widget.bottleItem != null && !isBottle) return;
      if (!isPickup && !isBottle) {
        message = t([
          '请扫顾客取酒码或瓶身存酒标签',
          'Scan guest pickup code or bottle label',
          '請掃顧客取酒碼或瓶身存酒標籤',
          'Scan pickup code or bottle label',
        ]);
        return;
      }
      // Keep the short-lived customer credential only in memory.
      pending = {
        'requestId': requestId(),
        'action': isPickup ? 'requestPickup' : 'collect',
        if (isBottle) 'bottleCode': code,
        if (isBottle) 'itemRef': widget.bottleItem!['itemRef'],
      };
      final encoded = jsonEncode(pending);
      await vault.write(key!, encoded);
      if (await vault.read(key!) != encoded) throw const FormatException();
      if (!current) return;
      final result = await widget.auth.wineStorage({
        ...scope,
        ...pending!,
        if (isPickup) 'pickupCode': code,
      });
      if (!current || !identical(identity, widget.auth.session)) return;
      if (result['state'] != 'confirmed' && result['state'] != 'requested')
        throw const FormatException();
      locations = List<String>.from(result['locations'] as List? ?? locations);
      await accept(Map<String, dynamic>.from(result['receipt'] as Map));
    } catch (_) {
      if (mounted) {
        message = t([
          '未确认取酒，请重试查询；重新扫取酒码后再扫瓶身码',
          'Pickup unconfirmed. Retry lookup, then rescan pickup code and bottle',
          '未確認取酒，請重試查詢；重新掃取酒碼後再掃瓶身碼',
          'ยังไม่ยืนยัน โปรดลองตรวจสอบแล้วสแกนสมาชิกและขวดใหม่',
        ]);
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.bottleItem == null && items.isNotEmpty && pending == null) {
      final receipt = items.last;
      final details = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 76,
            height: 76,
            decoration: const BoxDecoration(
              color: Color(0xffe3f2e8),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.check_rounded,
              size: 48,
              color: Color(0xff27834c),
            ),
          ),
          const SizedBox(height: 20),
          Text(
            t(['已加入消费明细', 'Added to bill', '已加入消費明細', 'เพิ่มในบิลแล้ว']),
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 25, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 24),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xffe1e8e2)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  receipt['name']?.toString() ?? '',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  '${receipt['quantity'] ?? 1} ${t(['瓶', 'bottle(s)', '瓶', 'ขวด'])}'
                  '${receipt['remainingPercent'] == null ? '' : ' · ${t(['剩余', 'Remaining', '剩餘', 'คงเหลือ'])} ${receipt['remainingPercent']}%'}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 16,
                    color: Color(0xff6b7871),
                  ),
                ),
                if (receipt['locationCode'] != null) ...[
                  const Divider(height: 28),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        t(['存放位置', 'Location', '存放位置', 'ตำแหน่ง']),
                        style: const TextStyle(
                          fontSize: 16,
                          color: Color(0xff6b7871),
                        ),
                      ),
                      const SizedBox(width: 14),
                      Text(
                        '${receipt['locationCode']}',
                        style: const TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 16),
          Text(
            t(['待上酒', 'Ready to serve', '待上酒', 'รอเสิร์ฟ']),
            style: const TextStyle(fontSize: 16, color: Color(0xff9b6915)),
          ),
          if (message != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(message!, textAlign: TextAlign.center),
            ),
        ],
      );
      return Padding(
        padding: const EdgeInsets.fromLTRB(32, 16, 32, 24),
        child: Column(
          mainAxisSize: widget.fillHeight ? MainAxisSize.max : MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.fillHeight)
              Expanded(
                child: Center(child: SingleChildScrollView(child: details)),
              )
            else
              details,
            const SizedBox(height: 20),
            FilledButton(
              key: const ValueKey('wine-pickup-done'),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(54),
                backgroundColor: const Color(0xff234c3f),
                foregroundColor: Colors.white,
                textStyle: const TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.w600,
                ),
              ),
              onPressed: widget.onDone ?? () => Navigator.maybePop(context),
              child: Text(t(['完成', 'Done', '完成', 'เสร็จสิ้น'])),
            ),
          ],
        ),
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.bottleItem != null) ...[
          Text(
            '${widget.bottleItem!['name']}',
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 18),
          Text(
            '${widget.bottleItem!['locationCode'] ?? "--"}',
            style: const TextStyle(fontSize: 52, fontWeight: FontWeight.bold),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 18),
          if (widget.bottleItem!['served'] == true)
            Text(t(['已上', 'Served', '已上', 'Served']))
          else if (!armed)
            FilledButton(
              onPressed: busy || initializing
                  ? null
                  : () => setState(() => armed = true),
              child: Text(t(['上酒', 'Serve', '上酒', 'Serve'])),
            )
          else
            Text(
              t([
                '请扫这瓶酒的瓶身二维码',
                'Scan this bottle label',
                '請掃這瓶酒的瓶身碼',
                'Scan this bottle label',
              ]),
              style: const TextStyle(fontSize: 22),
            ),
        ],
        if (busy || initializing) const LinearProgressIndicator(),
        if (message != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(message!),
          ),
        if (pending != null)
          TextButton(
            onPressed: busy
                ? null
                : () async {
                    setState(() => busy = true);
                    try {
                      await recover();
                    } catch (_) {
                    } finally {
                      if (mounted) setState(() => busy = false);
                    }
                  },
            child: Text(t(['重试查询', 'Retry lookup', '重試查詢', 'ตรวจสอบอีกครั้ง'])),
          ),
      ],
    );
  }
}
