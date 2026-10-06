import 'dart:math';

import 'package:flutter/material.dart';

import '../auth/staff_auth_controller.dart';
import '../strings.dart';
import 'order_snapshot.dart';
import 'table_snapshot.dart';
import 'touch_quantity.dart';
import 'provider_refund_journal.dart';

class ProviderRefundDialog extends StatefulWidget {
  const ProviderRefundDialog({
    super.key,
    required this.auth,
    required this.order,
    required this.item,
    required this.served,
    required this.language,
    required this.isCurrent,
  });
  final StaffAuthController auth;
  final LiveOrder order;
  final OrderItem item;
  final bool served;
  final UiLanguage language;
  final bool Function() isCurrent;
  @override
  State<ProviderRefundDialog> createState() => _ProviderRefundDialogState();
}

class _ProviderRefundDialogState extends State<ProviderRefundDialog> {
  late final identity = widget.auth.session!;
  late final journal = ProviderRefundJournal(identity, widget.order.reference);
  final quantity = TextEditingController(text: '1'),
      returned = TextEditingController(text: '1');
  Map<String, dynamic>? data, pending;
  String? originalEmployee, state, message;
  bool busy = true, returnStock = false;
  int reason = 0;
  String l(String zh, String en, String tw, String th) =>
      [zh, en, tw, th][widget.language.index];
  bool get current =>
      widget.isCurrent() && identical(identity, widget.auth.session);
  int n(String key) => data?[key] as int? ?? 0;
  int get maximum => widget.served
      ? n('servedQuantity') - n('storedQuantity')
      : n('availableQuantity') - n('servedQuantity');
  int get count => int.tryParse(quantity.text) ?? 0;
  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    quantity.dispose();
    returned.dispose();
    super.dispose();
  }

  Future<void> load() async {
    try {
      final saved = await journal.read();
      if (!mounted || !current) return;
      if (saved != null) {
        pending = Map<String, dynamic>.from(saved['command'] as Map);
        originalEmployee = saved['employeeRef'] as String;
        await query();
        return;
      }
      final value = await widget.auth.providerItemRefund({
        'action': 'context',
        'orderRef': widget.order.reference,
        'productRef': widget.item.productRef,
      });
      if (!mounted || !current) return;
      for (final key in [
        'unitPriceCents',
        'availableQuantity',
        'servedQuantity',
        'storedQuantity',
        'refundedQuantity',
        'servingEpoch',
      ]) {
        if (value[key] is! int || (value[key] as int) < 0)
          throw const FormatException();
      }
      if (value['servedQuantity'] > value['availableQuantity'] ||
          value['storedQuantity'] > value['servedQuantity'] ||
          value['availableQuantity'] > 1000 ||
          value['unitPriceCents'] <= 0)
        throw const FormatException();
      data = value;
      if (value['pendingRef'] != null) {
        if (value['pendingProductRef'] is! String)
          throw const FormatException();
        pending = {
          'action': 'query',
          'orderRef': widget.order.reference,
          'productRef': value['pendingProductRef'],
          'requestId': value['pendingRef'],
        };
        await query();
        return;
      }
      quantity.text = '${maximum > 0 ? maximum : 1}';
      returned.text = quantity.text;
      if (value['enabled'] != true)
        message = l(
          '原路退款暂未开放',
          'Refunds are not enabled',
          '原路退款暫未開放',
          'ยังไม่เปิดการคืนเงิน',
        );
    } catch (_) {
      if (mounted)
        message = l(
          '暂时无法读取，请重试',
          'Unable to read. Retry.',
          '暫時無法讀取，請重試',
          'อ่านไม่ได้ กรุณาลองใหม่',
        );
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> query() async => send(false);
  Future<void> send(bool submit) async {
    if (!current || pending == null) return;
    setState(() {
      busy = true;
      message = null;
    });
    try {
      final command = pending!;
      final result = await widget.auth.providerItemRefund(
        submit
            ? command
            : {
                'action': 'query',
                'orderRef': command['orderRef'],
                'productRef': command['productRef'],
                'requestId': command['requestId'],
              },
      );
      if (!mounted || !current) return;
      if (result['refundRef'] != command['requestId'] ||
          !['pending', 'review', 'refunded'].contains(result['state']) ||
          result['totalCents'] is! int ||
          result['quantity'] is! int ||
          result['stockReturnQuantity'] is! int ||
          (result['totalCents'] as int) <= 0 ||
          (result['quantity'] as int) <= 0 ||
          (command.containsKey('expectedRefundCents') &&
              (result['totalCents'] != command['expectedRefundCents'] ||
                  result['quantity'] != command['quantity'] ||
                  result['stockReturnQuantity'] !=
                      command['stockReturnQuantity'])))
        throw const FormatException();
      state = result['state'] as String;
      if (state == 'refunded') {
        await journal.acknowledge(command['requestId'] as String);
        if (mounted && current) Navigator.pop(context, true);
      }
    } catch (_) {
      if (mounted)
        message = l(
          '暂未确认结果，请查询原退款',
          'Check the original refund result',
          '暫未確認結果，請查詢原退款',
          'โปรดตรวจสอบผลการคืนเงินเดิม',
        );
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> submit() async {
    if (busy ||
        !current ||
        pending != null ||
        data?['enabled'] != true ||
        count < 1 ||
        count > maximum)
      return;
    setState(() => busy = true);
    try {
      final bytes = List<int>.generate(16, (_) => Random.secure().nextInt(256));
      bytes[6] = (bytes[6] & 15) | 64;
      bytes[8] = (bytes[8] & 63) | 128;
      final hex = bytes.map((n) => n.toRadixString(16).padLeft(2, '0')).join();
      final id =
          '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
      final command = <String, dynamic>{
        'action': 'refund',
        'orderRef': widget.order.reference,
        'productRef': widget.item.productRef,
        'requestId': id,
        'quantity': count,
        'servedQuantity': widget.served ? count : 0,
        'stockReturnQuantity': returnStock ? int.parse(returned.text) : 0,
        'physicalReturnConfirmed': returnStock,
        'reason': ['顾客退货', '缺货', '破损', '上错商品'][reason],
        'expectedRefundCents': count * n('unitPriceCents'),
        'expectedServingEpoch': n('servingEpoch'),
        'expectedRefundedQuantity': n('refundedQuantity'),
      };
      await journal.save(command);
      pending = command;
      originalEmployee = identity.employeeRef;
      if (mounted && current) await send(true);
    } catch (_) {
      if (mounted)
        message = l(
          '未完成，请重新打开查看原退款',
          'Reopen to check the original refund',
          '未完成，請重新開啟查看原退款',
          'เปิดอีกครั้งเพื่อตรวจสอบการคืนเงินเดิม',
        );
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: AlertDialog(
      title: Row(
        children: [
          Expanded(
            child: Text(l('商品退款', 'Item refund', '商品退款', 'คืนเงินสินค้า')),
          ),
          IconButton(
            onPressed: busy ? null : () => Navigator.pop(context),
            icon: const Icon(Icons.close),
          ),
        ],
      ),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                widget.item.name(widget.language),
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 16),
              if (pending != null)
                Text(
                  state == 'review'
                      ? l(
                          '退款需核对，请查询原退款',
                          'Refund needs review',
                          '退款需核對，請查詢原退款',
                          'โปรดตรวจสอบการคืนเงิน',
                        )
                      : l(
                          '退款处理中',
                          'Refund processing',
                          '退款處理中',
                          'กำลังคืนเงิน',
                        ),
                )
              else if (data != null) ...[
                TouchQuantity(
                  controller: quantity,
                  maximum: maximum,
                  label: l('退款数量', 'Quantity', '退款數量', 'จำนวน'),
                  enabled: !busy,
                  onChanged: () {
                    if (int.parse(returned.text) > count)
                      returned.text = '$count';
                    setState(() {});
                  },
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (var i = 0; i < 4; i++)
                      ChoiceChip(
                        label: Text(
                          [
                            l('顾客退货', 'Return', '顧客退貨', 'ลูกค้าคืนสินค้า'),
                            l('缺货', 'Unavailable', '缺貨', 'สินค้าหมด'),
                            l('破损', 'Damaged', '破損', 'ชำรุด'),
                            l('上错商品', 'Wrong item', '上錯商品', 'เสิร์ฟผิด'),
                          ][i],
                        ),
                        selected: reason == i,
                        onSelected: busy
                            ? null
                            : (_) => setState(() => reason = i),
                      ),
                  ],
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 8,
                  children: [
                    ChoiceChip(
                      label: Text(
                        l('仅退款', 'Refund only', '僅退款', 'คืนเงินเท่านั้น'),
                      ),
                      selected: !returnStock,
                      onSelected: busy
                          ? null
                          : (_) => setState(() => returnStock = false),
                    ),
                    ChoiceChip(
                      label: Text(
                        l(
                          '完好实物退库',
                          'Return intact goods',
                          '完好實物退庫',
                          'คืนสินค้าเข้าสต็อก',
                        ),
                      ),
                      selected: returnStock,
                      onSelected: busy
                          ? null
                          : (_) => setState(() => returnStock = true),
                    ),
                  ],
                ),
                if (returnStock) ...[
                  const SizedBox(height: 12),
                  Text(
                    l(
                      '请确认以下数量已完好收回',
                      'Confirm intact goods received',
                      '請確認以下數量已完好收回',
                      'ยืนยันว่าได้รับสินค้าสภาพสมบูรณ์',
                    ),
                  ),
                  TouchQuantity(
                    controller: returned,
                    maximum: count,
                    label: l('退库数量', 'Return quantity', '退庫數量', 'จำนวนคืน'),
                    enabled: !busy,
                    onChanged: () => setState(() {}),
                  ),
                ],
                const SizedBox(height: 18),
                Text(
                  '${l('原路退回', 'Original payment refund', '原路退回', 'คืนผ่านช่องทางเดิม')}  ¥ ${formatCents(count * n('unitPriceCents'))}',
                  style: const TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
              if (message != null)
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: Text(message!),
                ),
              if (busy)
                const Padding(
                  padding: EdgeInsets.only(top: 16),
                  child: LinearProgressIndicator(),
                ),
            ],
          ),
        ),
      ),
      actions: [
        if (pending != null) ...[
          if (state != 'review' &&
              originalEmployee == identity.employeeRef &&
              pending!['action'] == 'refund')
            TextButton(
              onPressed: busy ? null : () => send(true),
              child: Text(
                l('重试原退款', 'Retry original', '重試原退款', 'ลองรายการเดิมอีกครั้ง'),
              ),
            ),
          FilledButton(
            onPressed: busy ? null : query,
            child: Text(l('查询退款结果', 'Check refund', '查詢退款結果', 'ตรวจสอบผล')),
          ),
        ] else
          FilledButton(
            onPressed: busy || data?['enabled'] != true || maximum < 1
                ? null
                : submit,
            child: Text(l('确认退款', 'Confirm refund', '確認退款', 'ยืนยันคืนเงิน')),
          ),
      ],
    ),
  );
}
