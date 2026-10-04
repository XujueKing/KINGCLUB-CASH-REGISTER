import 'touch_quantity.dart';

import 'package:flutter/material.dart';

import '../auth/staff_auth_controller.dart';
import '../strings.dart';
import 'item_return_recovery.dart';
import 'order_snapshot.dart';

class BillItemReturnDialog extends StatefulWidget {
  const BillItemReturnDialog({
    super.key,
    required this.auth,
    required this.language,
    required this.tableRef,
    required this.sessionRef,
    required this.order,
    required this.item,
    required this.isCurrent,
    this.served = true,
  });
  final StaffAuthController auth;
  final UiLanguage language;
  final String tableRef, sessionRef;
  final LiveOrder order;
  final OrderItem item;
  final bool Function() isCurrent;
  final bool served;
  @override
  State<BillItemReturnDialog> createState() => _BillItemReturnDialogState();
}

class _BillItemReturnDialogState extends State<BillItemReturnDialog> {
  final quantity = TextEditingController();
  int get maximum =>
      (widget.served
          ? widget.item.servedQuantity
          : widget.item.returnableUnservedQuantity) ??
      0;
  @override
  void initState() {
    super.initState();
    quantity.text = '${maximum}';
  }

  bool busy = false, recovery = false, failed = false;
  String t(String key) => tr(widget.language, key);
  int? get count {
    final n = int.tryParse(quantity.text);
    return RegExp(r'^[1-9][0-9]{0,3}$').hasMatch(quantity.text) &&
            n != null &&
            n <=
                (widget.served
                    ? (widget.item.servedQuantity ?? 0)
                    : (widget.item.returnableUnservedQuantity ?? 0))
        ? n
        : null;
  }

  @override
  void dispose() {
    quantity.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    if (busy || count == null || !widget.isCurrent()) return;
    final n = count!;
    setState(() {
      busy = true;
      failed = false;
    });
    try {
      final pending = await widget.auth.pendingItemReturns();
      if (!mounted || !widget.isCurrent()) return;
      if (pending.any(
        (p) =>
            p.orderRef == widget.order.reference &&
            p.productRef == widget.item.productRef,
      )) {
        setState(() => recovery = true);
        return;
      }
      final result = await widget.auth.confirmItemReturn(
        unitPriceCents: widget.item.priceCents,
        fields: {
          'tableRef': widget.tableRef,
          'sessionRef': widget.sessionRef,
          'orderRef': widget.order.reference,
          'productRef': widget.item.productRef,
          'expectedQuantity': widget.item.quantity,
          'expectedServedQuantity': widget.item.servedQuantity,
          'expectedServingEpoch': widget.item.servingEpoch,
          'expectedTotalCents': widget.order.totalCents,
          'quantity': n,
          'returnedServedQuantity': widget.served ? n : 0,
          'physicalReturnConfirmed': true,
        },
      );
      if (!mounted) return;
      if (result.confirmed) {
        Navigator.pop(context);
      } else {
        setState(() => recovery = true);
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          failed = true;
          recovery = true;
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: AlertDialog(
      title: Text(t('billRecallReturn')),
      content: SizedBox(
        width: 500,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(widget.item.name(widget.language)),
              if (recovery)
                ItemReturnRecovery(auth: widget.auth, language: widget.language)
              else ...[
                Text(t('itemReturnNotice')),
                TouchQuantity(
                  controller: quantity,
                  maximum: maximum,
                  label: t('billRecallQuantity'),
                  enabled: !busy,
                  onChanged: () => setState(() {}),
                ),
                if (count != null)
                  Text(
                    '${t('itemReturnDueReduction')} ¥${(count! * widget.item.priceCents / 100).toStringAsFixed(2)}',
                  ),
              ],
              if (failed) Text(t('itemReturnPendingNotice')),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: busy ? null : () => Navigator.pop(context),
          child: Text(t('cashPrepareCancel')),
        ),
        if (!recovery)
          FilledButton(
            key: const ValueKey('item-return-submit'),
            onPressed: busy || count == null ? null : submit,
            child: Text(t('itemReturnConfirm')),
          ),
      ],
    ),
  );
}
