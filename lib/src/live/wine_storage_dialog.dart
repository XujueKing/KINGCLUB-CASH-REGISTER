import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';

import '../auth/staff_auth_controller.dart';
import '../auth/session_vault.dart';
import '../hardware/scanner_input.dart';
import '../strings.dart';
import 'member_identity.dart';
import 'touch_quantity.dart';
import 'wine_location_picker.dart';
import '../hardware/wine_label_printer.dart';

class WineStorageDialog extends StatefulWidget {
  const WineStorageDialog({
    super.key,
    required this.auth,
    required this.language,
    required this.tableRef,
    required this.sessionRef,
    required this.orderRef,
    required this.productRef,
    required this.name,
    required this.isCurrent,
    this.storage,
    this.printLabel,
  });
  final StaffAuthController auth;
  final UiLanguage language;
  final String tableRef, sessionRef, orderRef, productRef, name;
  final bool Function() isCurrent;
  final SecretStorage? storage;
  final Future<String> Function(WineLabel label, bool reprint)? printLabel;
  @override
  State<WineStorageDialog> createState() => _WineStorageDialogState();
}

class _WineStorageDialogState extends State<WineStorageDialog>
    with WidgetsBindingObserver {
  final quantity = TextEditingController(text: '1');
  late final vault = widget.storage ?? PlatformSecretStorage();
  StreamSubscription<String>? scans;
  String? key;
  Map<String, dynamic>? pending;
  List<String> locations = [];
  Map<String, dynamic>? confirmedReceipt;
  bool printFailed = false;
  final sentLabels = <String>{};
  String? locationCode;
  int maximum = 0, stored = 0, percent = 50;
  bool loading = true,
      busy = false,
      ready = false,
      failed = false,
      foreground = true;
  String text(List<String> v) => v[widget.language.index];
  Map<String, dynamic> get scope => {
    'tableRef': widget.tableRef,
    'sessionRef': widget.sessionRef,
    'orderRef': widget.orderRef,
    'productRef': widget.productRef,
  };
  bool get current => mounted && foreground && widget.isCurrent();
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    scans = ScannerInput.codes.listen((code) {
      if (current &&
          ready &&
          !busy &&
          ModalRoute.of(context)?.isCurrent == true &&
          MemberIdentity.codePattern.hasMatch(code))
        unawaited(deposit(code));
    });
    unawaited(load());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    foreground = s == AppLifecycleState.resumed;
  }

  @override
  void dispose() {
    scans?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    quantity.dispose();
    super.dispose();
  }

  Future<void> load() async {
    setState(() {
      loading = true;
      failed = false;
    });
    try {
      final identity = widget.auth.session!;
      final digest = await Sha256().hash(
        utf8.encode(
          jsonEncode([
            identity.base.toString(),
            identity.storeRef,
            identity.employeeRef,
            identity.deviceId,
            scope,
          ]),
        ),
      );
      key =
          'wine_storage_${digest.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';
      final saved = await vault.read(key!);
      if (saved != null) {
        pending = Map<String, dynamic>.from(jsonDecode(saved) as Map);
        final result = await widget.auth.wineStorage({
          ...scope,
          'action': 'lookup',
          'requestId': pending!['requestId'],
        });
        if (!current) return;
        if (result['state'] == 'confirmed') {
          await finish(Map<String, dynamic>.from(result['receipt'] as Map));
          return;
        }
        if (result['state'] != 'not_observed') throw const FormatException();
        quantity.text = '${pending!['quantity']}';
        percent = pending!['remainingPercent'] as int;
        locationCode = pending!['locationCode'] as String?;
        ready = true;
      }
      final result = await widget.auth.wineStorage({
        ...scope,
        'action': 'context',
      });
      if (!current) return;
      final available = result['availableQuantity'],
          previous = result['storedQuantity'];
      if (result['state'] != 'context' ||
          available is! int ||
          available < 0 ||
          available > 1000 ||
          previous is! int ||
          previous < 0 ||
          result['storageDays'] != 30)
        throw const FormatException();
      maximum = available;
      stored = previous;
      locations = (result['locations'] as List).cast<String>();
      if (pending == null && !locations.contains(locationCode))
        locationCode = null;
      if (pending != null && locationCode == null) {
        // A prior-version unresolved deposit must never silently move shelves.
        throw const FormatException();
      }
    } catch (_) {
      if (mounted) failed = true;
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  String requestId() {
    final r = Random.secure();
    final b = List<int>.generate(16, (_) => r.nextInt(256));
    b[6] = (b[6] & 15) | 64;
    b[8] = (b[8] & 63) | 128;
    final h = b.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
  }

  Future<void> deposit(String code) async {
    if (!current || busy || key == null) return;
    setState(() {
      busy = true;
      failed = false;
    });
    try {
      pending ??= {
        'requestId': requestId(),
        'quantity': int.parse(quantity.text),
        'remainingPercent': percent,
        'expectedStoredQuantity': stored,
        'locationCode': locationCode,
      };
      final saved = jsonEncode(pending);
      await vault.write(key!, saved);
      if (await vault.read(key!) != saved) throw const FormatException();
      if (!current) return;
      final result = await widget.auth.wineStorage({
        ...scope,
        ...pending!,
        'action': 'deposit',
        'identityCode': code,
      });
      if (!current) return;
      final receipt = result['receipt'];
      if (result['state'] != 'confirmed' ||
          receipt is! Map ||
          receipt['quantity'] != pending!['quantity'] ||
          receipt['remainingPercent'] != percent ||
          receipt['locationCode'] != locationCode)
        throw const FormatException();
      await finish(Map<String, dynamic>.from(receipt));
    } catch (_) {
      if (mounted) failed = true;
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> finish(
    Map<String, dynamic> receipt, {
    bool reprint = false,
  }) async {
    confirmedReceipt = receipt;
    ready = false;
    if (mounted) setState(() => busy = true);
    try {
      final labels = (receipt['labels'] as List)
          .map((v) => WineLabel(Map<String, dynamic>.from(v as Map)))
          .toList();
      if (labels.length != receipt['quantity'] || labels.isEmpty)
        throw const FormatException();
      for (final label in labels) {
        if (sentLabels.contains(label.itemRef)) continue;
        final result =
            await (widget.printLabel?.call(label, reprint) ??
                printWineLabel(
                  auth: widget.auth,
                  label: label,
                  stillCurrent: () => current,
                  reprint: reprint,
                ));
        if (result != 'checkoutPrintSent') throw const FormatException();
        sentLabels.add(label.itemRef);
      }
      await vault.delete(key!);
      if (mounted && current) Navigator.pop(context, true);
    } catch (_) {
      if (mounted) setState(() => printFailed = true);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: AlertDialog(
      title: Text(text(['存酒', 'Store wine', '存酒', 'ฝากสุรา'])),
      content: SizedBox(
        width: 430,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.name),
              const SizedBox(height: 12),
              Text(
                text([
                  '保管30天，从本次存入时间起算',
                  'Stored for 30 days from deposit',
                  '保管30天，從本次存入時間起算',
                  'ฝากได้ 30 วันนับจากเวลาฝาก',
                ]),
              ),
              if (confirmedReceipt != null)
                Text(
                  printFailed
                      ? text([
                          '存酒已成功，标签未确认打印，可补打',
                          'Wine stored; label not confirmed. Reprint available',
                          '存酒已成功，標籤未確認列印，可補印',
                          'Stored; reprint label',
                        ])
                      : text([
                          '存酒已成功，正在打印瓶身标签',
                          'Wine stored. Printing bottle labels',
                          '存酒已成功，正在列印瓶身標籤',
                          'Stored; printing labels',
                        ]),
                )
              else if (loading)
                const LinearProgressIndicator()
              else if (!ready && !failed && maximum == 0)
                Text(
                  text([
                    '没有可存的已付款、已上酒水',
                    'No paid, served bottles available',
                    '沒有可存的已付款、已上酒水',
                    'ไม่มีสุราที่ชำระและเสิร์ฟแล้วสำหรับฝาก',
                  ]),
                )
              else if (!ready && !failed) ...[
                TouchQuantity(
                  controller: quantity,
                  maximum: maximum,
                  label: text(['瓶数', 'Bottles', '瓶數', 'จำนวนขวด']),
                  onChanged: () => setState(() {}),
                ),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final p in [100, 75, 50, 25])
                      ChoiceChip(
                        label: Text('$p%'),
                        selected: percent == p,
                        onSelected: (_) => setState(() => percent = p),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  text([
                    '存放位置（上高下低）',
                    'Storage location (top to bottom)',
                    '存放位置（上高下低）',
                    'ตำแหน่งจัดเก็บ (บนลงล่าง)',
                  ]),
                ),
                if (locations.isEmpty)
                  Text(
                    text([
                      '本店尚未设置存放位置',
                      'No storage locations configured',
                      '本店尚未設定存放位置',
                      'ยังไม่ได้ตั้งค่าตำแหน่งจัดเก็บ',
                    ]),
                  )
                else
                  WineLocationPicker(
                    locations: locations,
                    selected: locationCode,
                    onSelected: (value) => setState(() => locationCode = value),
                  ),
              ],
              if (ready && locationCode != null)
                Text(
                  locationCode!,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              if (ready)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 18),
                  child: Text(
                    text([
                      '请顾客出示 KING 会员码，扫码直接存入',
                      'Scan the guest’s KING member code to deposit',
                      '請顧客出示 KING 會員碼，掃碼直接存入',
                      'สแกนรหัสสมาชิก KING ของลูกค้าเพื่อฝาก',
                    ]),
                  ),
                ),
              if (failed)
                Text(
                  text([
                    '尚未确认存酒结果，请查询后再试',
                    'Deposit unconfirmed. Check the result before retrying.',
                    '尚未確認存酒結果，請查詢後再試',
                    'ยังไม่ยืนยันการฝาก กรุณาตรวจสอบก่อนลองใหม่',
                  ]),
                ),
            ],
          ),
        ),
      ),
      actions: [
        if (printFailed && confirmedReceipt != null)
          FilledButton(
            onPressed: busy
                ? null
                : () => finish(confirmedReceipt!, reprint: true),
            child: Text(
              text(['补打存酒标签', 'Reprint labels', '補印存酒標籤', 'Reprint labels']),
            ),
          ),

        TextButton(
          onPressed: busy
              ? null
              : () => Navigator.pop(context, confirmedReceipt != null),
          child: Text(tr(widget.language, 'staffCancelSelection')),
        ),
        if (failed)
          FilledButton(
            onPressed: busy ? null : load,
            child: Text(text(['刷新', 'Refresh', '重新整理', 'รีเฟรช'])),
          ),
        if (confirmedReceipt == null &&
            !loading &&
            !failed &&
            !ready &&
            maximum > 0)
          FilledButton(
            onPressed: locationCode == null
                ? null
                : () => setState(() => ready = true),
            child: Text(text(['存酒', 'Store wine', '存酒', 'ฝากสุรา'])),
          ),
      ],
    ),
  );
}
