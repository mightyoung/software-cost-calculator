import 'dart:math';

import 'package:flutter/material.dart';
import 'package:supplier_core/supplier_core.dart';

import '../../app/theme.dart';

/// Where each object type sits, as fractions of the canvas; laid out so
/// most links run without crossing a box.
const _at = {
  'supplier': Offset(.12, .15),
  'quotation': Offset(.5, .15),
  'product': Offset(.88, .15),
  'contact': Offset(.12, .52),
  'project_item': Offset(.88, .52),
  'inquiry': Offset(.3, .87),
  'project': Offset(.7, .87),
};
const _box = Size(116, 46);

/// The object types and their links; tapping a box selects that type.
class RelationGraph extends StatelessWidget {
  const RelationGraph({
    super.key,
    required this.counts,
    required this.selected,
    required this.onSelect,
  });
  final Map<String, int> counts;
  final String selected;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 300,
    child: LayoutBuilder(
      builder: (context, c) {
        Offset center(String t) =>
            Offset(_at[t]!.dx * c.maxWidth, _at[t]!.dy * c.maxHeight);
        return Stack(
          children: [
            Positioned.fill(
              child: CustomPaint(
                painter: _Links(center: center, selected: selected),
              ),
            ),
            for (final t in ontology.values)
              Positioned(
                left: center(t.name).dx - _box.width / 2,
                top: center(t.name).dy - _box.height / 2,
                width: _box.width,
                height: _box.height,
                child: _Node(
                  label: t.label,
                  count: counts[t.name] ?? 0,
                  on: t.name == selected,
                  onTap: () => onSelect(t.name),
                ),
              ),
          ],
        );
      },
    ),
  );
}

class _Node extends StatelessWidget {
  const _Node({
    required this.label,
    required this.count,
    required this.on,
    required this.onTap,
  });
  final String label;
  final int count;
  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: on ? Tokens.accent : Tokens.surface,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(Tokens.radius),
      side: BorderSide(color: on ? Tokens.accent : Tokens.ruleStrong),
    ),
    child: InkWell(
      borderRadius: BorderRadius.circular(Tokens.radius),
      onTap: onTap,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            label,
            style: TextStyle(
              fontWeight: FontWeight.w600,
              color: on ? Colors.white : Tokens.ink,
            ),
          ),
          Text(
            '$count 条',
            style: TextStyle(
              fontSize: 12,
              fontFeatures: tabular,
              color: on ? Colors.white70 : Tokens.ink3,
            ),
          ),
        ],
      ),
    ),
  );
}

class _Links extends CustomPainter {
  _Links({required this.center, required this.selected});
  final Offset Function(String type) center;
  final String selected;

  /// Where the segment from the box centre toward [to] leaves the box.
  static Offset _edge(Offset from, Offset to) {
    final d = to - from;
    if (d == Offset.zero) return from;
    final t = min(
      d.dx == 0 ? double.infinity : (_box.width / 2 + 4) / d.dx.abs(),
      d.dy == 0 ? double.infinity : (_box.height / 2 + 4) / d.dy.abs(),
    );
    return from + d * t;
  }

  @override
  void paint(Canvas canvas, Size size) {
    for (final l in links) {
      if (l.from == l.to) continue; // "merged into": shown in the field list
      final on = l.from == selected || l.to == selected;
      final paint = Paint()
        ..color = on ? Tokens.accent : Tokens.ruleStrong
        ..strokeWidth = on ? 1.6 : 1
        ..style = PaintingStyle.stroke;
      final a = _edge(center(l.from), center(l.to));
      final b = _edge(center(l.to), center(l.from));
      canvas.drawLine(a, b, paint);
      // Arrow head at the referenced type.
      final dir = (b - a) / (b - a).distance;
      final side = Offset(-dir.dy, dir.dx);
      canvas.drawPath(
        Path()
          ..moveTo(b.dx, b.dy)
          ..lineTo((b - dir * 8 + side * 4).dx, (b - dir * 8 + side * 4).dy)
          ..lineTo((b - dir * 8 - side * 4).dx, (b - dir * 8 - side * 4).dy)
          ..close(),
        paint..style = PaintingStyle.fill,
      );
    }
  }

  @override
  bool shouldRepaint(_Links old) => old.selected != selected;
}
