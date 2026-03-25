import 'package:flutter/material.dart';

/// A draggable resize handle positioned at an [offset] from the parent Stack's
/// top-left corner.
class ResizeHandle extends StatelessWidget {
  final Alignment alignment;
  final Offset offset;
  final Function(DragUpdateDetails) onDragUpdate;
  final VoidCallback? onDragEnd;
  final Color color;

  const ResizeHandle({
    super.key,
    required this.alignment,
    required this.offset,
    required this.onDragUpdate,
    this.onDragEnd,
    this.color = Colors.blueAccent,
  });

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: offset.dx - 15,
      top: offset.dy - 15,
      child: GestureDetector(
        onPanUpdate: onDragUpdate,
        onPanEnd: (details) {
          if (onDragEnd != null) onDragEnd!();
        },
        behavior: HitTestBehavior.opaque,
        child: Container(
          width: 30, // Larger hit area
          height: 30,
          alignment: Alignment.center,
          color: Colors.transparent,
          child: Container(
            width: 12, // Visual size same as before
            height: 12,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 2),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.3),
                  blurRadius: 4,
                  spreadRadius: 1,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
