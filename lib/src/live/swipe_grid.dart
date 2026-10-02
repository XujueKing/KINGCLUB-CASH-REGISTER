import 'package:flutter/material.dart';

import 'swipe_pages.dart';

/// Fits each local page to the viewport, then requests another server page.
class SwipeGrid extends StatefulWidget {
  const SwipeGrid({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    required this.columns,
    required this.tileHeight,
    required this.loading,
    required this.hasPrevious,
    required this.hasNext,
    required this.onPrevious,
    required this.onNext,
  });
  final int itemCount, columns;
  final double tileHeight;
  final IndexedWidgetBuilder itemBuilder;
  final bool loading, hasPrevious, hasNext;
  final VoidCallback onPrevious, onNext;
  @override
  State<SwipeGrid> createState() => _SwipeGridState();
}

class _SwipeGridState extends State<SwipeGrid> {
  int localPage = 0;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final rows = ((box.maxHeight - 36 + 10) / (widget.tileHeight + 10))
          .floor()
          .clamp(1, 100);
      final capacity = rows * widget.columns;
      final pages = (widget.itemCount / capacity).ceil().clamp(1, 10000);
      final current = localPage.clamp(0, pages - 1);
      final offset = widget.hasPrevious ? 1 : 0;
      final begin = current * capacity;
      final end = (begin + capacity).clamp(0, widget.itemCount);
      return SwipePages(
        page: current + offset,
        pageCount: pages + offset + (widget.hasNext ? 1 : 0),
        hasNext: current < pages - 1 || widget.hasNext,
        loading: widget.loading,
        onPrevious: () {
          if (current > 0) {
            setState(() => localPage = current - 1);
          } else {
            widget.onPrevious();
          }
        },
        onNext: () {
          if (current < pages - 1) {
            setState(() => localPage = current + 1);
          } else {
            widget.onNext();
          }
        },
        child: GridView.builder(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: widget.columns,
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            mainAxisExtent: widget.tileHeight,
          ),
          itemCount: end - begin,
          itemBuilder: (context, index) =>
              widget.itemBuilder(context, begin + index),
        ),
      );
    },
  );
}
