import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import 'dart:math';

import '../auth/staff_auth_controller.dart';
import '../auth/staff_session.dart';
import '../network/cashier_realtime_client.dart';
import '../hardware/scanner_input.dart';
import '../strings.dart';
import 'member_identity.dart';
import 'store_member_copy.dart';
import 'recharge_touch_dialog.dart';

class StoreMembersPanel extends StatefulWidget {
  const StoreMembersPanel({
    super.key,
    required this.auth,
    required this.language,
    this.enableRealtime = const bool.fromEnvironment('CASHIER_REALTIME'),
    this.realtimeFactory,
  });
  final StaffAuthController auth;
  final UiLanguage language;
  final bool enableRealtime;
  final CashierRealtimeClient Function(StaffSession)? realtimeFactory;
  @override
  State<StoreMembersPanel> createState() => _StoreMembersPanelState();
}

class _StoreMembersPanelState extends State<StoreMembersPanel>
    with WidgetsBindingObserver {
  List<Map<String, dynamic>> members = [];
  Map<String, dynamic>? detail;
  String? next, notice;
  bool busy = false, foreground = true;
  int epoch = 0;
  int listEpoch = 0, socketRevision = -1;
  String? selectedAccount;
  StaffSession? session;
  CashierRealtimeClient? socket;
  Timer? fallback, refreshDelay;
  StreamSubscription<String>? scans;
  String w(String zh, String en) => memberCopy(widget.language, zh, en);
  String newRequestId() {
    final r = Random.secure();
    final b = List<int>.generate(16, (_) => r.nextInt(256));
    b[6] = (b[6] & 15) | 64;
    b[8] = (b[8] & 63) | 128;
    final h = b.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
  }

  String money(Object? v) => (int.parse('${v ?? 0}') / 100).toStringAsFixed(2);
  String? get account => selectedAccount;
  String memberNumber(Map member) => member['memberId'] as String? ?? '';
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.auth.addListener(changed);
    scans = ScannerInput.codes.listen((code) {
      if (mounted &&
          foreground &&
          !busy &&
          ModalRoute.of(context)?.isCurrent == true &&
          MemberIdentity.codePattern.hasMatch(code))
        unawaited(link(code));
    });
    session = widget.auth.session;
    syncSocket();
    fallback = Timer.periodic(const Duration(seconds: 30), (_) {
      if (foreground && socket?.state != CashierRealtimeState.connected) {
        unawaited(load());
      }
    });
    unawaited(load());
  }

  void changed() {
    if (widget.auth.busy) return;
    if (identical(session, widget.auth.session)) return;
    final previous = session;
    session = widget.auth.session;
    epoch++;
    listEpoch++;
    syncSocket();
    if (session == null ||
        previous?.storeRef != session?.storeRef ||
        previous?.employeeRef != session?.employeeRef ||
        previous?.base != session?.base) {
      setState(() {
        members = [];
        detail = null;
        selectedAccount = null;
      });
    }
    if (session == null) return;
    unawaited(load());
    if (account != null) unawaited(select(account!, background: true));
  }

  void syncSocket() {
    socket?.removeListener(realtimeChanged);
    socket?.dispose();
    socket = null;
    socketRevision = -1;
    if (!widget.enableRealtime || session == null) return;
    socket =
        widget.realtimeFactory?.call(session!) ??
        CashierRealtimeClient(session!);
    socket!.addListener(realtimeChanged);
    socket!.start();
  }

  void realtimeChanged() {
    if (!mounted ||
        !foreground ||
        socket?.state != CashierRealtimeState.connected ||
        socketRevision == socket!.revision)
      return;
    socketRevision = socket!.revision;
    if (socket!.lastTopic != null && socket!.lastTopic != 'members') return;
    refreshDelay?.cancel();
    refreshDelay = Timer(const Duration(milliseconds: 150), () {
      unawaited(load());
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    if (!foreground) {
      epoch++;
      listEpoch++;
      socket?.stop();
    } else {
      socket?.start();
      unawaited(load());
      if (account != null) unawaited(select(account!, background: true));
    }
  }

  @override
  void dispose() {
    epoch++;
    listEpoch++;
    fallback?.cancel();
    refreshDelay?.cancel();
    socket?.dispose();
    scans?.cancel();
    widget.auth.removeListener(changed);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> load({bool more = false}) async {
    final ticket = ++listEpoch;
    try {
      final r = await widget.auth.storeMembers({
        'action': 'list',
        if (more && next != null) 'after': next,
      });
      if (!mounted || ticket != listEpoch) return;
      setState(() {
        members = [
          if (more) ...members,
          ...(r['members'] as List).map((e) => Map<String, dynamic>.from(e)),
        ];
        next = r['nextAfter'] as String?;
      });
    } catch (_) {
      if (mounted && ticket == listEpoch)
        setState(
          () => notice = w('会员列表暂未加载，请重试', 'Could not load members. Retry.'),
        );
    }
  }

  Future<void> select(String user, {bool background = false}) async {
    final ticket = ++epoch;
    setState(() {
      selectedAccount = user;
      notice = null;
      if (!background || detail?['member']?['userAccount'] != user)
        detail = null;
    });
    try {
      final r = await widget.auth.storeMembers({
        'action': 'detail',
        'targetAccount': user,
      });
      if (r['member']?['userAccount'] != user)
        throw const FormatException('Member mismatch');
      if (mounted && ticket == epoch)
        setState(() {
          detail = r;
          selectedAccount = r['member']['userAccount'] as String;
          notice = null;
        });
    } catch (_) {
      if (mounted && ticket == epoch)
        setState(() => notice = w('会员资料暂不可用', 'Member details unavailable'));
    }
  }

  Future<void> link(String code) async {
    setState(() => busy = true);
    final ticket = ++epoch;
    try {
      final r = await widget.auth.storeMembers({
        'action': 'link',
        'identityCode': code,
      });
      if (mounted && ticket == epoch) {
        setState(() {
          detail = r;
          selectedAccount = r['member']['userAccount'] as String;
          notice = w('已加入本店会员', 'Added to this store');
        });
        await load();
      }
    } catch (_) {
      if (mounted)
        setState(
          () => notice = w(
            '会员码无效，请顾客刷新后重扫',
            'Refresh the member code and scan again',
          ),
        );
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Widget avatar(Map m, {double radius = 24}) {
    ImageProvider? image;
    try {
      if (m['avatarBase64'] != null)
        image = MemoryImage(base64Decode(m['avatarBase64']));
    } catch (_) {}
    return CircleAvatar(
      radius: radius,
      backgroundImage: image,
      child: image == null ? const Icon(Icons.person_outline) : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final d = detail, m = d?['member'] as Map?, b = d?['balance'] as Map?;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: 300,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        w('本店会员', 'Store members'),
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Text(
                  w(
                    '顾客出示会员码，扫码自动加入本店',
                    'Scan a member code to add to this store',
                  ),
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ),
              Expanded(
                child: ListView(
                  children: [
                    for (final member in members)
                      ListTile(
                        key: ValueKey('store-member-${member['userAccount']}'),
                        selected: member['userAccount'] == account,
                        leading: avatar(member),
                        title: Text(
                          member['nickname'] ?? member['userAccount'],
                        ),
                        subtitle: Text(memberNumber(member)),
                        onTap: busy
                            ? null
                            : () => select(member['userAccount']),
                      ),
                    if (members.isEmpty)
                      Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          w('暂无收藏会员，直接扫码添加', 'No members yet. Scan to add.'),
                        ),
                      ),
                    if (next != null)
                      TextButton(
                        onPressed: () => load(more: true),
                        child: Text(w('更多', 'More')),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const VerticalDivider(width: 1),
        Expanded(
          child: d == null
              ? Align(
                  alignment: Alignment.topCenter,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.qr_code_scanner, size: 64),
                      const SizedBox(height: 16),
                      Text(
                        notice ??
                            w(
                              '选择会员，或直接扫描会员码',
                              'Select a member or scan their code',
                            ),
                      ),
                    ],
                  ),
                )
              : SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          avatar(m!, radius: 38),
                          const SizedBox(width: 16),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                m['nickname'] ?? m['userAccount'],
                                style: const TextStyle(
                                  fontSize: 26,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              Text(memberNumber(m)),
                              Text(
                                w('手机号：', 'Phone: ') +
                                    (m['phone'] ?? w('未提供', 'Not provided')),
                              ),
                            ],
                          ),
                        ],
                      ),
                      const SizedBox(height: 24),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(28),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(18),
                          gradient: const LinearGradient(
                            colors: [Color(0xff163e33), Color(0xff3d6654)],
                          ),
                        ),
                        child: DefaultTextStyle(
                          style: const TextStyle(color: Color(0xffeee0b8)),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${d['storeName']} · ${w('会员储值卡', 'Member card')}',
                                style: const TextStyle(fontSize: 18),
                              ),
                              const SizedBox(height: 20),
                              Text(
                                '¥ ${money((b!['principalCents'] as num) + (b['giftCents'] as num))}',
                                style: const TextStyle(
                                  fontSize: 38,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                '${w('本金', 'Principal')} ¥${money(b['principalCents'])}    ${w('赠送', 'Gift')} ¥${money(b['giftCents'])}',
                              ),
                              if (b['status'] == 'frozen')
                                Text(
                                  w(
                                    '退款处理中，余额暂不可使用',
                                    'Refund pending; balance temporarily frozen',
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),
                      Wrap(
                        spacing: 12,
                        children: [
                          FilledButton.icon(
                            onPressed: busy || b['status'] == 'frozen'
                                ? null
                                : recharge,
                            icon: const Icon(Icons.add_card),
                            label: Text(w('充值', 'Recharge')),
                          ),
                          OutlinedButton.icon(
                            onPressed: null,
                            icon: const Icon(Icons.undo),
                            label: Text(w('退款', 'Refund')),
                          ),
                          if (widget.auth.session?.permissions.contains(
                                'price.adjust',
                              ) ==
                              true)
                            OutlinedButton(
                              onPressed: campaigns,
                              child: Text(w('充值设置', 'Recharge settings')),
                            ),
                        ],
                      ),
                      if (notice != null)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          child: Text(notice!),
                        ),
                      const SizedBox(height: 16),
                      Text(
                        w('充值记录', 'Recharge history'),
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      for (final row in d['history'] as List)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(
                            '${w('充值', 'Recharge')} ¥${money(row['principalCents'])}  /  ${w('赠送', 'Gift')} ¥${money(row['giftCents'])}',
                          ),
                          subtitle: Text(
                            '${row['createdDate']} · ${row['refundStatus'] == 'refunded'
                                ? w('已退款', 'Refunded')
                                : row['refundStatus'] == 'pending'
                                ? w('退款处理中', 'Refund pending')
                                : row['creditStatus'] == 'credited'
                                ? w('已到账', 'Credited')
                                : w('待付款／到账', 'Awaiting payment / credit')}',
                          ),
                          trailing: row['refundStatus'] == 'pending'
                              ? TextButton(
                                  onPressed: () => refund(
                                    row: Map<String, dynamic>.from(row),
                                    recover: true,
                                  ),
                                  child: Text(w('查询退款', 'Check refund')),
                                )
                              : row['creditStatus'] == 'credited' &&
                                    row['refundStatus'] == 'none'
                              ? TextButton(
                                  onPressed: null,
                                  child: Text(w('退款', 'Refund')),
                                )
                              : row['creditStatus'] != 'credited'
                              ? TextButton(
                                  onPressed: () =>
                                      payment(Map<String, dynamic>.from(row)),
                                  child: Text(w('收款／查询', 'Pay / check')),
                                )
                              : null,
                        ),
                    ],
                  ),
                ),
        ),
      ],
    );
  }

  Future<void> campaigns() async {
    final offers = (detail!['campaigns'] as List)
        .where((c) => c['enabled'] == true)
        .toList();
    final chosen = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => Dialog(
        child: SizedBox(
          width: 900,
          height: 610,
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        w('充值设置', 'Recharge settings'),
                        style: const TextStyle(
                          fontSize: 26,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.pop(ctx),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                Expanded(
                  child: GridView.builder(
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 3,
                          mainAxisExtent: 150,
                          mainAxisSpacing: 16,
                          crossAxisSpacing: 16,
                        ),
                    itemCount: offers.length,
                    itemBuilder: (_, i) {
                      final c = Map<String, dynamic>.from(offers[i]);
                      return OutlinedButton(
                        onPressed: () => Navigator.pop(ctx, c),
                        style: OutlinedButton.styleFrom(
                          backgroundColor: const Color(0xffedf2ef),
                          padding: const EdgeInsets.all(20),
                          side: const BorderSide(color: Color(0xffcbd4cf)),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            const Align(
                              alignment: Alignment.centerRight,
                              child: Icon(Icons.edit_outlined, size: 20),
                            ),
                            const Spacer(),
                            FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: Alignment.centerLeft,
                              child: Text(
                                '${w('充', 'Pay')} ¥ ${money(c['principalCents'])}',
                                style: const TextStyle(
                                  fontSize: 26,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                            const SizedBox(height: 10),
                            Text(
                              '${w('送', 'Gift')} ¥ ${money(c['giftCents'])}',
                              style: const TextStyle(
                                fontSize: 19,
                                color: Color(0xff99701e),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 24),
                SizedBox(
                  height: 60,
                  child: FilledButton.icon(
                    onPressed: () => Navigator.pop(ctx, <String, dynamic>{}),
                    icon: const Icon(Icons.add),
                    label: Text(
                      w('新增档位', 'New offer'),
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (!mounted || chosen == null) return;
    await editCampaign(chosen.isEmpty ? null : chosen);
  }

  Future<void> editCampaign(Map<String, dynamic>? old) async {
    final values = [
      old == null ? '0' : money(old['principalCents']),
      old == null ? '0' : money(old['giftCents']),
    ];
    var field = 0;
    final replace = [true, true];
    bool saving = false;
    String? error;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) {
          void digit(String key) => set(() {
            error = null;
            if (key == 'C') {
              values[field] = '0';
              replace[field] = true;
              return;
            }
            if (key == 'back') {
              values[field] = values[field].length > 1
                  ? values[field].substring(0, values[field].length - 1)
                  : '0';
              replace[field] = false;
              return;
            }
            if (replace[field]) {
              values[field] = '0';
              replace[field] = false;
            }
            if (key == '.') {
              if (!values[field].contains('.')) values[field] += '.';
              return;
            }
            if (values[field].contains('.') &&
                values[field].split('.').last.length >= 2)
              return;
            if (values[field].replaceAll('.', '').length >= 9) return;
            values[field] = values[field] == '0' ? key : values[field] + key;
          });
          return PopScope(
            canPop: !saving,
            child: Dialog(
              child: SizedBox(
                width: 900,
                height: 610,
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              w('充多少，送多少', 'Recharge and gift'),
                              style: const TextStyle(
                                fontSize: 26,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          IconButton(
                            onPressed: saving ? null : () => Navigator.pop(ctx),
                            icon: const Icon(Icons.close),
                          ),
                        ],
                      ),
                      const SizedBox(height: 24),
                      Expanded(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  for (var i = 0; i < 2; i++) ...[
                                    if (i > 0) const SizedBox(height: 20),
                                    SizedBox(
                                      height: 142,
                                      child: OutlinedButton(
                                        onPressed: saving
                                            ? null
                                            : () => set(() {
                                                field = i;
                                                replace[i] = true;
                                              }),
                                        style: OutlinedButton.styleFrom(
                                          alignment: Alignment.centerLeft,
                                          padding: const EdgeInsets.all(20),
                                          backgroundColor: field == i
                                              ? const Color(0xfffff2cc)
                                              : const Color(0xffedf2ef),
                                          side: BorderSide(
                                            color: field == i
                                                ? const Color(0xffc59c39)
                                                : const Color(0xffcbd4cf),
                                            width: field == i ? 2 : 1,
                                          ),
                                          shape: RoundedRectangleBorder(
                                            borderRadius: BorderRadius.circular(
                                              12,
                                            ),
                                          ),
                                        ),
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          mainAxisAlignment:
                                              MainAxisAlignment.center,
                                          children: [
                                            Text(
                                              i == 0
                                                  ? w('充值', 'Recharge')
                                                  : w('赠送', 'Gift'),
                                              style: const TextStyle(
                                                fontSize: 19,
                                              ),
                                            ),
                                            const SizedBox(height: 12),
                                            FittedBox(
                                              fit: BoxFit.scaleDown,
                                              child: Text(
                                                '¥ ${values[i]}',
                                                style: const TextStyle(
                                                  fontSize: 38,
                                                  fontWeight: FontWeight.bold,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ],
                                  if (error != null)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 16),
                                      child: Text(
                                        error!,
                                        style: TextStyle(
                                          color: Theme.of(ctx)
                                              .colorScheme
                                              .error,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 24),
                            SizedBox(
                              width: 330,
                              child: Column(
                                children: [
                                  Expanded(
                                    child: GridView.count(
                                      physics:
                                          const NeverScrollableScrollPhysics(),
                                      crossAxisCount: 3,
                                      mainAxisSpacing: 10,
                                      crossAxisSpacing: 10,
                                      childAspectRatio: 1.35,
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
                                          '.',
                                          '0',
                                          'back',
                                        ])
                                          OutlinedButton(
                                            onPressed: saving
                                                ? null
                                                : () => digit(key),
                                            style: OutlinedButton.styleFrom(
                                              backgroundColor: Colors.white,
                                              side: const BorderSide(
                                                color: Color(0xffd4dbd6),
                                              ),
                                              shape: RoundedRectangleBorder(
                                                borderRadius:
                                                    BorderRadius.circular(12),
                                              ),
                                            ),
                                            child: key == 'back'
                                                ? const Icon(
                                                    Icons.backspace_outlined,
                                                    size: 27,
                                                  )
                                                : Text(
                                                    key,
                                                    style: const TextStyle(
                                                      fontSize: 30,
                                                      fontWeight:
                                                          FontWeight.w600,
                                                    ),
                                                  ),
                                          ),
                                      ],
                                    ),
                                  ),
                                  TextButton(
                                    onPressed: saving ? null : () => digit('C'),
                                    child: Text(
                                      rechargeText(
                                        widget.language,
                                        '清空金额',
                                        'Clear amount',
                                        '清空金額',
                                        'ล้างยอดเงิน',
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 24),
                      SizedBox(
                        height: 60,
                        child: FilledButton(
                          onPressed: saving
                              ? null
                              : () async {
                                  final p = double.tryParse(values[0]),
                                      g = double.tryParse(values[1]);
                                  if (p == null ||
                                      p <= 0 ||
                                      p > 1000000 ||
                                      g == null ||
                                      g < 0 ||
                                      g > 1000000) {
                                    set(
                                      () => error = w(
                                        '请输入有效金额',
                                        'Enter a valid amount',
                                      ),
                                    );
                                    return;
                                  }
                                  set(() => saving = true);
                                  try {
                                    await widget.auth.storeMembers({
                                      'action': 'campaignSave',
                                      'campaign': {
                                        if (old != null)
                                          'campaignRef': old['campaignRef'],
                                        'revision': old?['revision'] ?? 0,
                                        'principalCents': (p * 100).round(),
                                        'giftCents': (g * 100).round(),
                                        'enabled': true,
                                      },
                                    });
                                    if (ctx.mounted) Navigator.pop(ctx);
                                  } catch (_) {
                                    if (ctx.mounted)
                                      set(() {
                                        error = w(
                                          '保存失败，请重试',
                                          'Could not save. Retry.',
                                        );
                                        saving = false;
                                      });
                                  }
                                },
                          child: Text(
                            w('保存', 'Save'),
                            style: const TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
    if (mounted && account != null) await select(account!, background: true);
  }

  Future<void> recharge() async {
    if (busy || account == null) return;
    final owner = account!;
    setState(() => busy = true);
    try {
      await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => RechargeTouchDialog(
          auth: widget.auth,
          language: widget.language,
          member: Map<String, dynamic>.from(detail!['member']),
          campaigns: (detail!['campaigns'] as List)
              .where((c) => c['enabled'] == true)
              .map((c) => Map<String, dynamic>.from(c))
              .toList(),
          newRequestId: newRequestId,
        ),
      );
      if (mounted) await select(owner, background: true);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> payment(Map<String, dynamic> row) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => RechargeScanDialog(
        auth: widget.auth,
        row: row,
        language: widget.language,
      ),
    );
    if (mounted && account != null) await select(account!);
  }

  Future<void> refund({Map<String, dynamic>? row, bool recover = false}) async {
    row ??= await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(w('选择充值记录', 'Select recharge')),
        children: [
          for (final r in detail!['history'] as List)
            if (r['creditStatus'] == 'credited' &&
                r['refundStatus'] != 'refunded')
              SimpleDialogOption(
                onPressed: () =>
                    Navigator.pop(ctx, Map<String, dynamic>.from(r)),
                child: Text(
                  '${r['createdDate']} · ¥${money(r['principalCents'])}',
                ),
              ),
        ],
      ),
    );
    if (row == null || !mounted) return;
    setState(() => busy = true);
    final selected = row;
    try {
      final scope = {
        'targetAccount': account,
        'rechargeRef': selected['rechargeRef'],
      };
      var r = await widget.auth.storeMembers({
        'action': recover ? 'refundQuery' : 'refundQuote',
        ...scope,
      });
      if (!recover && r['state'] == 'quote' && mounted) {
        final q = r['quote'] as Map;
        final yes = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(
              r['channel'] == 'cash'
                  ? rechargeText(
                      widget.language,
                      '退还现金',
                      'Return cash',
                      '退還現金',
                      'คืนเงินสด',
                    )
                  : w('原路退款', 'Refund to original payment'),
            ),
            content: Text(
              '${w('已消费', 'Consumed')} ¥${money(q['consumedCents'])}\n${w('取消赠送', 'Cancel gift')} ¥${money(q['cancelledGiftCents'])}\n${w('可退金额', 'Refund')} ¥${money(q['refundCents'])}',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(w('取消', 'Cancel')),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(
                  r['channel'] == 'cash'
                      ? rechargeText(
                          widget.language,
                          '确认已退现金',
                          'Confirm cash returned',
                          '確認已退現金',
                          'ยืนยันคืนเงินสดแล้ว',
                        )
                      : w('确认退款', 'Confirm refund'),
                ),
              ),
            ],
          ),
        );
        if (yes == true)
          r = await widget.auth.storeMembers({
            'action': 'refund',
            ...scope,
            'requestId': newRequestId(),
            'expectedRefundCents': q['refundCents'],
          });
        else
          return;
      }
      if (mounted) {
        await select(scope['targetAccount'] as String);
        setState(
          () => notice = r['state'] == 'refunded'
              ? w('退款完成，赠送已取消', 'Refund completed; gifts cancelled')
              : w('退款处理中，可在记录中查询', 'Refund pending; check in history'),
        );
      }
    } catch (_) {
      if (mounted)
        setState(
          () => notice = w(
            '退款未完成，请刷新原充值记录核对',
            'Refund not completed; check the original recharge',
          ),
        );
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }
}
