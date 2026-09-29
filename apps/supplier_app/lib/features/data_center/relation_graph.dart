import 'dart:math';
import 'package:flutter/material.dart';
import 'package:supplier_core/supplier_core.dart';
import '../../widgets/app_icon.dart';

/// Immutable colours for the graph painters, the global design tokens
/// (DESIGN.md §3) resolved once per brightness. In the dark theme the
/// selected object is marked light grey; page actions stay blue.
class RelationGraphPalette {
  const RelationGraphPalette(
    this.canvas,
    this.surface,
    this.ink,
    this.muted,
    this.border,
    this.accent,
    this.tint,
  );
  factory RelationGraphPalette.of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
      ? const RelationGraphPalette(
          Color(0xFF131211),
          Color(0xFF181716),
          Color(0xFFEEEDEA),
          Color(0xFFAAA7A3),
          Color(0xFF45423E),
          Color(0xFFEEEDEA),
          Color(0xFF302E2B),
        )
      : const RelationGraphPalette(
          Color(0xFFF7F8FA),
          Color(0xFFFFFFFF),
          Color(0xFF111827),
          Color(0xFF636C7E),
          Color(0xFFC3CAD6),
          Color(0xFF2458D3),
          Color(0xFFE8EFFF),
        );
  final Color canvas, surface, ink, muted, border, accent, tint;
}

const _canvas = Size(1100, 660);
const _box = Size(180, 72);
const _at = <String, Offset>{
  'supplier': Offset(150, 130),
  'contact': Offset(150, 330),
  'quotation': Offset(550, 130),
  'product': Offset(950, 130),
  'product_param': Offset(950, 330),
  'project_item': Offset(750, 330),
  'project': Offset(750, 550),
  'inquiry': Offset(350, 330),
  'spec_request': Offset(550, 550),
  'spec_item': Offset(350, 550),
  'spec_response': Offset(150, 550),
};
const _icons = <String, IconData>{
  'supplier': Icons.factory_outlined,
  'contact': Icons.contacts_outlined,
  'quotation': Icons.manage_search,
  'product': Icons.inventory_2_outlined,
  'product_param': Icons.rule,
  'project_item': Icons.table_rows_outlined,
  'project': Icons.folder_copy_outlined,
  'inquiry': Icons.request_quote_outlined,
  'spec_request': Icons.description_outlined,
  'spec_item': Icons.playlist_add_check,
  'spec_response': Icons.fact_check_outlined,
};

class RelationGraph extends StatefulWidget {
  const RelationGraph({
    super.key,
    required this.counts,
    required this.selected,
    required this.onSelect,
    this.height = 560,
  });
  final Map<String, int> counts;
  final String selected;
  final ValueChanged<String> onSelect;
  final double height;
  @override
  State<RelationGraph> createState() => _RelationGraphState();
}

