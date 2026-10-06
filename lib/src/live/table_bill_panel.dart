import 'provider_refund_dialog.dart';
import 'wine_pickup_panel.dart';
import 'product_thumbnail.dart';

import 'dart:convert';

import 'wine_storage_dialog.dart';

import 'package:cryptography/cryptography.dart';

import '../hardware/receipt_document_renderer.dart';
import '../hardware/receipt_print_identity.dart';
import '../hardware/paid_receipt_printer.dart';
import 'bill_product_group.dart';
import 'workspace_read_cache.dart';
import 'table_detail_snapshot.dart';
import 'bill_product_card.dart';
import 'bill_details_dialog.dart';
import 'bill_serving_dialog.dart';
import 'bill_item_return_dialog.dart';
import 'catalog_snapshot.dart';
import 'item_price_dialog.dart';

import 'dart:async';

import 'package:flutter/material.dart';

import '../auth/staff_auth_controller.dart';
import '../network/ccsop_client.dart';
import '../strings.dart';
import 'order_snapshot.dart';
import 'table_checkout_dialog.dart';
import 'table_snapshot.dart';

/// The server's table bill, separate from the local unsubmitted selection.
class TableBillPanel extends StatefulWidget {
  const TableBillPanel({
    super.key,
    required this.auth,
    required this.language,
    required this.tableRef,
    required this.sessionRef,
    required this.revision,
    this.checkoutAllowed = true,
    this.recording = false,
    this.changesAllowed = true,
    this.fillHeight = false,
    this.leading,
    this.draftCents = 0,
    this.headerBuilder,
    this.onAddProduct,
    this.draftCards = const {},
    this.onQuickAddProduct,
    this.onRepriceDraft,
    this.onQuickAddSpecialProduct,
    this.orderAction,
    this.primaryAction,
    this.beforeActions,
    this.seatSessions = const [],
    this.emptySeat = false,
    this.readOnly = false,
    this.receiptCaption,
    this.receiptDate,
    this.initialBill,
    this.detailRead,
  });
  final StaffAuthController auth;
  final UiLanguage language;
  final String tableRef, sessionRef;
  final List<Map<String, String>> seatSessions;
  final int revision;
  final bool checkoutAllowed, fillHeight, recording;

  /// Selected unused seat: render the same bill without creating a session.
  final bool emptySeat;
  final bool readOnly;
  final Future<TableDetailSnapshot>? detailRead;
  final ReceiptCaption? receiptCaption;
  final String? receiptDate;
  final ({OrderSnapshot snapshot, List<LiveOrder> orders})? initialBill;
  final bool changesAllowed;
  final Widget? leading;
  final Widget? orderAction, primaryAction, beforeActions;
  final int draftCents;
  final Widget Function(Widget filter)? headerBuilder;
  final Future<void> Function(String productRef)? onAddProduct;
  final Map<String, BillProductCard> draftCards;
  final Future<void> Function(CatalogProduct product)? onQuickAddProduct;
  final Future<void> Function(
    CatalogProduct product,
    int unitPriceCents,
    String selectionRef, [
    String? expenseOwnerUserAccount,
    String? authorizationRef,
  ])?
  onQuickAddSpecialProduct;
  final void Function(
    String draftRef,
    int unitPriceCents,
    String selectionRef, [
    String? expenseOwnerUserAccount,
    String? authorizationRef,
  ])?
  onRepriceDraft;
  @override
  State<TableBillPanel> createState() => _TableBillPanelState();
}

