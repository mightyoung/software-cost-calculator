import 'package:flutter/material.dart';

import '../app/theme.dart';

/// A ruled row of labelled figures; replaces metric cards.
class LedgerStrip extends StatelessWidget {
  const LedgerStrip({super.key, required this.cells, this.columns});
  final List<LedgerCell> cells;

  /// Wraps into a grid of this many columns (phones use 2).
  final int? columns;

  @override
  Widget build(BuildContext context) {
    final perRow = columns ?? cells.length;
    final rows = [
      for (var i = 0; i < cells.length; i += perRow)
        cells.sublist(i, (i + perRow).clamp(0, cells.length)),
    ];
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.symmetric(horizontal: BorderSide(color: Tokens.rule)),
      ),
      child: Column(
        children: [
          for (var r = 0; r < rows.length; r++)
            DecoratedBox(
              decoration: BoxDecoration(
                border: r == 0
                    ? null
                    : Border(top: BorderSide(color: Tokens.rule)),
              ),
              child: IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var i = 0; i < perRow; i++)
                      Expanded(
                        child: i < rows[r].length
                            ? Container(
                                padding: EdgeInsets.fromLTRB(
                                  i == 0 ? 0 : 14,
                                  10,
                                  8,
                                  10,
                                ),
                                decoration: BoxDecoration(
                                  border: i == 0
                                      ? null
                                      : Border(
                                          left: BorderSide(color: Tokens.rule),
                                        ),
                                ),
                                child: rows[r][i],
                              )
                            : const SizedBox(),
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class LedgerCell extends StatelessWidget {
  const LedgerCell(this.label, this.value, {super.key, this.note, this.alert});
  final String label, value;
  final String? note, alert;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: TextStyle(fontSize: 12, color: Tokens.ink3)),
      const SizedBox(height: 2),
      Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: value,
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w600,
                fontFeatures: tabular,
              ),
            ),
            if (note != null)
              TextSpan(
                text: '  $note',
                style: TextStyle(fontSize: 12, color: Tokens.ink3),
              ),
          ],
        ),
      ),
      if (alert != null) ...[
        const SizedBox(height: 2),
        HintText(alert!, icon: Icons.warning_amber_rounded),
      ],
    ],
  );
}

enum HintTone { warning, error, info, success }

/// Icon plus words, never colour alone.
class HintTag extends StatelessWidget {
  const HintTag(
    this.text, {
    super.key,
    this.icon = Icons.warning_amber_rounded,
    this.tone = HintTone.warning,
  });
  final String text;
  final IconData icon;
  final HintTone tone;

  @override
  Widget build(BuildContext context) {
    final (fg, bg) = switch (tone) {
      HintTone.error => (Tokens.red, Tokens.redBg),
      HintTone.warning => (Tokens.amber, Tokens.amberBg),
      HintTone.info => (Tokens.accentDeep, Tokens.surface),
      HintTone.success => (Tokens.green, Tokens.greenBg),
    };
    return Semantics(
      label: text,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: fg),
            const SizedBox(width: 4),
            // Narrow cells cut the words rather than overflow.
            Flexible(
              child: Text(
                text,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: fg),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class HintText extends StatelessWidget {
  const HintText(this.text, {super.key, required this.icon});
  final String text;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, size: 13, color: Tokens.amber),
      const SizedBox(width: 4),
      Flexible(
        child: Text(text, style: TextStyle(fontSize: 12, color: Tokens.amber)),
      ),
    ],
  );
}

class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.title,
    required this.body,
    this.actions = const [],
  });
  final String title, body;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(
              body,
              textAlign: TextAlign.center,
              style: TextStyle(color: Tokens.ink2),
            ),
            if (actions.isNotEmpty) ...[
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: actions,
              ),
            ],
          ],
        ),
      ),
    ),
  );
}

/// Code / model text in the monospace role.
class MonoText extends StatelessWidget {
  const MonoText(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: TextStyle(
      fontSize: 12,
      color: Tokens.ink2,
      fontFamily: monoFamily,
      fontFamilyFallback: monoFallback,
    ),
    overflow: TextOverflow.ellipsis,
  );
}

/// Rows a long list shows at first, and adds per "再显示".
const pageSize = 200;

/// Last row of a list cut at [shown] items: says so and loads more.
class MoreRow extends StatelessWidget {
  const MoreRow({super.key, required this.shown, required this.onMore});
  final int shown;
  final VoidCallback onMore;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text('已显示 $shown 条', style: TextStyle(color: Tokens.ink3)),
        const SizedBox(width: 8),
        TextButton(onPressed: onMore, child: const Text('再显示 200 条')),
      ],
    ),
  );
}