class _RelationGraphState extends State<RelationGraph>
    with SingleTickerProviderStateMixin {
  final _transform = TransformationController();
  final _search = TextEditingController();
  late final AnimationController _motion = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
  )..addListener(_tick);
  Animation<Matrix4>? _flight;
  Size _viewport = Size.zero;
  bool _all = false, _reduce = false;
  String _query = '';
  String? _edge;
  bool get _quiet =>
      _reduce ||
      MediaQuery.disableAnimationsOf(context) ||
      View.of(context).platformDispatcher.accessibilityFeatures.reduceMotion;
  void _tick() {
    if (_flight != null) _transform.value = _flight!.value;
  }

  @override
  void dispose() {
    _motion.dispose();
    _transform.dispose();
    _search.dispose();
    super.dispose();
  }

  void _move(Matrix4 target, {bool animate = true}) {
    _motion.stop();
    if (_quiet || !animate) {
      _transform.value = target;
      return;
    }
    _flight = Matrix4Tween(
      begin: _transform.value.clone(),
      end: target,
    ).animate(CurvedAnimation(parent: _motion, curve: Curves.easeOutCubic));
    _motion.forward(from: 0);
  }

  Matrix4 _matrix(double scale, Offset center) => Matrix4.identity()
    ..translateByDouble(
      _viewport.width / 2 - center.dx * scale,
      _viewport.height / 2 - center.dy * scale,
      0,
      1,
    )
    ..scaleByDouble(scale, scale, 1, 1);
  void _fit({bool animate = true, bool readable = false}) {
    if (_viewport.isEmpty) return;
    final scale = min(
      _viewport.width / _canvas.width,
      _viewport.height / _canvas.height,
    ).clamp(readable ? .75 : .2, 1.0);
    _move(_matrix(scale, _canvas.center(Offset.zero)), animate: animate);
  }

  void _focus(String type) {
    final center = _at[type];
    if (center == null || _viewport.isEmpty) return;
    _move(
      _matrix(
        max(.85, _transform.value.getMaxScaleOnAxis()).clamp(.2, 2.0),
        center,
      ),
    );
  }

  void _zoom(double factor) {
    final scale = (_transform.value.getMaxScaleOnAxis() * factor).clamp(
      .2,
      2.0,
    );
    _move(_matrix(scale, _transform.toScene(_viewport.center(Offset.zero))));
  }

  void _pick(String type, {bool focus = false}) {
    setState(() {
      _edge = null;
      _query = '';
      _search.clear();
    });
    widget.onSelect(type);
    if (focus) _focus(type);
  }

  @override
  Widget build(BuildContext context) {
    final p = RelationGraphPalette.of(context);
    final visible = links
        .where(
          (l) => _all || l.from == widget.selected || l.to == widget.selected,
        )
        .toList();
    final nearby = {
      widget.selected,
      for (final l in visible) ...[l.from, l.to],
    };
    final results = ontology.values.where(
      (t) =>
          t.label.contains(_query) ||
          t.name.toLowerCase().contains(_query.toLowerCase()),
    );
    return SizedBox(
      height: widget.height,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: p.canvas,
          border: Border.all(color: p.border),
          borderRadius: BorderRadius.circular(12),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Column(
            children: [
              Container(
                color: p.surface,
                padding: const EdgeInsets.all(12),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    SizedBox(
                      width: 210,
                      child: TextField(
                        controller: _search,
                        decoration: const InputDecoration(
                          isDense: true,
                          hintText: '查找对象 · 中文 / 英文',
                          prefixIcon: AppIcon(Icons.search, size: 18),
                        ),
                        onChanged: (value) =>
                            setState(() => _query = value.trim()),
                      ),
                    ),
                    ChoiceChip(
                      label: const Text('一跳关系'),
                      selected: !_all,
                      onSelected: (_) => setState(() {
                        _all = false;
                        _edge = null;
                      }),
                    ),
                    ChoiceChip(
                      label: const Text('全部关系'),
                      selected: _all,
                      onSelected: (_) => setState(() {
                        _all = true;
                        _edge = null;
                      }),
                    ),
                    FilterChip(
                      label: const Text('减少动效'),
                      selected: _reduce,
                      onSelected: (value) {
                        _motion.stop();
                        setState(() => _reduce = value);
                      },
                    ),
                  ],
                ),
              ),
              if (_query.isNotEmpty)
                Container(
                  width: double.infinity,
                  color: p.surface,
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                  child: results.isEmpty
                      ? const Text('没有匹配对象，请尝试物料或 product')
                      : Wrap(
                          spacing: 8,
                          children: [
                            for (final t in results)
                              ActionChip(
                                label: Text('${t.label} · ${t.name}'),
                                onPressed: () => _pick(t.name, focus: true),
                              ),
                          ],
                        ),
                ),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final next = Size(
                      constraints.maxWidth,
                      constraints.maxHeight,
                    );
                    if (_viewport != next) {
                      _viewport = next;
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (mounted) _fit(animate: false, readable: true);
                      });
                    }
                    return Stack(
                      children: [
                        Positioned.fill(
                          child: InteractiveViewer(
                            key: const ValueKey('relation-viewport'),
                            transformationController: _transform,
                            constrained: false,
                            minScale: .2,
                            maxScale: 2,
                            boundaryMargin: const EdgeInsets.all(1100),
                            onInteractionStart: (_) => _motion.stop(),
                            child: SizedBox(
                              width: _canvas.width,
                              height: _canvas.height,
                              child: Stack(
                                children: [
                                  Positioned.fill(
                                    child: CustomPaint(
                                      painter: _Links(
                                        selected: widget.selected,
                                        all: _all,
                                        edge: _edge,
                                        accent: p.accent,
                                        line: p.border,
                                        background: p.canvas,
                                        ink: p.ink,
                                      ),
                                    ),
                                  ),
                                  for (final t in ontology.values)
                                    Positioned(
                                      left: _at[t.name]!.dx - _box.width / 2,
                                      top: _at[t.name]!.dy - _box.height / 2,
                                      width: _box.width,
                                      height: _box.height,
                                      child: AnimatedOpacity(
                                        duration: Duration(
                                          milliseconds: _quiet ? 0 : 140,
                                        ),
                                        opacity: nearby.contains(t.name)
                                            ? 1
                                            : .62,
                                        child: _Node(
                                          type: t,
                                          count: widget.counts[t.name] ?? 0,
                                          selected: t.name == widget.selected,
                                          palette: p,
                                          onFocus: () => _focus(t.name),
                                          onTap: () => _pick(t.name),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        Positioned(
                          left: 12,
                          bottom: 12,
                          child: Material(
                            color: p.surface,
                            borderRadius: BorderRadius.circular(8),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  tooltip: '放大',
                                  onPressed: () => _zoom(1.25),
                                  icon: const AppIcon(Icons.add, size: 18),
                                ),
                                IconButton(
                                  tooltip: '缩小',
                                  onPressed: () => _zoom(.8),
                                  icon: const AppIcon(Icons.remove, size: 18),
                                ),
                                ValueListenableBuilder<Matrix4>(
                                  valueListenable: _transform,
                                  builder: (_, m, _) => SizedBox(
                                    width: 46,
                                    child: Text(
                                      '${(m.getMaxScaleOnAxis() * 100).round()}%',
                                      key: const ValueKey('graph-zoom'),
                                      textAlign: TextAlign.center,
                                    ),
                                  ),
                                ),
                                IconButton(
                                  tooltip: '适应画布',
                                  onPressed: _fit,
                                  icon: const AppIcon(
                                    Icons.fit_screen,
                                    size: 18,
                                  ),
                                ),
                                IconButton(
                                  tooltip: '聚焦选中对象',
                                  onPressed: () => _focus(widget.selected),
                                  icon: const AppIcon(
                                    Icons.center_focus_strong,
                                    size: 18,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
              Container(
                color: p.surface,
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '引用方向 → 被引用对象 · ${visible.length} 条关系',
                      style: TextStyle(fontSize: 12, color: p.muted),
                    ),
                    const SizedBox(height: 6),
                    SizedBox(
                      height: 38,
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            for (final l in visible)
                              Padding(
                                padding: const EdgeInsets.only(right: 6),
                                child: ChoiceChip(
                                  key: ValueKey('link-${l.name}'),
                                  label: Text(
                                    '${ontology[l.from]!.label} · ${ontology[l.from]!.field(l.field)!.label} (${l.field}) → ${ontology[l.to]!.label} · ${l.many ? '多对多' : '多对一'}',
                                  ),
                                  selected: _edge == l.name,
                                  onSelected: (_) =>
                                      setState(() => _edge = l.name),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Node extends StatelessWidget {
  const _Node({
    required this.type,
    required this.count,
    required this.selected,
    required this.palette,
    required this.onTap,
    required this.onFocus,
  });
  final ObjectType type;
  final int count;
  final bool selected;
  final RelationGraphPalette palette;
  final VoidCallback onTap, onFocus;
  @override
  Widget build(BuildContext context) => Semantics(
    selected: selected,
    button: true,
    label: '${type.label}，$count 条',
    child: Material(
      color: selected ? palette.tint : palette.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(
          color: selected ? palette.accent : palette.border,
          width: selected ? 1.5 : 1,
        ),
      ),
      child: InkWell(
        key: ValueKey('node-${type.name}'),
        onTap: onTap,
        onFocusChange: (focus) {
          if (focus &&
              FocusManager.instance.highlightMode ==
                  FocusHighlightMode.traditional) {
            onFocus();
          }
        },
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Row(
            children: [
              AppIcon(
                _icons[type.name],
                color: selected ? palette.accent : palette.muted,
                size: 24,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      type.label,
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                        color: palette.ink,
                      ),
                    ),
                    Text(
                      '$count 条',
                      style: TextStyle(fontSize: 14, color: palette.muted),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _Links extends CustomPainter {
  _Links({
    required this.selected,
    required this.all,
    required this.edge,
    required this.accent,
    required this.line,
    required this.background,
    required this.ink,
  });
  final String selected;
  final bool all;
  final String? edge;
  final Color accent, line, background, ink;
  static Offset _boundary(Offset from, Offset to) {
    final d = to - from;
    final scale = min(
      d.dx == 0 ? double.infinity : (_box.width / 2 + 5) / d.dx.abs(),
      d.dy == 0 ? double.infinity : (_box.height / 2 + 5) / d.dy.abs(),
    );
    return from + d * scale;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final groups = <String, List<LinkType>>{};
    for (final l in links) {
      groups.putIfAbsent('${l.from}:${l.to}', () => []).add(l);
    }
    for (final l in links) {
      final related = l.from == selected || l.to == selected;
      if (!all && !related) continue;
      final a = _at[l.from]!, b = _at[l.to]!;
      final siblings = groups['${l.from}:${l.to}']!;
      final bend = (siblings.indexOf(l) - (siblings.length - 1) / 2) * 42;
      final path = Path();
      if (a == b) {
        path.moveTo(a.dx - 40, a.dy - _box.height / 2 - 5);
        path.cubicTo(
          a.dx - 80,
          a.dy - 105,
          a.dx + 80,
          a.dy - 105,
          a.dx + 40,
          a.dy - _box.height / 2 - 5,
        );
      } else if (a.dx == b.dx && (a.dy - b.dy).abs() > 250) {
        // Route around intervening nodes, not through their labels.
        final x = a.dx - _box.width / 2 - 5;
        final corridor = x - 55 - bend;
        path.moveTo(x, a.dy);
        path.cubicTo(corridor, a.dy, corridor, b.dy, x, b.dy);
      } else {
        final start = _boundary(a, b), end = _boundary(b, a), d = end - start;
        final normal = Offset(-d.dy, d.dx) / d.distance;
        path.moveTo(start.dx, start.dy);
        final mid = (start + end) / 2 + normal * bend;
        path.quadraticBezierTo(mid.dx, mid.dy, end.dx, end.dy);
      }
      final active = edge == l.name;
      final color = active || (edge == null && related) ? accent : line;
      canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = active ? 2.2 : 1.2,
      );
      final metric = path.computeMetrics().first;
      final tip = metric.getTangentForOffset(metric.length)!;
      final dir = tip.vector,
          side = Offset(-dir.dy, dir.dx),
          end = tip.position;
      final left = end - dir * 8 + side * 4, right = end - dir * 8 - side * 4;
      canvas.drawPath(
        Path()
          ..moveTo(end.dx, end.dy)
          ..lineTo(left.dx, left.dy)
          ..lineTo(right.dx, right.dy)
          ..close(),
        Paint()..color = color,
      );
      if (active && metric.length > 180) {
        final mid = metric.getTangentForOffset(metric.length / 2)!.position;
        final text = TextPainter(
          text: TextSpan(
            text:
                '${ontology[l.from]!.field(l.field)!.label} · ${l.many ? '多对多' : '多对一'}',
            style: TextStyle(fontSize: 15, color: ink),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        final rect = Rect.fromCenter(
          center: mid,
          width: text.width + 12,
          height: text.height + 8,
        );
        canvas.drawRRect(
          RRect.fromRectAndRadius(rect, const Radius.circular(4)),
          Paint()..color = background,
        );
        text.paint(canvas, mid - Offset(text.width / 2, text.height / 2));
      }
    }
  }

  @override
  bool shouldRepaint(_Links old) =>
      old.selected != selected ||
      old.all != all ||
      old.edge != edge ||
      old.accent != accent ||
      old.line != line ||
      old.background != background ||
      old.ink != ink;
}
