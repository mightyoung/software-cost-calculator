import 'dart:math';

import 'package:flutter/material.dart';

import '../app/format.dart';
import '../app/theme.dart';

class TrendPoint {
  const TrendPoint(
    this.day,
    this.price, {
    this.usable = true,
    this.lowest = false,
    this.awarded = false,
  });

  /// Quote date, YYYY-MM-DD.
  final String day;

  /// Exact decimal price in one comparable basis.
  final String price;
  final bool usable, lowest, awarded;
}

/// Quotes of one material over time: a line through every quote, the
/// lowest usable price in green, awards ringed, unusable quotes hollow.
class PriceTrend extends StatelessWidget {
  const PriceTrend({super.key, required this.points, this.height = 150});
  final List<TrendPoint> points;
  final double height;

  @override
  Widget build(BuildContext context) {
    final sorted = [...points]..sort((a, b) => a.day.compareTo(b.day));
    final prices = [for (final p in sorted) double.parse(p.price)];
    final low = prices.reduce(min), high = prices.reduce(max);
    final label = TextStyle(fontSize: 12, color: Tokens.ink3);
    return SizedBox(
      height: height,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(money('$high'), style: label),
              Text(money('$low'), style: label),
              const SizedBox(height: 16),
            ],
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              children: [
                Expanded(
                  child: CustomPaint(
                    size: Size.infinite,
                    painter: _TrendPainter(sorted, prices, low, high),
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(sorted.first.day, style: label),
                    if (sorted.last.day != sorted.first.day)
                      Text(sorted.last.day, style: label),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TrendPainter extends CustomPainter {
  _TrendPainter(this.points, this.prices, this.low, this.high);
  final List<TrendPoint> points;
  final List<double> prices;
  final double low, high;

  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()
      ..color = Tokens.rule
      ..strokeWidth = 1;
    canvas
      ..drawLine(Offset.zero, Offset(size.width, 0), grid)
      ..drawLine(Offset(0, size.height), Offset(size.width, size.height), grid);
    // Dates spread by real time, so gaps between quotes show.
    final days = [for (final p in points) DateTime.parse(p.day)];
    final span = days.last.difference(days.first).inDays;
    Offset at(int i) => Offset(
      span == 0
          ? size.width / 2
          : size.width * days[i].difference(days.first).inDays / span,
      high == low
          ? size.height / 2
          : size.height * (1 - (prices[i] - low) / (high - low)) * 0.84 +
                size.height * 0.08,
    );
    final line = Path()..moveTo(at(0).dx, at(0).dy);
    for (var i = 1; i < points.length; i++) {
      line.lineTo(at(i).dx, at(i).dy);
    }
    canvas.drawPath(
      line,
      Paint()
        ..color = Tokens.ruleStrong
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
    for (final (i, p) in points.indexed) {
      final o = at(i);
      if (p.awarded) {
        canvas.drawCircle(
          o,
          7,
          Paint()
            ..color = Tokens.green
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5,
        );
      }
      canvas.drawCircle(
        o,
        4,
        Paint()
          ..color = p.lowest
              ? Tokens.green
              : (p.usable ? Tokens.accent : Tokens.ink3)
          ..style = p.usable ? PaintingStyle.fill : PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    }
  }

  @override
  bool shouldRepaint(_TrendPainter old) => old.points != points;
}
