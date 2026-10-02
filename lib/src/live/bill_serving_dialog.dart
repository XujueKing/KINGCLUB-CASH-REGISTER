import 'package:flutter/material.dart';

import '../auth/staff_auth_controller.dart';
import '../strings.dart';
import 'live_serving_recovery_panel.dart';
import 'order_snapshot.dart';

/// Records actual delivery through the existing durable serving command journal.
class BillServingDialog extends StatefulWidget {
  const BillServingDialog({
    super.key,
    required this.auth,
    required this.language,
    required this.tableRef,
    required this.sessionRef,
    required this.order,
    required this.item,
    required this.isCurrent,
    this.recall = false,
  });
  final StaffAuthController auth;
  final UiLanguage language;
  final String tableRef, sessionRef;
  final LiveOrder order;
  final OrderItem item;
  final bool Function() isCurrent;
  final bool recall;
  @override
  State<BillServingDialog> createState() => _BillServingDialogState();
}

class _BillServingDialogState extends State<BillServingDialog> {
  final quantity = TextEditingController(text: '1');
  bool busy = false, recovery = false, failed = false;
  String t(String key) => tr(widget.language, key);
  int? get count {
    final value = int.tryParse(quantity.text);
    return RegExp(r'^[1-9][0-9]{0,3}$').hasMatch(quantity.text) &&
            value != null &&
            value <=
                ((widget.recall
                        ? widget.item.servedQuantity
                        : widget.item.remainingQuantity) ??
                    0)
        ? value
        : null;
  }

  @override
  void dispose() {
    quantity.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    if (busy || recovery || count == null) return;
    if (!widget.isCurrent()) {
      Navigator.of(context).pop();
      return;
    }
    final delivered = count!;
    setState(() {
      busy = true;
      failed = false;
    });
    var attempted = false;
    try {
      final pending = await widget.auth.pendingServing();
      if (!mounted) return;
      if (!widget.isCurrent()) {
        Navigator.of(context).pop();
        return;
      }
      if (pending.any(
        (p) =>
            p.orderRef == widget.order.reference &&
            p.productRef == widget.item.productRef,
      )) {
        setState(() => recovery = true);
        return;
      }
      attempted = true;
      final result = await widget.auth.confirmServing(
        tableRef: widget.tableRef,
        sessionRef: widget.sessionRef,
        orderRef: widget.order.reference,
        productRef: widget.item.productRef,
        quantity: widget.item.activeQuantity,
        expectedServedQuantity: widget.item.servedQuantity!,
        targetServedQuantity:
            widget.item.servedQuantity! +
            (widget.recall ? -delivered : delivered),
        expectedServingEpoch: widget.item.servingEpoch,
        confirmed: true,
      );
      if (!mounted) return;
      if (result.confirmed) {
        Navigator.of(context).pop();
      } else {
        setState(() => recovery = true);
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          recovery = attempted;
          failed = !attempted;
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: recovery
        ? Dialog(
            child: SizedBox(
              width: 720,
              height: 500,
              child: LiveServingRecoveryPanel(
                auth: widget.auth,
                language: widget.language,
                onBack: () => Navigator.of(context).pop(),
              ),
            ),
          )
        : AlertDialog(
            title: Text(t(widget.recall ? 'billRecallWait' : 'servingConfirm')),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(widget.item.name(widget.language)),
                  Text(
                    '${t('servingDelivered')}: ${widget.item.servedQuantity} · ${t('servingRemaining')}: ${widget.item.remainingQuantity}',
                  ),
                  Text(
                    t(
                      widget.recall
                          ? 'billRecallWaitNotice'
                          : 'servingConfirmNotice',
                    ),
                  ),
                  if (failed) Text(t('liveReadFailed')),
                  TextField(
                    key: const ValueKey('bill-serving-quantity'),
                    controller: quantity,
                    enabled: !busy,
                    keyboardType: TextInputType.number,
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      labelText: t(
                        widget.recall
                            ? 'billRecallQuantity'
                            : 'servingThisQuantity',
                      ),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: busy ? null : () => Navigator.of(context).pop(),
                child: Text(t('cashPrepareCancel')),
              ),
              FilledButton(
                key: const ValueKey('bill-serving-submit'),
                onPressed: busy || count == null ? null : submit,
                child: Text(
                  t(widget.recall ? 'billRecallWait' : 'servingConfirm'),
                ),
              ),
            ],
          ),
  );
}
