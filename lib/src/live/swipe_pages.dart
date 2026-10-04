import 'package:flutter/material.dart';

/// Cursor pages: dots show reached pages plus the next available page.
class SwipePages extends StatefulWidget {
  const SwipePages({
    super.key,
    required this.child,
    required this.page,
    required this.hasNext,
    required this.loading,
    required this.onPrevious,
    required this.onNext,
    this.pageCount,
  });
  final Widget child;
  final int page;
  final int? pageCount;
  final bool hasNext, loading;
  final VoidCallback onPrevious, onNext;
  @override
  State<SwipePages> createState() => _SwipePagesState();
}

class _SwipePagesState extends State<SwipePages> {
  double distance = 0;
  double direction = 1;
  @override
  void didUpdateWidget(covariant SwipePages oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.page != oldWidget.page)
      direction = widget.page > oldWidget.page ? 1 : -1;
  }

  @override
  Widget build(BuildContext context) {
    final count =
        widget.pageCount ?? widget.page + 1 + (widget.hasNext ? 1 : 0);
    final start = (widget.page - 3).clamp(0, (count - 7).clamp(0, count));
    return Column(
      children: [
        Expanded(
          child: GestureDetector(
            key: const ValueKey('swipe-pages'),
            behavior: HitTestBehavior.opaque,
            onHorizontalDragStart: (_) => distance = 0,
            onHorizontalDragUpdate: (event) => distance += event.delta.dx,
            onHorizontalDragEnd: (event) {
              if (widget.loading) return;
              final velocity = event.primaryVelocity ?? 0;
              if ((distance < -60 || velocity < -400) && widget.hasNext) {
                widget.onNext();
              } else if ((distance > 60 || velocity > 400) && widget.page > 0) {
                widget.onPrevious();
              }
            },
            child: ClipRect(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 240),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                transitionBuilder: (child, animation) => SlideTransition(
                  position: Tween<Offset>(
                    begin: Offset(
                      child.key == ValueKey(widget.page)
                          ? direction
                          : -direction,
                      0,
                    ),
                    end: Offset.zero,
                  ).animate(animation),
                  child: child,
                ),
                child: KeyedSubtree(
                  key: ValueKey(widget.page),
                  child: widget.child,
                ),
              ),
            ),
          ),
        ),
        if (count > 1)
          SizedBox(
            height: 24,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var i = start; i < count && i < start + 7; i++)
                  Container(
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    width: i == widget.page ? 16 : 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: i == widget.page
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
}
