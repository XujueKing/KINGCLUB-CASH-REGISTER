import 'package:flutter/material.dart';

import '../strings.dart';
import 'app_updates.dart';

String updateText(UiLanguage language, String key) =>
    _copy[key]![language.index];
const _copy = {
  'title': ['软件更新', 'Software update', '軟體更新', 'อัปเดตซอฟต์แวร์'],
  'ready': ['新版已就绪', 'Update ready', '新版已就緒', 'พร้อมอัปเดต'],
  'checking': [
    '正在检查版本…',
    'Checking version…',
    '正在檢查版本…',
    'กำลังตรวจสอบเวอร์ชัน…',
  ],
  'downloading': [
    '正在后台下载',
    'Downloading in background',
    '正在背景下載',
    'กำลังดาวน์โหลดเบื้องหลัง',
  ],
  'current': ['已是最新版本', 'Up to date', '已是最新版本', 'เป็นเวอร์ชันล่าสุดแล้ว'],
  'failed': [
    '暂时无法检查或下载，请稍后重试',
    'Check or download unavailable. Retry later.',
    '暫時無法檢查或下載，請稍後重試',
    'ตรวจสอบหรือดาวน์โหลดไม่ได้ โปรดลองภายหลัง',
  ],
  'unavailable': [
    '此安装包未配置更新',
    'Updates are not configured for this build',
    '此安裝包未設定更新',
    'รุ่นนี้ยังไม่ได้ตั้งค่าการอัปเดต',
  ],
  'check': ['检查更新', 'Check for updates', '檢查更新', 'ตรวจสอบอัปเดต'],
  'install': ['安装新版', 'Install update', '安裝新版', 'ติดตั้งอัปเดต'],
  'close': ['关闭', 'Close', '關閉', 'ปิด'],
  'installed': ['当前版本', 'Installed version', '目前版本', 'เวอร์ชันปัจจุบัน'],
  'help': [
    '开机及每小时自动检查，发现新版后后台下载。安装期间收银会短暂退出，数据保留。',
    'Checks at startup and hourly, then downloads in background. Installation briefly closes the app; data is retained.',
    '開機及每小時自動檢查，發現新版後背景下載。安裝期間收銀會短暫退出，資料保留。',
    'ตรวจสอบเมื่อเปิดและทุกชั่วโมง พร้อมดาวน์โหลดเบื้องหลัง การติดตั้งจะปิดแอปชั่วคราวและเก็บข้อมูลไว้',
  ],
  'safe': [
    '我已处理当前点单、收款及未保存内容，可以安装',
    'Current sales and payments are handled and drafts saved. Ready to install.',
    '我已處理目前點單、收款及未儲存內容，可以安裝',
    'ดำเนินการขายและชำระเงิน พร้อมบันทึกข้อมูลแล้ว ติดตั้งได้',
  ],
  'permission': [
    '请允许 KINGCLUB 安装应用，返回这里再点“安装新版”。',
    'Allow KINGCLUB to install apps, then return and tap Install update.',
    '請允許 KINGCLUB 安裝應用，返回這裡再點「安裝新版」。',
    'อนุญาตให้ KINGCLUB ติดตั้งแอป แล้วกลับมากดติดตั้งอัปเดต',
  ],
  'installer': [
    '请在系统窗口确认安装；取消后可随时重试。',
    'Confirm in the system installer. You can retry if cancelled.',
    '請在系統視窗確認安裝；取消後可隨時重試。',
    'ยืนยันในหน้าติดตั้งระบบ หากยกเลิกสามารถลองใหม่ได้',
  ],
};

class UpdateButton extends StatelessWidget {
  const UpdateButton({
    super.key,
    required this.language,
    this.onlyWhenReady = false,
    this.updates,
  });
  final UiLanguage language;
  final bool onlyWhenReady;
  final AppUpdates? updates;
  @override
  Widget build(BuildContext context) {
    final service = updates ?? AppUpdates.instance;
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        if (onlyWhenReady && service.stage != UpdateStage.ready) {
          return const SizedBox.shrink();
        }
        return OutlinedButton.icon(
          key: const ValueKey('app-update-open'),
          onPressed: () => showDialog<void>(
            context: context,
            barrierDismissible: false,
            builder: (_) => UpdateDialog(language: language, updates: service),
          ),
          icon: Icon(
            service.stage == UpdateStage.ready
                ? Icons.system_update
                : Icons.update,
          ),
          label: Text(
            updateText(
              language,
              service.stage == UpdateStage.ready ? 'ready' : 'title',
            ),
          ),
        );
      },
    );
  }
}

class UpdateDialog extends StatefulWidget {
  const UpdateDialog({
    super.key,
    required this.language,
    required this.updates,
  });
  final UiLanguage language;
  final AppUpdates updates;
  @override
  State<UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<UpdateDialog> {
  bool safe = false;
  String? notice;
  String t(String key) => updateText(widget.language, key);
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.updates,
    builder: (context, _) {
      final u = widget.updates;
      return PopScope(
        canPop: !u.installing,
        child: AlertDialog(
          title: Row(
            children: [
              Expanded(child: Text(t('title'))),
              IconButton(
                tooltip: t('close'),
                onPressed: u.installing ? null : () => Navigator.pop(context),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
          content: SizedBox(
            width: 600,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('${t('installed')}  ${u.currentVersion}'),
                  const SizedBox(height: 20),
                  Text(
                    t(u.stage == UpdateStage.idle ? 'check' : u.stage.name),
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  if (u.stage == UpdateStage.downloading) ...[
                    const SizedBox(height: 16),
                    LinearProgressIndicator(value: u.progress / 100),
                    Text('${u.progress}%'),
                  ],
                  if (u.stage == UpdateStage.ready) ...[
                    const SizedBox(height: 12),
                    Text(u.nextVersion),
                    if (u.notes.isNotEmpty) Text(u.notes),
                  ],
                  const SizedBox(height: 20),
                  Text(t('help')),
                  if (u.stage == UpdateStage.ready) ...[
                    const SizedBox(height: 20),
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      value: safe,
                      controlAffinity: ListTileControlAffinity.leading,
                      title: Text(t('safe')),
                      onChanged: u.installing
                          ? null
                          : (value) => setState(() => safe = value ?? false),
                    ),
                  ],
                  if (notice != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 16),
                      child: Text(t(notice!)),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            OutlinedButton(
              onPressed: u.busy || u.stage == UpdateStage.unavailable
                  ? null
                  : () => u.check(force: true),
              child: Text(t('check')),
            ),
            FilledButton(
              onPressed: !safe || u.busy || u.stage != UpdateStage.ready
                  ? null
                  : () async {
                      final result = await u.install();
                      if (mounted) {
                        setState(() {
                          notice = result;
                          safe = false;
                        });
                      }
                    },
              child: Text(t('install')),
            ),
          ],
        ),
      );
    },
  );
}
