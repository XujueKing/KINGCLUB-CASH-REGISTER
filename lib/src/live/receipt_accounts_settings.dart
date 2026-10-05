import 'package:flutter/material.dart';

import '../auth/staff_auth_controller.dart';
import '../strings.dart';
import 'recharge_touch_dialog.dart' show rechargeText;

class ReceiptAccountsSettings extends StatefulWidget {
  const ReceiptAccountsSettings({
    super.key,
    required this.auth,
    required this.language,
  });
  final StaffAuthController auth;
  final UiLanguage language;
  @override
  State<ReceiptAccountsSettings> createState() =>
      _ReceiptAccountsSettingsState();
}

class _ReceiptAccountsSettingsState extends State<ReceiptAccountsSettings> {
  final name = TextEditingController();
  List<String> accounts = [];
  int revision = 0;
  bool loading = true, saving = false, failed = false, loaded = false;
  String t(String zh, String en, String tw, String th) =>
      rechargeText(widget.language, zh, en, tw, th);
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    setState(() {
      loading = true;
      failed = false;
    });
    try {
      final result = await widget.auth.storeMembers({
        'action': 'receiptAccounts',
      });
      if (!mounted) return;
      final settings = result['receiptSettings'];
      accounts = List<String>.from(settings['accounts']);
      revision = settings['revision'] as int;
      loaded = true;
    } catch (_) {
      failed = true;
    }
    if (mounted) setState(() => loading = false);
  }

  Future<void> save() async {
    if (!loaded || saving || name.text.trim().isNotEmpty) return;
    setState(() {
      saving = true;
      failed = false;
    });
    try {
      await widget.auth.storeMembers({
        'action': 'receiptAccountsSave',
        'receiptSettings': {'revision': revision, 'accounts': accounts},
      });
      if (mounted) Navigator.pop(context);
    } catch (_) {
      if (mounted) {
        setState(() {
          saving = false;
          failed = true;
        });
      }
    }
  }

  void add() {
    final value = name.text.trim();
    if (value.length < 2 || accounts.length >= 20 || accounts.contains(value)) {
      return;
    }
    setState(() {
      accounts.add(value);
      name.clear();
    });
  }

  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !saving,
    child: AlertDialog(
      title: Text(
        t(
          '银行／第三方收款码设置',
          'Bank / third-party QR settings',
          '銀行／第三方收款碼設定',
          'ตั้งค่า QR ธนาคาร / ผู้ให้บริการ',
        ),
      ),
      content: SizedBox(
        width: 620,
        height: 400,
        child: loading
            ? const Center(child: CircularProgressIndicator())
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    t(
                      '按实际收款贴纸配置名称，收款时直接选择。',
                      'Name each payment sticker for selection at checkout.',
                      '按實際收款貼紙配置名稱，收款時直接選擇。',
                      'ตั้งชื่อ QR รับเงินเพื่อเลือกตอนชำระ',
                    ),
                  ),
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: name,
                          enabled: loaded && !saving,
                          maxLength: 100,
                          onChanged: (_) => setState(() {}),
                          onSubmitted: (_) => add(),
                          decoration: InputDecoration(
                            labelText: t(
                              '收款码名称',
                              'Payment QR name',
                              '收款碼名稱',
                              'ชื่อ QR รับเงิน',
                            ),
                            hintText: t(
                              '例如：收钱吧·门店账户',
                              'Example: provider / store account',
                              '例如：收錢吧·門店帳戶',
                              'ผู้ให้บริการ / บัญชีร้าน',
                            ),
                            counterText: '',
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      FilledButton.icon(
                        onPressed:
                            !loaded ||
                                saving ||
                                name.text.trim().length < 2 ||
                                accounts.length >= 20 ||
                                accounts.contains(name.text.trim())
                            ? null
                            : add,
                        icon: const Icon(Icons.add),
                        label: Text(t('添加', 'Add', '新增', 'เพิ่ม')),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Expanded(
                    child: ListView(
                      children: [
                        for (final value in accounts)
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: const Icon(Icons.qr_code),
                            title: Text(value),
                            trailing: IconButton(
                              onPressed: saving
                                  ? null
                                  : () =>
                                        setState(() => accounts.remove(value)),
                              icon: const Icon(Icons.delete_outline),
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (failed)
                    Text(
                      t(
                        '配置未保存，请重新打开核对设置后重试',
                        'Not saved. Reopen to reload settings and retry.',
                        '配置未儲存，請重新開啟核對設定後重試',
                        'ยังไม่บันทึก โปรดเปิดใหม่และลองอีกครั้ง',
                      ),
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: saving ? null : () => Navigator.pop(context),
          child: Text(t('取消', 'Cancel', '取消', 'ยกเลิก')),
        ),
        FilledButton(
          onPressed: !loaded || loading || saving || name.text.trim().isNotEmpty
              ? null
              : save,
          child: Text(t('保存', 'Save', '儲存', 'บันทึก')),
        ),
      ],
    ),
  );
}
