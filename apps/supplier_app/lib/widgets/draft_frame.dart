import 'package:flutter/material.dart';

import '../app/theme.dart';

/// Dashed border = "proposal, not yet confirmed" (AI matches, previews).
class DraftFrame extends StatelessWidget {
  const DraftFrame({
    super.key,
    required this.child,
    this.color = Tokens.accent,
  });
  final Widget child;
  final Color color;

  @override
  Widget build(BuildContext context) => CustomPaint(
    foregroundPainter: _Dashes(color),
    child: ClipRRect(
      borderRadius: BorderRadius.circular(Tokens.radius),
      child: child,
    ),
  );
}

class _Dashes extends CustomPainter {
  _Dashes(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          Offset.zero & size,
          const Radius.circular(Tokens.radius),
        ).deflate(0.5),
      );
    for (final metric in path.computeMetrics()) {
      for (var d = 0.0; d < metric.length; d += 9) {
        canvas.drawPath(metric.extractPath(d, d + 5), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_Dashes old) => old.color != color;
}
