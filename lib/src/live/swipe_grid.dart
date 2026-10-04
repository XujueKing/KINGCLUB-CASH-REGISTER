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
    this.fillHeight = false,
  });
  final int itemCount, columns;
  final double tileHeight;
  final bool fillHeight;
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
      final dots =
          widget.fillHeight || pages + offset + (widget.hasNext ? 1 : 0) > 1
          ? 24
          : 0;
      final extent = widget.fillHeight
          ? ((box.maxHeight - dots - 12 - (rows - 1) * 10) / rows).clamp(
              widget.tileHeight,
              double.infinity,
            )
          : widget.tileHeight;
      if (widget.fillHeight && !widget.hasPrevious && !widget.hasNext) {
        return Column(
          children: [
            Expanded(
              child: PageView.builder(
                key: ValueKey('swipe-pages'),
                itemCount: pages,
                onPageChanged: (page) => setState(() => localPage = page),
                itemBuilder: (context, page) {
                  final begin = page * capacity;
                  final count = (widget.itemCount - begin).clamp(0, capacity);
                  return GridView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                    physics: const NeverScrollableScrollPhysics(),
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: widget.columns,
                      mainAxisSpacing: 10,
                      crossAxisSpacing: 10,
                      mainAxisExtent: extent,
                    ),
                    itemCount: count,
                    itemBuilder: (context, index) =>
                        widget.itemBuilder(context, begin + index),
                  );
                },
              ),
            ),
            SizedBox(
              height: 24,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (
                    var i = (current - 3).clamp(0, (pages - 7).clamp(0, pages));
                    pages > 1 &&
                        i < pages &&
                        i <
                            (current - 3).clamp(
                                  0,
                                  (pages - 7).clamp(0, pages),
                                ) +
                                7;
                    i++
                  )
                    Container(
                      margin: const EdgeInsets.symmetric(horizontal: 4),
                      width: i == current ? 16 : 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: i == current
                            ? const Color(0xff17483b)
                            : const Color(0xffbacbc2),
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                ],
              ),
            ),
          ],
        );
      }
      final begin = current * capacity;
      final end = (begin + capacity).clamp(0, widget.itemCount);
      return SwipePages(
        reserveIndicatorSpace: widget.fillHeight,
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
            mainAxisExtent: extent,
          ),
          itemCount: end - begin,
          itemBuilder: (context, index) =>
              widget.itemBuilder(context, begin + index),
        ),
      );
    },
  );
}
