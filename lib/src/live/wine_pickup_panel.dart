import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';

import '../auth/staff_auth_controller.dart';
import '../auth/session_vault.dart';
import '../hardware/scanner_input.dart';
import '../hardware/wine_label_printer.dart';
import '../strings.dart';
import 'member_identity.dart';
import 'wine_location_picker.dart';

class WinePickupPanel extends StatefulWidget {
  const WinePickupPanel({
    super.key,
    required this.auth,
    required this.language,
    required this.tableRef,
    required this.sessionRef,
    this.scannerEvents,
    this.storage,
  });
  final StaffAuthController auth;
  final UiLanguage language;
  final String? tableRef, sessionRef;
  final Stream<String>? scannerEvents;
  final SecretStorage? storage;
  @override
  State<WinePickupPanel> createState() => _WinePickupPanelState();
}

class _WinePickupPanelState extends State<WinePickupPanel>
    with WidgetsBindingObserver {
  late final vault = widget.storage ?? PlatformSecretStorage();
  StreamSubscription<String>? scanner;
  List<Map<String, dynamic>> items = [];
  List<String> locations = [];
  String? memberCode, nickname, memberNumber, message, key;
  Map<String, dynamic>? pending;
  bool busy = false, foreground = true, initializing = true;
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
    if (!foreground) {
      memberCode = null;
    }
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
      'action': 'collectionLookup',
      'requestId': pending!['requestId'],
    });
    if (!current) return true;
    if (result['state'] == 'confirmed') {
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
    if (receipt['served'] != true || receipt['collectedQuantity'] != 1)
      throw const FormatException();
    await vault.delete(key!);
    pending = null;
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
      if (MemberIdentity.codePattern.hasMatch(code)) {
        final result = await widget.auth.wineStorage({
          ...scope,
          'action': 'inventory',
          'identityCode': code,
        });
        if (!current || !identical(identity, widget.auth.session)) return;
        memberCode = code;
        nickname = result['nickname'] as String?;
        memberNumber = result['memberNumber'] as String;
        locations = (result['locations'] as List).cast<String>();
        items = (result['items'] as List)
            .map((v) => Map<String, dynamic>.from(v as Map))
            .toList();
        message = null;
        return;
      }
      if (!RegExp(r'^KC:W:[0-9A-F]{32}$').hasMatch(code) ||
          memberCode == null) {
        message = t([
          '请先扫会员码，再扫酒瓶上的存酒标签',
          'Scan member code, then the bottle label',
          '請先掃會員碼，再掃酒瓶上的存酒標籤',
          'สแกนสมาชิกก่อนแล้วสแกนฉลากขวด',
        ]);
        return;
      }
      pending = {'requestId': requestId(), 'bottleCode': code};
      final encoded = jsonEncode(pending);
      await vault.write(key!, encoded);
      if (await vault.read(key!) != encoded) throw const FormatException();
      if (!current) return;
      final result = await widget.auth.wineStorage({
        ...scope,
        ...pending!,
        'action': 'collect',
        'identityCode': memberCode,
      });
      if (!current || !identical(identity, widget.auth.session)) return;
      if (result['state'] != 'confirmed') throw const FormatException();
      await accept(Map<String, dynamic>.from(result['receipt'] as Map));
    } catch (_) {
      if (mounted) {
        memberCode = null;
        message = t([
          '未确认取酒，请重试查询；重新扫会员码后再扫瓶身码',
          'Pickup unconfirmed. Retry lookup, then rescan member and bottle',
          '未確認取酒，請重試查詢；重新掃會員碼後再掃瓶身碼',
          'ยังไม่ยืนยัน โปรดลองตรวจสอบแล้วสแกนสมาชิกและขวดใหม่',
        ]);
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> label(Map<String, dynamic> item) async {
    if (busy || !current || memberCode == null) return;
    setState(() => busy = true);
    try {
      String? location = item['locationCode'] as String?;
      if (location == null) {
        location = await showDialog<String>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(
              t(['选择存放位置', 'Choose shelf', '選擇存放位置', 'เลือกช่องเก็บ']),
            ),
            content: SizedBox(
              width: 430,
              child: SingleChildScrollView(
                child: WineLocationPicker(
                  locations: locations,
                  selected: null,
                  onSelected: (value) => Navigator.pop(context, value),
                ),
              ),
            ),
          ),
        );
        if (location == null) return;
      }
      if (!current) return;
      final result = await widget.auth.wineStorage({
        ...scope,
        'action': 'label',
        'identityCode': memberCode,
        'itemRef': item['itemRef'],
        'locationCode': location,
      });
      final label = WineLabel(
        Map<String, dynamic>.from(result['label'] as Map),
      );
      final outcome = await printWineLabel(
        auth: widget.auth,
        label: label,
        stillCurrent: () => current,
        reprint: true,
      );
      if (mounted) {
        item['locationCode'] = label.location;
        item['hasLabel'] = true;
        message = outcome == 'checkoutPrintSent'
            ? t([
                '标签已发送到打印机',
                'Label sent to printer',
                '標籤已送至印表機',
                'ส่งฉลากไปยังเครื่องพิมพ์แล้ว',
              ])
            : t([
                '打印未成功，可再次补打',
                'Print failed; reprint available',
                '列印未成功，可再次補印',
                'พิมพ์ไม่สำเร็จ ลองพิมพ์อีกครั้ง',
              ]);
      }
    } catch (_) {
      if (mounted) {
        memberCode = null;
        message = t([
          '请重新扫会员码后补打；旧存酒多瓶合并记录需先核实实物',
          'Rescan member; legacy multi-bottle records need physical verification',
          '請重新掃會員碼後補印；舊存酒多瓶合併紀錄需先核實實物',
          'สแกนสมาชิกใหม่เพื่อตรวจสอบและพิมพ์',
        ]);
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        widget.sessionRef == null
            ? t(['请先选择桌台', 'Select a table first', '請先選擇桌台', 'เลือกโต๊ะก่อน'])
            : memberCode == null
            ? t(['请出示会员码', 'Scan member code', '請出示會員碼', 'สแกนรหัสสมาชิก'])
            : t([
                '找到存放位置，扫描瓶身码即出库并已上',
                'Find the shelf and scan the bottle to collect and serve',
                '找到存放位置，掃描瓶身碼即出庫並已上',
                'ค้นหาขวดแล้วสแกนฉลากเพื่อรับและเสิร์ฟ',
              ]),
        style: const TextStyle(fontSize: 19, fontWeight: FontWeight.bold),
      ),
      if (nickname != null || memberNumber != null)
        Text('${nickname ?? ''}  ${memberNumber ?? ''}'),
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
      if (memberCode != null && items.isEmpty)
        Text(
          t([
            '本店没有可领取的存酒',
            'No available stored wine here',
            '本店沒有可領取的存酒',
            'ไม่มีไวน์ที่รับได้ในร้านนี้',
          ]),
        ),
      for (final item in items)
        Card(
          child: ListTile(
            title: Text('${item['locationCode'] ?? '—'}   ${item['name']}'),
            subtitle: Text(
              '${item['specification'] ?? ''} · ${item['remainingPercent']}% · ${item['quantity']}',
            ),
            trailing: TextButton(
              onPressed: busy || memberCode == null || item['quantity'] != 1
                  ? null
                  : () => label(item),
              child: Text(t(['补打标签', 'Print label', '補印標籤', 'พิมพ์ฉลาก'])),
            ),
          ),
        ),
    ],
  );
}
