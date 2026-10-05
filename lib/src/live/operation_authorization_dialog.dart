import 'dart:async';

import 'package:flutter/material.dart';

import '../scan_icon.dart';

import '../auth/staff_auth_controller.dart';
import '../hardware/scanner_input.dart';
import '../strings.dart';

Future<String?> scanPriceAuthorization(
  BuildContext context, {
  required StaffAuthController auth,
  required UiLanguage language,
  required Map<String, Object> scope,
}) => showDialog<String>(
  context: context,
  barrierDismissible: false,
  builder: (_) => _Authorization(auth: auth, language: language, scope: scope),
);

class _Authorization extends StatefulWidget {
  const _Authorization({
    required this.auth,
    required this.language,
    required this.scope,
  });
  final StaffAuthController auth;
  final UiLanguage language;
  final Map<String, Object> scope;
  @override
  State<_Authorization> createState() => _AuthorizationState();
}

class _AuthorizationState extends State<_Authorization> {
  StreamSubscription<String>? subscription;
  bool busy = false, failed = false;
  String words(List<String> v) => v[widget.language.index];
  @override
  void initState() {
    super.initState();
    subscription = ScannerInput.codes.listen((code) {
      if (mounted && ModalRoute.of(context)?.isCurrent == true) {
        unawaited(scan(code));
      }
    });
  }

  Future<void> scan(String code) async {
    if (busy || !mounted) return;
    setState(() {
      busy = true;
      failed = false;
    });
    try {
      final ref = await widget.auth.authorizeItemPrice(
        scope: widget.scope,
        identityCode: code,
      );
      if (mounted) Navigator.pop(context, ref);
    } catch (_) {
      if (mounted) {
        setState(() {
          busy = false;
          failed = true;
        });
      }
    }
  }

  @override
  void dispose() {
    subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      words([
        '负责人扫码授权',
        'Manager authorization',
        '负责人扫码授权',
        'สแกนเพื่ออนุมัติ',
      ]),
    ),
    content: SizedBox(
      width: 420,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const ScanIcon(size: 64),
          const SizedBox(height: 16),
          Text(
            words([
              '请出示有本店权限的 KING 会员码',
              'Scan an authorized manager?s KING member code',
              '请出示有本店权限的 KING 会员码',
              'สแกนรหัสสมาชิก KING ของผู้มีสิทธิ์ร้านนี้',
            ]),
          ),
          const SizedBox(height: 12),
          Text(
            words([
              '等待扫码，无需点击输入框',
              'Ready to scan — no input focus needed',
              '等待掃碼，無需點擊輸入框',
              'พร้อมสแกน ไม่ต้องแตะช่องกรอก',
            ]),
          ),
          if (busy)
            const Padding(
              padding: EdgeInsets.all(12),
              child: CircularProgressIndicator(),
            ),
          if (failed)
            Text(
              words([
                '未获授权，请确认权限并刷新会员码重扫',
                'Not authorized. Check permissions and refresh the code.',
                '未获授权，请确认权限并刷新会员码重扫',
                'ไม่ได้รับอนุญาต กรุณาตรวจสอบสิทธิ์และรีเฟรชรหัส',
              ]),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: busy ? null : () => Navigator.pop(context),
        child: Text(words(['取消', 'Cancel', '取消', 'ยกเลิก'])),
      ),
    ],
  );
}