class _TableBillPanelState extends State<TableBillPanel>
    with WidgetsBindingObserver {
  List<LiveOrder> orders = [];
  List<Map<String, dynamic>> storedWineServed = [];
  String filter = 'all';
  OrderSnapshot? snapshot;
  bool loading = false, failed = false, foreground = true, checkout = false;
  bool reducing = false;
  bool verifiedSnapshot = false;
  bool firstDisplayReported = false;
  final queuedReductions = <String>[];
  int epoch = 0;
  final inventory = <String, CatalogProduct>{};
  bool printingBill = false;
  String get displayKey {
    final refs =
        widget.seatSessions
            .map((s) => '${s['tableRef']}/${s['sessionRef']}')
            .toSet()
            .toList()
          ..sort();
    return 'bill/${widget.tableRef}/${widget.sessionRef}${refs.isEmpty ? '' : '/${refs.join(',')}'}';
  }

  Future<void> printBill() async {
    final identity = widget.auth.session;
    if (identity == null || printingBill || loading || failed) return;
    final e = epoch;
    bool current() =>
        mounted &&
        foreground &&
        epoch == e &&
        identical(identity, widget.auth.session);
    final items =
        <
          ({
            String name,
            String specification,
            int quantity,
            int priceCents,
            String state,
          })
        >[];
    for (final order in orders) {
      if (order.status == 'expired' || order.fullyRefunded) continue;
      if (filter != 'all' && filter != 'gift' && order.status != filter)
        continue;
      if (filter == 'voucher') continue;
      for (final item in order.items) {
        if (item.activeQuantity == 0 ||
            (filter == 'gift' && item.priceCents != 0))
          continue;
        items.add((
          name: item.name(widget.language),
          specification: item.specification(widget.language),
          quantity: item.activeQuantity,
          priceCents: item.priceCents,
          state: item.priceCents == 0
              ? t('billGift')
              : t(order.status == 'paid' ? 'tableBillPaid' : 'tableBillUnpaid'),
        ));
      }
    }
    if (filter == 'all' || filter == 'pending') {
      for (final card in widget.draftCards.values) {
        items.add((
          name: card.name,
          specification: card.specification,
          quantity: card.quantity,
          priceCents: card.priceCents,
          state: [
            '待下单',
            'Not submitted',
            '待下單',
            'ยังไม่ส่งคำสั่ง',
          ][widget.language.index],
        ));
      }
    }
    if (filter == 'all' || filter == 'paid') {
      for (final wine in storedWineServed) {
        items.add((
          name: '${(wine['names'] as Map?)?['zh-CN'] ?? wine['name']}',
          specification:
              '${wine['specification'] ?? ''} ${wine['remainingPercent']}%',
          quantity: 1,
          priceCents: 0,
          state: [
            '存酒',
            'Stored wine',
            '存酒',
            'รับเครื่องดื่ม',
          ][widget.language.index],
        ));
      }
    }
    if (items.isEmpty) return;
    setState(() => printingBill = true);
    try {
      final caption =
          widget.receiptCaption ??
          await readReceiptCaption(
            widget.auth,
            widget.tableRef,
            widget.sessionRef,
          );
      final plan = ReceiptRasterPlan.bill(
        language: widget.language,
        caption: caption,
        filterLabel:
            '${widget.receiptDate == null ? '' : '${widget.receiptDate} · '}${t({'all': 'billAllConsumption', 'pending': 'tableBillUnpaid', 'paid': 'tableBillPaid', 'gift': 'billGift', 'voucher': 'billVoucher'}[filter]!)}',
        items: items,
      );
      final digest = await Sha256().hash(
        utf8.encode('${widget.tableRef}|${widget.sessionRef}|${plan.pages}'),
      );
      final status = await printReceiptPlan(
        plan: plan,
        printIdentity: ReceiptPrintIdentity.unpaid(
          base: identity.base.toString(),
          storeRef: identity.storeRef,
          fingerprint: digest.bytes
              .map((b) => b.toRadixString(16).padLeft(2, '0'))
              .join(),
        ),
        current: current,
        reprint: true,
      );
      if (mounted && status != 'checkoutPrintSent')
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(t(status))));
    } catch (_) {
      if (current())
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              [
                '小票未打印，请检查打印机',
                'Print unconfirmed; check the printer',
                '小票未列印，請檢查印表機',
                'ยังไม่พิมพ์ โปรดตรวจสอบเครื่องพิมพ์',
              ][widget.language.index],
            ),
          ),
        );
    } finally {
      if (mounted) setState(() => printingBill = false);
    }
  }

  String t(String key) => tr(widget.language, key);
  bool get canRead =>
      widget.auth.session?.permissions.contains('orders.read') == true;
  @override
  void initState() {
    super.initState();
    foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    widget.auth.addListener(reset);
    restoreDisplayCache();
    unawaited(load());
  }

  void restoreDisplayCache() {
    if (widget.emptySeat) return;
    if (foreground && canRead) {
      final cached =
          (widget.readOnly ? widget.initialBill : null) ??
          WorkspaceReadCache.read<
            ({OrderSnapshot snapshot, List<LiveOrder> orders})
          >(
            widget.auth.session,
            displayKey,
            maxAge: const Duration(minutes: 5),
          );
      if (cached != null) {
        snapshot = cached.snapshot;
        orders = List.of(cached.orders);
        final products = WorkspaceReadCache.read<List<CatalogProduct>>(
          widget.auth.session,
          'products/$displayKey',
          maxAge: const Duration(minutes: 5),
        );
        inventory.addEntries(
          (products ?? []).map((p) => MapEntry(p.reference, p)),
        );
      }
      storedWineServed = List.of(
        WorkspaceReadCache.read<List<Map<String, dynamic>>>(
              widget.auth.session,
              'wine/$displayKey',
              maxAge: const Duration(minutes: 5),
            ) ??
            [],
      );
    }
  }

  void reset({bool useCache = false}) {
    epoch++;
    activeRead = null;
    queuedReductions.clear();
    verifiedSnapshot = false;
    setState(() {
      orders = [];
      storedWineServed = [];
      snapshot = null;
      loading = false;
      failed = false;
      inventory.clear();
      if (useCache) restoreDisplayCache();
    });
    if (foreground) {
      unawaited(load());
    }
  }

  @override
  void didUpdateWidget(covariant TableBillPanel old) {
    super.didUpdateWidget(old);
    if (widget.draftCents > old.draftCents && filter == 'paid') {
      filter = 'pending';
    }
    if (old.auth != widget.auth) {
      old.auth.removeListener(reset);
      widget.auth.addListener(reset);
    }
    if (old.auth != widget.auth ||
        old.tableRef != widget.tableRef ||
        old.sessionRef != widget.sessionRef) {
      reset(useCache: old.auth == widget.auth);
    } else if ((old.revision != widget.revision ||
            old.detailRead != widget.detailRead) &&
        foreground) {
      unawaited(load(fresh: true));
    } else if (old.onQuickAddProduct == null &&
        widget.onQuickAddProduct != null &&
        !loading &&
        inventory.isEmpty) {
      unawaited(loadInventory(epoch));
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    reset();
  }

  Future<void>? activeRead;
  Future<TableDetailSnapshot>? consumedDetail;
  Future<void> load({bool more = false, bool fresh = false}) async {
    if (widget.emptySeat) return;
    if (widget.readOnly && widget.initialBill != null) {
      restoreDisplayCache();
      await loadStoredWine(epoch);
      return;
    }
    final previous = activeRead;
    if (previous != null) {
      await previous;
      if (!fresh || !mounted) return;
    }
    final work = readBill(more: more);
    activeRead = work;
    try {
      await work;
    } finally {
      if (identical(activeRead, work)) activeRead = null;
    }
  }

  Future<void> readBill({bool more = false}) async {
    final timer = Stopwatch()..start();
    if (!mounted ||
        !foreground ||
        !canRead ||
        (more && (loading || snapshot?.nextAfterOrder == null))) {
      return;
    }
    final ticket = ++epoch, identity = widget.auth.session;
    if (widget.detailRead != null) {
      setState(() {
        loading = true;
        failed = false;
      });
      try {
        final request = consumedDetail != widget.detailRead
            ? widget.detailRead!
            : widget.auth.readTableDetail(
                tableRef: widget.tableRef,
                sessionRef: widget.sessionRef,
              );
        consumedDetail = widget.detailRead;
        final detail = await request;
        if (!mounted ||
            ticket != epoch ||
            !foreground ||
            !identical(identity, widget.auth.session))
          return;
        final allOrders = List<LiveOrder>.of(detail.bill.orders);
        final allWine = List<Map<String, dynamic>>.of(detail.wine);
        final allProducts = List<CatalogProduct>.of(detail.products);
        for (final seat in widget.seatSessions.where(
          (s) => s['sessionRef'] != widget.sessionRef,
        )) {
          final extra = await widget.auth.readTableDetail(
            tableRef: seat['tableRef']!,
            sessionRef: seat['sessionRef']!,
          );
          if (!mounted ||
              ticket != epoch ||
              !foreground ||
              !identical(identity, widget.auth.session))
            return;
          allOrders.addAll(extra.bill.orders);
          allWine.addAll(extra.wine);
          allProducts.addAll(extra.products);
        }
        WorkspaceReadCache.put(identity, displayKey, (
          snapshot: detail.bill,
          orders: List<LiveOrder>.unmodifiable(allOrders),
        ));
        WorkspaceReadCache.put(
          identity,
          'products/$displayKey',
          List<CatalogProduct>.unmodifiable(allProducts),
        );
        WorkspaceReadCache.put(
          identity,
          'wine/$displayKey',
          List<Map<String, dynamic>>.unmodifiable(allWine),
        );
        setState(() {
          snapshot = detail.bill;
          orders = allOrders;
          storedWineServed = allWine;
          inventory
            ..clear()
            ..addEntries(allProducts.map((p) => MapEntry(p.reference, p)));
          verifiedSnapshot = true;
          loading = false;
          failed = false;
        });
      } catch (_) {
        if (mounted && ticket == epoch)
          setState(() {
            loading = false;
            failed = true;
            verifiedSnapshot = false;
          });
      }
      return;
    }
    unawaited(loadStoredWine(ticket));
    final cursor = more ? snapshot?.nextAfterOrder : null;
    final previous = more ? List<LiveOrder>.of(orders) : <LiveOrder>[];
    setState(() {
      loading = true;
      failed = false;
    });
    try {
      var after = cursor;
      final collected = List<LiveOrder>.of(previous);
      OrderSnapshot? next;
      do {
        final raw = await WorkspaceReadCache.readOnce(
          identity!,
          'orders/${widget.tableRef}/${widget.sessionRef}/$after',
          () => widget.auth.readOrders(
            tableRef: widget.tableRef,
            sessionRef: widget.sessionRef,
            afterOrder: after,
          ),
        );
        if (!mounted ||
            ticket != epoch ||
            !foreground ||
            !identical(identity, widget.auth.session)) {
          return;
        }
        next = OrderSnapshot.parse(
          raw,
          storeRef: identity.storeRef,
          tableRef: widget.tableRef,
          sessionRef: widget.sessionRef,
          afterOrder: after,
        );
        collected.addAll(next.orders);
        after = next.nextAfterOrder;
      } while (after != null);
      for (final seat in widget.seatSessions.where(
        (s) => s['sessionRef'] != widget.sessionRef,
      )) {
        String? seatCursor;
        do {
          final raw = await WorkspaceReadCache.readOnce(
            identity,
            'orders/${seat['tableRef']}/${seat['sessionRef']}/$seatCursor',
            () => widget.auth.readOrders(
              tableRef: seat['tableRef']!,
              sessionRef: seat['sessionRef']!,
              afterOrder: seatCursor,
            ),
          );
          if (!mounted ||
              ticket != epoch ||
              !foreground ||
              !identical(identity, widget.auth.session))
            return;
          final extra = OrderSnapshot.parse(
            raw,
            storeRef: identity.storeRef,
            tableRef: seat['tableRef']!,
            sessionRef: seat['sessionRef']!,
            afterOrder: seatCursor,
          );
          collected.addAll(extra.orders);
          seatCursor = extra.nextAfterOrder;
        } while (seatCursor != null);
      }
      WorkspaceReadCache.put(identity, displayKey, (
        snapshot: next,
        orders: List<LiveOrder>.unmodifiable(collected),
      ));
      setState(() {
        orders = collected;
        snapshot = next;
        verifiedSnapshot = true;
        loading = false;
      });
      if (widget.onQuickAddProduct != null) unawaited(loadInventory(ticket));
    } catch (_) {
      if (mounted && ticket == epoch) {
        setState(() {
          failed = true;
          loading = false;
        });
      }
    } finally {
      debugPrint('cashier_bill_read elapsed_ms=${timer.elapsedMilliseconds}');
    }
  }

  Future<void> loadStoredWine(int ticket) async {
    final timer = Stopwatch()..start();
    final identity = widget.auth.session;
    final scope = '${widget.tableRef}/${widget.sessionRef}';
    try {
      final seats = [
        {'tableRef': widget.tableRef, 'sessionRef': widget.sessionRef},
        ...widget.seatSessions.where(
          (s) => s['sessionRef'] != widget.sessionRef,
        ),
      ];
      final results = await Future.wait(
        seats.map(
          (seat) => WorkspaceReadCache.readOnce(
            identity!,
            'wine/${seat['tableRef']}/${seat['sessionRef']}',
            () => widget.auth.wineStorage({...seat, 'action': 'served'}),
          ),
        ),
      );
      if (!mounted ||
          ticket != epoch ||
          !identical(identity, widget.auth.session) ||
          scope != '${widget.tableRef}/${widget.sessionRef}')
        return;
      setState(
        () => storedWineServed = [
          for (final result in results)
            for (final item in result['items'] as List)
              Map<String, dynamic>.from(item as Map),
        ],
      );
      WorkspaceReadCache.put(
        identity,
        'wine/$displayKey',
        List<Map<String, dynamic>>.unmodifiable(storedWineServed),
      );
    } catch (_) {
      /* Keep the existing bill usable; a failed read never implies pickup success. */
    } finally {
      debugPrint('cashier_wine_read elapsed_ms=${timer.elapsedMilliseconds}');
    }
  }

  Future<void> loadInventory(int ticket) async {
    if (widget.detailRead != null) return;
    try {
      final wanted = orders
          .expand((o) => o.items)
          .map((i) => i.productRef)
          .toSet();
      final found = <String, CatalogProduct>{};
      String? cursor;
      final seen = <String>{};
      while (wanted.isNotEmpty) {
        final page = await widget.auth.readCatalog(afterProduct: cursor);
        if (!mounted || ticket != epoch || !foreground) return;
        for (final product in page.products) {
          if (wanted.remove(product.reference)) {
            found[product.reference] = product;
          }
        }
        cursor = page.nextAfterProduct;
        if (cursor == null) break;
        if (!seen.add(cursor)) throw const FormatException();
      }
      if (mounted && ticket == epoch) {
        setState(() {
          inventory
            ..clear()
            ..addAll(found);
        });
      }
    } catch (_) {
      // Unknown stock leaves quick-add disabled; bill amounts remain readable.
    }
  }

  Future<void> pay() async {
    if (loading ||
        failed ||
        checkout ||
        !foreground ||
        !widget.checkoutAllowed ||
        reducing ||
        snapshot == null) {
      return;
    }
    final identity = widget.auth.session;
    final tableRef = widget.tableRef, sessionRef = widget.sessionRef;
    setState(() => checkout = true);
    try {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (context) {
          if (!mounted ||
              !foreground ||
              tableRef != widget.tableRef ||
              sessionRef != widget.sessionRef ||
              !identical(identity, widget.auth.session)) {
            final route = ModalRoute.of(context);
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (context.mounted && route != null && route.isActive) {
                Navigator.of(context).removeRoute(route);
              }
            });
            return const SizedBox.shrink();
          }
          return TableCheckoutDialog(
            seatSessions: widget.seatSessions,
            paidCents: widget.seatSessions.isNotEmpty
                ? orders.fold<int>(0, (sum, o) => sum + o.netPaidCents)
                : (snapshot?.sessionSummary?.buckets['netPaid'] ??
                              snapshot?.sessionSummary?.buckets['paid'])
                          ?.totalCents ??
                      0,
            auth: widget.auth,
            language: widget.language,
            tableRef: tableRef,
            sessionRef: sessionRef,
          );
        },
      );
    } finally {
      if (mounted) {
        setState(() => checkout = false);
        if (foreground) {
          unawaited(load());
        }
      }
    }
  }

  @override
  void dispose() {
    epoch++;
    widget.auth.removeListener(reset);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  bool canReduce(BillProductGroup group) =>
      !widget.readOnly &&
      verifiedSnapshot &&
      !checkout &&
      widget.changesAllowed &&
      foreground &&
      widget.auth.session?.permissions.contains('orders.create') == true &&
      snapshot?.sessionStatus == 'open' &&
      group.active.any(
        (line) =>
            line.order.status == 'pending' &&
            line.item.servingKnown &&
            (line.item.remainingQuantity ?? 0) > 0,
      );

  Future<void> reduceGroup(
    BillProductGroup group, {
    bool retryConflict = true,
  }) async {
    if (failed || !canReduce(group)) return;
    if (reducing) {
      if (queuedReductions.length < 50) queuedReductions.add(group.groupingRef);
      return;
    }
    var succeeded = false;
    var stateConflict = false;
    final identity = widget.auth.session,
        table = widget.tableRef,
        session = widget.sessionRef;
    // Most recent unpaid addition first, keeping the original price on each order.
    final lines =
        group.active
            .where(
              (line) =>
                  line.order.status == 'pending' &&
                  line.item.servingKnown &&
                  (line.item.remainingQuantity ?? 0) > 0,
            )
            .toList()
          ..sort((a, b) => b.order.reference.compareTo(a.order.reference));
    final target = lines.first;
    setState(() => reducing = true);
    try {
      await widget.auth.reduceUnpaidItem(
        tableRef: table,
        sessionRef: session,
        orderRef: target.order.reference,
        productRef: target.item.productRef,
        expectedQuantity: target.item.quantity,
        expectedServedQuantity: target.item.servedQuantity!,
        expectedServingEpoch: target.item.servingEpoch,
        expectedTotalCents: target.order.totalCents,
      );
      succeeded = true;
    } catch (error) {
      stateConflict =
          retryConflict &&
          error is CcsopFailure &&
          error.code == 'ORDER_REDUCTION_STATE_CHANGED';
      if (!stateConflict &&
          mounted &&
          identical(identity, widget.auth.session) &&
          table == widget.tableRef &&
          session == widget.sessionRef) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              t(
                error is CcsopFailure &&
                        [
                          'ORDER_REDUCTION_PAYMENT_REVIEW',
                          'CASHIER_TABLE_CHECKOUT_IN_PROGRESS',
                        ].contains(error.code)
                    ? 'billReductionPaymentBusy'
                    : 'billReductionRefresh',
              ),
            ),
          ),
        );
      }
    } finally {
      if (mounted) {
        await load(fresh: true);
        if (mounted) {
          setState(() => reducing = false);
          if (stateConflict &&
              !failed &&
              identical(identity, widget.auth.session) &&
              table == widget.tableRef &&
              session == widget.sessionRef) {
            final next = groupBillProducts(orders)
                .where(
                  (g) => g.groupingRef == group.groupingRef && canReduce(g),
                )
                .firstOrNull;
            if (next != null) {
              unawaited(reduceGroup(next, retryConflict: false));
            } else {
              queuedReductions.clear();
            }
          } else if (!succeeded ||
              failed ||
              !identical(identity, widget.auth.session) ||
              table != widget.tableRef ||
              session != widget.sessionRef) {
            queuedReductions.clear();
          } else {
            while (queuedReductions.isNotEmpty) {
              final ref = queuedReductions.removeAt(0);
              final next = groupBillProducts(orders)
                  .where((g) => g.groupingRef == ref && canReduce(g))
                  .firstOrNull;
              if (next != null) {
                unawaited(reduceGroup(next));
                break;
              }
            }
          }
        }
      }
    }
  }

  Future<void> openGroup(BillProductGroup group) async {
    if (loading || failed || !foreground || reducing || checkout) return;
    final table = widget.tableRef, session = widget.sessionRef;
    final unpaid = group.active
        .where((line) => line.order.status == 'pending')
        .toList();
    final draftRef = group.item.pricingRef ?? group.productRef;
    final draft = widget.draftCards[draftRef];
    if (unpaid.isEmpty && draft != null) {
      draft.onTap?.call();
      return;
    }
    if (draft != null && widget.onRepriceDraft == null) {
      draft.onTap?.call();
      return;
    }
    if (unpaid.isEmpty ||
        !widget.changesAllowed ||
        snapshot?.sessionStatus != 'open' ||
        widget.auth.session?.permissions.contains('orders.create') != true ||
        unpaid.any((line) => !line.item.servingKnown)) {
      return openGroupDetails(group);
    }
    final generation = epoch, identity = widget.auth.session;
    var details = false;
    final first = unpaid.first.item;
    var expenseOwner = first.expenseOwnerUserAccount;
    String? authorization;
    final price = await showItemPriceDialog(
      context,
      language: widget.language,
      name: '${first.name(widget.language)} · ${t('tableBillUnpaid')}',
      quantity:
          unpaid.fold(0, (n, line) => n + line.item.quantity) +
          (draft?.quantity ?? 0),
      originalCents: first.originalPriceCents,
      currentCents: first.priceCents,
      auth: widget.auth,
      expenseOwnerUserAccount: expenseOwner,
      onExpenseOwner: (value) => expenseOwner = value,
      authorizationScope: {
        'tableRef': widget.tableRef,
        'sessionRef': widget.sessionRef,
        'productRef': group.productRef,
      },
      onAuthorization: (value) => authorization = value,
      onDetails: () => details = true,
    );
    if (!mounted ||
        generation != epoch ||
        !identical(identity, widget.auth.session) ||
        !foreground) {
      return;
    }
    if (details) return openGroupDetails(group);
    if (price == null) return;
    setState(() => checkout = true);
    try {
      final selectionRef = await widget.auth.repriceUnpaidItems(
        tableRef: widget.tableRef,
        sessionRef: widget.sessionRef,
        productRef: group.productRef,
        unitPriceCents: price,
        expenseOwnerUserAccount: expenseOwner,
        authorizationRef: authorization,
        items: [
          for (final line in unpaid)
            {
              'orderRef': line.order.reference,
              'expectedQuantity': line.item.quantity,
              'expectedServedQuantity': line.item.servedQuantity!,
              if (line.item.servingEpoch != null)
                'expectedServingEpoch': line.item.servingEpoch!,
              'expectedTotalCents': line.order.totalCents,
              'expectedUnitPriceCents': line.item.priceCents,
            },
        ],
      );
      if (mounted &&
          identical(identity, widget.auth.session) &&
          foreground &&
          table == widget.tableRef &&
          session == widget.sessionRef &&
          draft != null) {
        widget.onRepriceDraft?.call(
          draftRef,
          price,
          selectionRef,
          expenseOwner,
          authorization,
        );
      }
    } catch (_) {
      if (mounted &&
          generation == epoch &&
          identical(identity, widget.auth.session)) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              [
                '改价未完成，请核对账单后重试',
                'Price update failed. Check the bill and retry.',
                '改價未完成，請核對帳單後重試',
                'เปลี่ยนราคาไม่สำเร็จ โปรดตรวจสอบบิลแล้วลองใหม่',
              ][widget.language.index],
            ),
          ),
        );
      }
    } finally {
      if (mounted) {
        await load(fresh: true);
        if (mounted) setState(() => checkout = false);
      }
    }
  }

  Future<void> openGroupDetails(BillProductGroup group) async {
    if (loading || failed || !foreground || reducing || checkout) return;
    final generation = epoch, identity = widget.auth.session;
    bool current() =>
        mounted &&
        foreground &&
        generation == epoch &&
        identical(identity, widget.auth.session) &&
        !loading &&
        !failed;
    bool canServe(LiveOrder order, OrderItem item) =>
        identity?.permissions.contains('orders.serve') == true &&
        order.refundQuantitiesKnown &&
        !order.fullyRefunded &&
        item.servingKnown &&
        item.remainingQuantity! > 0 &&
        {'open', 'clearing'}.contains(snapshot?.sessionStatus) &&
        (order.status == 'paid' ||
            order.status == 'waived' ||
            (snapshot?.paymentTiming == 'postpay' &&
                order.status == 'pending'));
    bool canRecall(LiveOrder order, OrderItem item) =>
        identity?.permissions.contains('orders.serve') == true &&
        order.refundQuantitiesKnown &&
        !order.fullyRefunded &&
        item.servingKnown &&
        item.servedQuantity! > item.storedQuantity &&
        item.servingEpoch != null &&
        item.servingEpoch! < 1000000 &&
        {'open', 'clearing'}.contains(snapshot?.sessionStatus) &&
        (order.status == 'paid' ||
            order.status == 'waived' ||
            (snapshot?.paymentTiming == 'postpay' &&
                order.status == 'pending'));
    bool canReturnUnserved(LiveOrder order, OrderItem item) =>
        identity?.permissions.contains('orders.serve') == true &&
        identity?.permissions.contains('orders.create') == true &&
        order.refunds.isEmpty &&
        order.status == 'pending' &&
        snapshot?.paymentTiming == 'postpay' &&
        snapshot?.sessionStatus == 'open' &&
        item.servingKnown &&
        item.servingEpoch != null &&
        item.servingEpoch! < 1000000 &&
        (item.returnableUnservedQuantity ?? 0) > 0;
    bool canStoreWine(LiveOrder order, OrderItem item) =>
        identity?.permissions.contains('orders.serve') == true &&
        order.status == 'paid' &&
        item.wineStorage &&
        order.refunds.isEmpty &&
        snapshot?.sessionStatus == 'open' &&
        (item.servedQuantity ?? 0) > item.storedQuantity;
    bool canRefund(LiveOrder order, OrderItem item) =>
        identity?.permissions.contains('payment.refund') == true &&
        order.status == 'paid' &&
        order.providerRefundAvailable &&
        order.refundQuantitiesKnown &&
        !order.fullyRefunded &&
        item.activeQuantity > item.storedQuantity &&
        {'open', 'clearing'}.contains(snapshot?.sessionStatus);
    final selected = await showDialog<BillDetailAction>(
      context: context,
      builder: (_) => BillDetailsDialog(
        group: group,
        language: widget.language,
        canServe: canServe,
        canRecall: canRecall,
        canReturnUnserved: canReturnUnserved,
        canStoreWine: canStoreWine,
        canRefund: canRefund,
      ),
    );
    if (!mounted || !current() || selected == null) return;
    if (selected.action == 'refund' &&
        canRefund(selected.order, selected.item)) {
      final refundTable = widget.tableRef, refundSession = widget.sessionRef;
      await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => ProviderRefundDialog(
          auth: widget.auth,
          order: selected.order,
          item: selected.item,
          served: selected.served,
          language: widget.language,
          isCurrent: () =>
              mounted &&
              foreground &&
              identical(identity, widget.auth.session) &&
              widget.tableRef == refundTable &&
              widget.sessionRef == refundSession,
        ),
      );
      if (mounted && foreground) await load();
      return;
    }
    if (selected.action == 'storeWine' &&
        canStoreWine(selected.order, selected.item)) {
      await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => WineStorageDialog(
          auth: widget.auth,
          language: widget.language,
          tableRef: widget.tableRef,
          sessionRef: widget.sessionRef,
          orderRef: selected.order.reference,
          productRef: selected.item.productRef,
          name: selected.item.name(widget.language),
          isCurrent: current,
        ),
      );
      if (mounted && foreground) await load();
      return;
    }
    if (selected.action == 'return' &&
        !selected.served &&
        canReturnUnserved(selected.order, selected.item)) {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => BillItemReturnDialog(
          auth: widget.auth,
          language: widget.language,
          tableRef: widget.tableRef,
          sessionRef: widget.sessionRef,
          order: selected.order,
          item: selected.item,
          isCurrent: current,
          served: false,
        ),
      );
      if (mounted && foreground) await load();
      return;
    }
    final recall = selected.action == 'recall';
    if (recall && canRecall(selected.order, selected.item)) {
      final choice = await showDialog<bool>(
        context: context,
        builder: (context) => SimpleDialog(
          title: Text(t('billRecall')),
          children: [
            SimpleDialogOption(
              key: const ValueKey('bill-recall-wait'),
              onPressed: () => Navigator.pop(context, true),
              child: Text(t('billRecallWait')),
            ),
            ListTile(
              key: const ValueKey('bill-recall-return'),
              enabled:
                  selected.order.status == 'pending' &&
                  identity?.permissions.contains('orders.create') == true &&
                  identity?.permissions.contains('payment.refund') == true &&
                  snapshot?.sessionStatus == 'open',
              onTap:
                  selected.order.status == 'pending' &&
                      identity?.permissions.contains('orders.create') == true &&
                      identity?.permissions.contains('payment.refund') ==
                          true &&
                      snapshot?.sessionStatus == 'open'
                  ? () => Navigator.pop(context, false)
                  : null,
              title: Text(t('billRecallReturn')),
            ),
          ],
        ),
      );
      if (!mounted || !current() || choice == null) return;
      if (!choice) {
        await showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (_) => BillItemReturnDialog(
            auth: widget.auth,
            language: widget.language,
            tableRef: widget.tableRef,
            sessionRef: widget.sessionRef,
            order: selected.order,
            item: selected.item,
            isCurrent: current,
          ),
        );
        if (mounted && foreground) await load();
        return;
      }
    }
    if ((!recall &&
            selected.action == 'serve' &&
            canServe(selected.order, selected.item)) ||
        (recall && canRecall(selected.order, selected.item))) {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => BillServingDialog(
          auth: widget.auth,
          language: widget.language,
          tableRef: widget.tableRef,
          sessionRef: widget.sessionRef,
          order: selected.order,
          item: selected.item,
          isCurrent: current,
          recall: recall,
        ),
      );
      if (mounted && foreground) await load();
    }
  }

  Widget status(String label, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.10),
      borderRadius: BorderRadius.circular(4),
    ),
    child: Text(
      label,
      style: TextStyle(fontSize: 10, color: color, fontWeight: FontWeight.w600),
    ),
  );
  Widget filterDropdown() => DropdownButton<String>(
    key: const ValueKey('bill-filter'),
    value: filter,
    underline: const SizedBox(),
    style: const TextStyle(fontSize: 12, color: Color(0xff203d32)),
    items: [
      for (final entry in {
        'all': 'billAllConsumption',
        'pending': 'tableBillUnpaid',
        'paid': 'tableBillPaid',
        'voucher': 'billVoucher',
        'gift': 'billGift',
      }.entries)
        DropdownMenuItem(value: entry.key, child: Text(t(entry.value))),
    ],
    onChanged: (value) {
      if (value != null) setState(() => filter = value);
    },
  );

  Widget amountLabel(String label) => Text.rich(
    TextSpan(
      text: t(label),
      children: const [
        TextSpan(
          text: ' (CNY)',
          style: TextStyle(fontSize: 10, color: Color(0xFF86918B)),
        ),
      ],
    ),
    style: const TextStyle(fontSize: 12),
  );

  Widget amount(String label, int cents, String key) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      key: ValueKey(key),
      children: [
        Expanded(child: amountLabel(label)),
        Text(
          formatCents(cents),
          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    if (snapshot != null && !firstDisplayReported) {
      firstDisplayReported = true;
      final source = verifiedSnapshot ? 'server' : 'cache';
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) debugPrint('cashier_bill_first_frame source=$source');
      });
    }
    final pending = widget.emptySeat
        ? const OrderSummaryBucket(0, 0)
        : widget.seatSessions.isEmpty
        ? snapshot?.sessionSummary?.buckets['pending']
        : OrderSummaryBucket(
            orders.where((o) => o.status == 'pending').length,
            orders
                .where((o) => o.status == 'pending')
                .fold<int>(0, (sum, o) => sum + o.totalCents),
          );
    final summary = snapshot?.sessionSummary;
    final paid = widget.emptySeat
        ? const OrderSummaryBucket(0, 0)
        : widget.seatSessions.isEmpty
        ? summary?.buckets['netPaid'] ?? summary?.buckets['paid']
        : OrderSummaryBucket(
            orders.where((o) => o.status == 'paid').length,
            orders.fold<int>(0, (sum, o) => sum + o.netPaidCents),
          );
    final drafts = filter == 'all' || filter == 'pending'
        ? widget.draftCards
        : <String, BillProductCard>{};
    final visible = orders
        .where(
          (o) =>
              o.status != 'expired' &&
              (filter == 'all' ||
                  o.status == filter ||
                  (filter == 'gift' && o.items.any((i) => i.priceCents == 0))),
        )
        .toList();
    final groups = groupBillProducts(visible)
        .where(
          (g) => filter == 'gift'
              ? g.item.priceCents == 0
              : (filter == 'paid' || filter == 'pending')
              ? g.item.priceCents > 0
              : true,
        )
        .toList();
    BillProductCard? draftFor(BillProductGroup group) => group.currency == 'CNY'
        ? drafts[group.item.pricingRef ?? group.productRef]
        : null;
    final canPay = [
      'payment.cash',
      'payment.wechat',
      'payment.alipay',
      'payment.balance',
    ].any((p) => widget.auth.session?.permissions.contains(p) == true);
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.leading != null && (filter == 'all' || filter == 'pending'))
          widget.leading!,
        for (final entry in drafts.entries)
          if (!groups.any(
            (g) =>
                g.currency == 'CNY' &&
                (g.item.pricingRef ?? g.productRef) == entry.key,
          ))
            entry.value,
        if (canRead) ...[
          if (loading && snapshot == null) Text(t('billFirstSync')),
          if (failed)
            TextButton(
              onPressed: () => unawaited(load()),
              child: Text(t('tableBillRetry')),
            ),
          if (filter == 'voucher')
            Text(t('billSourceUnavailable'))
          else if (!loading &&
              !failed &&
              visible.isEmpty &&
              drafts.isEmpty &&
              storedWineServed.isEmpty)
            Text(t('billNoItems')),
          if (filter == 'all' || filter == 'paid')
            for (final wine in storedWineServed)
              BillProductCard(
                key: ValueKey('stored-wine-${wine['itemRef']}'),
                language: widget.language,
                name: '${(wine['names'] as Map?)?['zh-CN'] ?? wine['name']}',
                specification: '${wine['specification'] ?? ''}',
                quantity: 1,
                priceCents: 0,
                totalCents: 0,
                base: widget.auth.session?.base,
                thumbnailPath: productThumbnail(
                  wine['bottleMaterial'],
                  widget.auth.session?.storeRef ?? '',
                ),
                priceLabel: '${wine['remainingPercent']}%',
                totalLabel: [
                  '存酒',
                  'Stored wine',
                  '存酒',
                  'Stored wine',
                ][widget.language.index],
                badges: status(
                  '${t('tableBillPaid')} 1',
                  const Color(0xff216344),
                ),
                leadingBadge: status(
                  wine['restoredItemRef'] != null
                      ? [
                          '已再次存酒',
                          'Stored again',
                          '已再次存酒',
                          'Stored again',
                        ][widget.language.index]
                      : '${t('billServed')} ${wine['served'] == true ? 1 : 0} / ${t('billNotServed')} ${wine['served'] == true ? 0 : 1}',
                  wine['served'] == true
                      ? const Color(0xff216344)
                      : const Color(0xff994a16),
                ),
                onTap:
                    widget.readOnly ||
                        loading ||
                        !verifiedSnapshot ||
                        wine['restoredItemRef'] != null
                    ? null
                    : () async {
                        await showDialog<bool>(
                          context: context,
                          barrierDismissible: false,
                          builder: (_) => wine['served'] == true
                              ? WineStorageDialog(
                                  auth: widget.auth,
                                  language: widget.language,
                                  tableRef: widget.tableRef,
                                  sessionRef: widget.sessionRef,
                                  orderRef: wine['sourceOrderRef'] as String,
                                  productRef:
                                      wine['sourceProductRef'] as String,
                                  name: wine['name'] as String,
                                  restoredFromItemRef:
                                      wine['itemRef'] as String,
                                  isCurrent: () => mounted && foreground,
                                )
                              : AlertDialog(
                                  content: SizedBox(
                                    width: 420,
                                    child: WinePickupPanel(
                                      auth: widget.auth,
                                      language: widget.language,
                                      tableRef: widget.tableRef,
                                      sessionRef: widget.sessionRef,
                                      bottleItem: wine,
                                    ),
                                  ),
                                  actions: [
                                    TextButton(
                                      onPressed: () => Navigator.pop(context),
                                      child: Text(
                                        [
                                          '关闭',
                                          'Close',
                                          '關閉',
                                          'Close',
                                        ][widget.language.index],
                                      ),
                                    ),
                                  ],
                                ),
                        );
                        if (mounted) await loadStoredWine(epoch);
                      },
              ),
          for (final group in groups)
            BillProductCard(
              key: ValueKey(
                'bill-group-${group.currency}-${group.groupingRef}',
              ),
              language: widget.language,
              name: group.item.name(widget.language),
              specification: group.item.specification(widget.language),
              quantity: group.quantity + (draftFor(group)?.quantity ?? 0),
              priceCents: group.item.priceCents,
              priceLabel:
                  group.mixedPrices ||
                      (draftFor(group) != null &&
                          group.item.priceCents != draftFor(group)!.priceCents)
                  ? t('billMixedPrices')
                  : null,
              totalCents: group.totalCents + (draftFor(group)?.totalCents ?? 0),
              thumbnailPath: group.item.thumbnailPath,
              base: widget.auth.session?.base,
              onTap: !widget.readOnly && widget.seatSessions.isEmpty
                  ? () => openGroup(group)
                  : null,
              specialPrice: group.specialPrice,
              quantityControls: true,
              productRef: group.groupingRef,
              onMinus: !widget.readOnly && !failed && !checkout
                  ? (draftFor(group) != null
                        ? draftFor(group)!.onMinus
                        : (canReduce(group) ? () => reduceGroup(group) : null))
                  : null,
              onPlus:
                  !widget.readOnly &&
                      !failed &&
                      (group.specialPrice
                          ? widget.onQuickAddSpecialProduct != null
                          : widget.onQuickAddProduct != null) &&
                      (inventory[group.productRef]?.inventoryKnown ?? false) &&
                      (draftFor(group)?.quantity ?? 0) <
                          inventory[group.productRef]!.available &&
                      (draftFor(group)?.quantity ?? 0) < 1000
                  ? (draftFor(group) != null
                        ? draftFor(group)!.onPlus
                        : group.specialPrice
                        ? () => widget.onQuickAddSpecialProduct!(
                            inventory[group.productRef]!,
                            group.item.priceCents,
                            group.item.pricingRef!,
                            group.item.expenseOwnerUserAccount,
                            group.item.authorizationRef,
                          )
                        : () => widget.onQuickAddProduct!(
                            inventory[group.productRef]!,
                          ))
                  : null,
              badges: status(
                group.item.priceCents == 0
                    ? '${['免单', 'Complimentary', '免單', 'ฟรี'][widget.language.index]} ${group.waivedQuantity}'
                    : '${t('tableBillPaid')} ${group.paidQuantity} / ${t('tableBillUnpaid')} ${group.unpaidQuantity + (draftFor(group)?.quantity ?? 0)}',
                const Color(0xff216344),
              ),
              leadingBadge: group.quantity == 0
                  ? null
                  : !group.servingKnown
                  ? status(t('billProgressUnknown'), const Color(0xff666666))
                  : status(
                      '${t('billServed')} ${group.served} / ${t('billNotServed')} ${group.remaining}',
                      group.remaining == 0
                          ? const Color(0xff216344)
                          : const Color(0xff994a16),
                    ),
              footer: group.returned == 0 && draftFor(group)?.footer == null
                  ? null
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (group.returned > 0)
                          Text(
                            [
                              if (group.returned > 0)
                                '${t('tableBillRefunded')} ${group.returned}',
                            ].join(' · '),
                            style: const TextStyle(fontSize: 11),
                          ),
                        if (draftFor(group)?.footer != null)
                          draftFor(group)!.footer!,
                      ],
                    ),
            ),
          if (snapshot?.nextAfterOrder != null)
            TextButton(
              onPressed: loading ? null : () => unawaited(load(more: true)),
              child: Text(t('tableBillMore')),
            ),
        ],
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (canRead || widget.headerBuilder != null) ...[
          widget.headerBuilder?.call(
                canRead ? filterDropdown() : const SizedBox(),
              ) ??
              Align(alignment: Alignment.centerRight, child: filterDropdown()),
          const Divider(height: 14, thickness: 1, color: Color(0xffd7e2dc)),
        ],
        if (widget.fillHeight)
          Expanded(child: SingleChildScrollView(child: content))
        else
          content,
        if (canRead && pending != null && paid != null) ...[
          const Divider(height: 12, thickness: 1, color: Color(0xffd7e2dc)),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  key: const ValueKey('table-bill-total'),
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: amountLabel('billTotal'),
                    ),
                    Text(
                      formatCents(
                        paid.totalCents +
                            pending.totalCents +
                            widget.draftCents,
                      ),
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 20),
              Expanded(
                child: Column(
                  children: [
                    amount(
                      'billPaidAmount',
                      paid.totalCents,
                      'table-bill-paid',
                    ),
                    amount(
                      'billUnpaidAmount',
                      pending.totalCents + widget.draftCents,
                      'table-bill-pending',
                    ),
                  ],
                ),
              ),
            ],
          ),
          if ((summary?.buckets['refunded']?.totalCents ?? 0) > 0)
            amount(
              'tableBillRefunded',
              summary!.buckets['refunded']!.totalCents,
              'table-bill-refunded',
            ),
        ],
        const SizedBox(height: 10),
        if (widget.beforeActions != null) widget.beforeActions!,
        if (widget.orderAction != null ||
            widget.primaryAction != null ||
            (canRead && canPay))
          Row(
            children: [
              if (widget.orderAction != null)
                Expanded(
                  child: OutlinedButtonTheme(
                    data: OutlinedButtonThemeData(
                      style: Theme.of(context).outlinedButtonTheme.style?.merge(
                        OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                        ),
                      ),
                    ),
                    child: widget.orderAction!,
                  ),
                ),
              if (widget.orderAction != null &&
                  (widget.primaryAction != null || (canRead && canPay)))
                const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton(
                  key: const ValueKey('table-bill-print'),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                  ),
                  onPressed: printingBill || loading || failed
                      ? null
                      : printBill,
                  child: Text(
                    ['打印', 'Print', '列印', 'พิมพ์'][widget.language.index],
                    maxLines: 1,
                    softWrap: false,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              if (widget.primaryAction != null)
                Expanded(flex: 3, child: widget.primaryAction!)
              else if (canRead && canPay)
                Expanded(
                  flex: 3,
                  child: FilledButton(
                    key: const ValueKey('table-bill-checkout'),
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFFDC2626),
                      foregroundColor: Colors.white,
                      disabledBackgroundColor:
                          !widget.readOnly &&
                              ((pending?.totalCents ?? 0) > 0 ||
                                  widget.recording)
                          ? const Color(0xFFDC2626)
                          : null,
                      disabledForegroundColor:
                          !widget.readOnly &&
                              ((pending?.totalCents ?? 0) > 0 ||
                                  widget.recording)
                          ? Colors.white
                          : null,
                    ),
                    onPressed:
                        !widget.readOnly &&
                            !loading &&
                            !failed &&
                            !checkout &&
                            widget.checkoutAllowed &&
                            !reducing &&
                            pending != null &&
                            pending.orderCount > 0 &&
                            pending.totalCents > 0
                        ? pay
                        : null,
                    child: Text.rich(
                      TextSpan(
                        text:
                            pending != null &&
                                pending.totalCents == 0 &&
                                !widget.recording &&
                                !failed
                            ? t('billSettled')
                            : t('tableCheckoutTitle'),
                        children: [
                          if (pending != null && pending.totalCents > 0)
                            TextSpan(
                              text: '  ¥ ${formatCents(pending.totalCents)}',
                              style: const TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
      ],
    );
  }
}
