import 'package:flutter/material.dart';

import 'icon_paths.g.dart';

/// Business icons share geometry across themes; the surrounding IconTheme owns
/// their foreground, disabled opacity and size just as it does for [Icon].
class AppIcon extends Icon {
  const AppIcon(
    super.icon, {
    super.key,
    super.size,
    super.color,
    super.semanticLabel,
    super.textDirection,
    super.applyTextScaling,
  });

  static final Map<String, Path> _paths = {};

  @override
  Widget build(BuildContext context) {
    final source = businessIconPaths[icon];
    if (source == null) return super.build(context);

    final theme = IconTheme.of(context);
    final direction = textDirection ?? Directionality.of(context);
    final nominalSize = size ?? theme.size ?? 24;
    final scale = applyTextScaling ?? theme.applyTextScaling ?? false;
    final extent = scale
        ? MediaQuery.textScalerOf(context).scale(nominalSize)
        : nominalSize;
    final foreground = color ?? theme.color!;
    final opacity = theme.opacity ?? 1;
    final path = _paths.putIfAbsent(source, () => _parsePath(source));

    return Semantics(
      label: semanticLabel,
      child: ExcludeSemantics(
        child: SizedBox.square(
          dimension: extent,
          child: Center(
            child: SizedBox.square(
              dimension: extent,
              child: CustomPaint(
                painter: _BusinessIconPainter(
                  path,
                  foreground.withValues(alpha: foreground.a * opacity),
                  icon!.matchTextDirection && direction == TextDirection.rtl,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// The checked-in atlas uses only absolute M/L/Q/C/Z with complete arguments.
// Decode each distinct geometry once, outside the paint hot path.
Path _parsePath(String source) {
  final tokens = RegExp(
    r'[MLQCZ]|-?(?:\d+(?:\.\d*)?|\.\d+)',
  ).allMatches(source).map((match) => match.group(0)!).toList();
  final path = Path();
  var index = 0;
  double number() => double.parse(tokens[index++]);
  while (index < tokens.length) {
    switch (tokens[index++]) {
      case 'M':
        path.moveTo(number(), number());
      case 'L':
        path.lineTo(number(), number());
      case 'Q':
        path.quadraticBezierTo(number(), number(), number(), number());
      case 'C':
        path.cubicTo(
          number(),
          number(),
          number(),
          number(),
          number(),
          number(),
        );
      case 'Z':
        path.close();
      default:
        throw FormatException('Unsupported business icon path', source);
    }
  }
  return path;
}

class _BusinessIconPainter extends CustomPainter {
  const _BusinessIconPainter(this.path, this.color, this.mirrored);

  final Path path;
  final Color color;
  final bool mirrored;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    final side = size.shortestSide;
    canvas.translate((size.width - side) / 2, (size.height - side) / 2);
    canvas.scale(side / 24, side / 24);
    if (mirrored) {
      canvas.translate(24, 0);
      canvas.scale(-1, 1);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.7
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_BusinessIconPainter oldDelegate) =>
      oldDelegate.path != path ||
      oldDelegate.color != color ||
      oldDelegate.mirrored != mirrored;
}
