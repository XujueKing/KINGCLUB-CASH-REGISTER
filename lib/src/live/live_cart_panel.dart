import 'dart:async';

import 'package:flutter/material.dart';

import '../auth/staff_auth_controller.dart';
import '../strings.dart';
import 'catalog_snapshot.dart';
import 'cart_draft.dart';
import 'live_catalog_panel.dart';
import 'live_order_recovery_panel.dart';
import 'order_command.dart';
import 'order_context_snapshot.dart';
import 'table_snapshot.dart';

/// Explicit local draft save/restore; submission remains a separately confirmed command.
class LiveCartPanel extends StatefulWidget {
  const LiveCartPanel({
    super.key,
    required this.auth,
    required this.language,
    required this.orderContext,
    required this.memberRef,
    required this.onBack,
    this.revision = 0,
  });
  final StaffAuthController auth;
  final UiLanguage language;
  final OrderContextSnapshot orderContext;
  final String memberRef;
  final VoidCallback onBack;
  final int revision;
  @override
  State<LiveCartPanel> createState() => _LiveCartPanelState();
}

class _LiveCartPanelState extends State<LiveCartPanel>
    with WidgetsBindingObserver {
  final items = <String, OrderSelection>{};
  CartDraft? savedDraft;
  OrderContextSnapshot? restoredContext;
  bool draftLoaded = false, dirty = false;
  BuildContext? activeDialog;
  OrderContextSnapshot get currentContext =>
      restoredContext ?? widget.orderContext;
  bool ready = false,
      busy = false,
      stale = false,
      attempted = false,
      recovery = false;
  int epoch = 0;
  bool confirming = false;
  String? message;
  String t(String key) => tr(widget.language, key);
  String get memberName {
    for (final member in currentContext.members) {
      if (member.reference == widget.memberRef) {
        return member.nickname ?? t('orderMemberUnnamed');
      }
    }
    return t('orderMemberUnnamed');
  }

  bool get draftAction => ready && !busy && !stale && !attempted;
  bool get editable => draftAction && (savedDraft == null || draftLoaded);
  bool get canSubmit =>
      editable && items.isNotEmpty && (savedDraft == null || !dirty);
  int get total => items.values.fold(
    0,
    (sum, item) => sum + item.quantity * item.product.priceCents,
  );

  @override
  void initState() {
    super.initState();
    widget.auth.addListener(invalidate);
    WidgetsBinding.instance.addObserver(this);
    unawaited(checkPending());
  }

  Future<void> checkPending() async {
    final generation = epoch;
    try {
      final pending = await widget.auth.pendingOrders();
      if (!mounted || generation != epoch) return;
      final drafts = await widget.auth.cartDrafts();
      if (!mounted || generation != epoch) return;
      final matches = drafts
          .where(
            (d) =>
                d.tableRef == widget.orderContext.tableRef &&
                d.sessionRef == widget.orderContext.sessionRef &&
                d.memberRef == widget.memberRef,
          )
          .toList();
      setState(() {
        savedDraft = matches.isEmpty ? null : matches.single;
        ready = !pending.any((p) => p.tableRef == widget.orderContext.tableRef);
        if (!ready) message = 'cartPending';
        if (ready && savedDraft != null) message = 'cartDraftFound';
      });
    } catch (_) {
      if (mounted && generation == epoch) {
        setState(() {
          message = 'orderRecoveryFailed';
        });
      }
    }
  }

  void invalidate() {
    ++epoch;
    if (!mounted) return;
    final dialog = activeDialog;
    if (dialog != null &&
        dialog.mounted &&
        ModalRoute.of(dialog)?.isCurrent == true) {
      Navigator.of(dialog).pop();
    }
    setState(() {
      stale = true;
      ready = false;
      items.clear();
      savedDraft = null;
      restoredContext = null;
      message = 'cartStale';
    });
  }

  Future<void> draftOperation(String action) async {
    if (!draftAction) return;
    if (action == 'save' && (!editable || items.isEmpty)) return;
    if (action != 'save' && savedDraft == null) return;
    final generation = epoch, identity = widget.auth.session;
    final original = savedDraft;
    bool current() =>
        mounted &&
        generation == epoch &&
        identical(identity, widget.auth.session);
    setState(() => busy = true);
    try {
      if (action == 'discard') {
        confirming = true;
        final accepted = await showDialog<bool>(
          context: context,
          builder: (ctx) {
            activeDialog = ctx;
            return AlertDialog(
              title: Text(t('cartDraftDiscard')),
              content: Text(t('cartDraftDiscardNotice')),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: Text(t('cancel')),
                ),
                FilledButton(
                  key: const ValueKey('cart-draft-discard-confirm'),
                  onPressed: () => Navigator.pop(ctx, true),
                  child: Text(t('confirm')),
                ),
              ],
            );
          },
        );
        activeDialog = null;
        if (!current() || accepted != true) return;
        await widget.auth.discardCartDraft(original!, confirmed: true);
        if (!current()) return;
        setState(() {
          savedDraft = null;
          draftLoaded = false;
          dirty = false;
          items.clear();
          message = 'cartDraftDiscarded';
        });
      } else if (action == 'restore') {
        final result = await widget.auth.restoreCartDraft(original!);
        if (!current()) return;
        setState(() {
          restoredContext = result.context;
          items
            ..clear()
            ..addEntries(
              result.items.map((i) => MapEntry(i.product.reference, i)),
            );
          draftLoaded = true;
          dirty = false;
          message = 'cartDraftRestored';
        });
      } else {
        final result = await widget.auth.saveCartDraft(
          context: currentContext,
          memberRef: widget.memberRef,
          items: List.unmodifiable(items.values),
          previous: original,
        );
        if (!current()) return;
        setState(() {
          savedDraft = result;
          draftLoaded = true;
          dirty = false;
          message = 'cartDraftSaved';
        });
      }
    } catch (_) {
      if (current()) {
        setState(() {
          // A write may have reached encrypted storage. Reopen to read its actual version.
          if (action != 'restore') ready = false;
          if (action == 'restore') {
            draftLoaded = false;
            items.clear();
            restoredContext = null;
            dirty = false;
          }
          message = 'cartDraftFailed';
        });
      }
    } finally {
      activeDialog = null;
      if (mounted) {
        setState(() {
          busy = false;
          confirming = false;
        });
      }
    }
  }

  @override
  void didUpdateWidget(covariant LiveCartPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.auth, widget.auth)) {
      oldWidget.auth.removeListener(invalidate);
      widget.auth.addListener(invalidate);
    }
    if (!identical(oldWidget.auth, widget.auth) ||
        !identical(oldWidget.orderContext, widget.orderContext) ||
        oldWidget.memberRef != widget.memberRef) {
      invalidate();
    } else if (oldWidget.revision != widget.revision && !attempted) {
      // Once sent, wait for the original response/recovery even if its own
      // notification arrives first. Auth/scope/lifecycle changes still invalidate.
      invalidate();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) invalidate();
  }

  void change(CatalogProduct product, int delta) {
    if (!editable) return;
    final old = items[product.reference];
    final quantity = (old?.quantity ?? 0) + delta;
    if (quantity <= 0) {
      setState(() {
        items.remove(product.reference);
        dirty = true;
        message = null;
      });
      return;
    }
    try {
      if ((old != null &&
              (old.product.revision != product.revision ||
                  old.product.priceCents != product.priceCents)) ||
          (old == null && items.length >= 50)) {
        throw const FormatException();
      }
      final next = OrderSelection(product, quantity);
      final nextTotal =
          total -
          (old == null ? 0 : old.quantity * old.product.priceCents) +
          next.quantity * product.priceCents;
      if (nextTotal > 100000000) throw const FormatException();
      setState(() {
        items[product.reference] = next;
        dirty = true;
        message = null;
      });
    } catch (_) {
      setState(() {
        message = 'cartLimit';
      });
    }
  }

  Future<void> submit() async {
    if (!canSubmit) return;
    final generation = epoch, identity = widget.auth.session;
    final original = List<OrderSelection>.unmodifiable(items.values);
    final orderContext = currentContext, memberRef = widget.memberRef;
    final draft = savedDraft;
    setState(() {
      busy = true;
      confirming = true;
    });
    try {
      final accepted = await showDialog<bool>(
        context: context,
        builder: (dialogContext) {
          activeDialog = dialogContext;
          return AlertDialog(
            title: Text(t('cartSubmit')),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${orderContext.tableName}\n$memberName'),
                  Text(
                    t(
                      orderContext.paymentTiming == 'prepay'
                          ? 'livePrepay'
                          : 'livePostpay',
                    ),
                  ),
                  for (final item in original)
                    Text(
                      '${item.product.name(widget.language)} · ${item.product.specification(widget.language)} × ${item.quantity} · CNY ${formatCents(item.quantity * item.product.priceCents)}',
                    ),
                  Text('CNY ${formatCents(total)}'),
                  Text(t('cartConfirmNotice')),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: Text(t('cancel')),
              ),
              FilledButton(
                key: const ValueKey('cart-confirm'),
                onPressed: () => Navigator.pop(dialogContext, true),
                child: Text(t('confirm')),
              ),
            ],
          );
        },
      );
      activeDialog = null;
      if (accepted != true ||
          !mounted ||
          generation != epoch ||
          !identical(identity, widget.auth.session)) {
        return;
      }
      // Any attempted delivery leaves this editor terminal. Recovery owns the original ID.
      setState(() {
        attempted = true;
        confirming = false;
        message = null;
      });
      final result = await widget.auth.submitOrder(
        context: orderContext,
        memberRef: memberRef,
        items: original,
        confirmed: true,
        cartDraft: draft,
      );
      if (mounted && generation == epoch) {
        setState(() {
          items.clear();
          message = switch (result.state) {
            OrderRequestState.confirmed => 'orderRecoveryConfirmed',
            OrderRequestState.cancelled => 'orderRecoveryCancelled',
            OrderRequestState.notObserved => 'orderRecoveryUnknown',
          };
        });
      }
    } catch (_) {
      if (mounted && generation == epoch) {
        setState(() {
          message = 'orderRecoveryUnconfirmed';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          busy = false;
          confirming = false;
        });
      }
    }
  }

  @override
  void dispose() {
    ++epoch;
    widget.auth.removeListener(invalidate);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (recovery) {
      return LiveOrderRecoveryPanel(
        auth: widget.auth,
        language: widget.language,
        onBack: widget.onBack,
      );
    }
    return Row(
      children: [
        Expanded(
          flex: 3,
          child: AbsorbPointer(
            absorbing: !editable,
            child: LiveCatalogPanel(
              auth: widget.auth,
              language: widget.language,
              revision: widget.revision,
              onBack: widget.onBack,
              onSelect: (product) => change(product, 1),
            ),
          ),
        ),
        const VerticalDivider(width: 1),
        Expanded(
          flex: 2,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          '${widget.orderContext.tableName} · ${t('cartTitle')}',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        Text(memberName),
                        Text(
                          t(
                            currentContext.paymentTiming == 'prepay'
                                ? 'livePrepay'
                                : 'livePostpay',
                          ),
                        ),
                        if (message != null)
                          Text(
                            t(message!),
                            key: const ValueKey('cart-message'),
                          ),
                        if (busy && !confirming)
                          const LinearProgressIndicator(),
                        Text(t('cartDraftNotice')),
                        Wrap(
                          spacing: 8,
                          children: [
                            OutlinedButton(
                              key: const ValueKey('cart-draft-save'),
                              onPressed: editable && items.isNotEmpty && dirty
                                  ? () => unawaited(draftOperation('save'))
                                  : null,
                              child: Text(t('cartDraftSave')),
                            ),
                            OutlinedButton(
                              key: const ValueKey('cart-draft-restore'),
                              onPressed:
                                  draftAction && savedDraft != null && !dirty
                                  ? () => unawaited(draftOperation('restore'))
                                  : null,
                              child: Text(t('cartDraftRestore')),
                            ),
                            TextButton(
                              key: const ValueKey('cart-draft-discard'),
                              onPressed: draftAction && savedDraft != null
                                  ? () => unawaited(draftOperation('discard'))
                                  : null,
                              child: Text(t('cartDraftDiscard')),
                            ),
                          ],
                        ),
                        if (savedDraft != null && dirty)
                          Text(t('cartDraftResave')),
                        if (items.isEmpty) Text(t('cartDraftEmpty')),
                        for (final item in items.values)
                          Card(
                            child: Padding(
                              padding: const EdgeInsets.all(8),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(item.product.name(widget.language)),
                                  Text(
                                    item.product.specification(widget.language),
                                  ),
                                  Text(
                                    'CNY ${formatCents(item.product.priceCents)} × ${item.quantity}',
                                  ),
                                  Wrap(
                                    children: [
                                      IconButton(
                                        key: ValueKey(
                                          'cart-minus-${item.product.reference}',
                                        ),
                                        tooltip: t('cartRemove'),
                                        onPressed: editable
                                            ? () => change(item.product, -1)
                                            : null,
                                        icon: const Icon(Icons.remove),
                                      ),
                                      IconButton(
                                        key: ValueKey(
                                          'cart-plus-${item.product.reference}',
                                        ),
                                        tooltip: t('cartAdd'),
                                        onPressed: editable
                                            ? () => change(item.product, 1)
                                            : null,
                                        icon: const Icon(Icons.add),
                                      ),
                                      IconButton(
                                        key: ValueKey(
                                          'cart-delete-${item.product.reference}',
                                        ),
                                        tooltip: t('cartDelete'),
                                        onPressed: editable
                                            ? () => change(
                                                item.product,
                                                -item.quantity,
                                              )
                                            : null,
                                        icon: const Icon(Icons.delete_outline),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                Text(
                  'CNY ${formatCents(total)}',
                  key: const ValueKey('cart-total'),
                ),
                FilledButton(
                  key: const ValueKey('cart-submit'),
                  onPressed: canSubmit ? () => unawaited(submit()) : null,
                  child: Text(t('cartSubmit')),
                ),
                OutlinedButton(
                  key: const ValueKey('cart-recovery'),
                  onPressed: busy
                      ? null
                      : () => setState(() {
                          recovery = true;
                        }),
                  child: Text(t('orderRecoveryTitle')),
                ),
                TextButton(
                  onPressed: busy ? null : widget.onBack,
                  child: Text(t('ordersBack')),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
