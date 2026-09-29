import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supplier_app/app/theme.dart';
import 'package:supplier_app/features/data_center/relation_graph.dart';

double contrast(Color a, Color b) {
  final first = a.computeLuminance();
  final second = b.computeLuminance();
  return (math.max(first, second) + .05) / (math.min(first, second) + .05);
}

void main() {
  final original = Tokens.dark;
  tearDown(() => Tokens.dark = original);

  for (final dark in [false, true]) {
    test('workspace text and action contrast, dark=$dark', () {
      Tokens.dark = dark;
      final theme = buildTheme();
      final scheme = theme.colorScheme;
      final pairs = <String, (Color, Color)>{
        for (final background in [Tokens.canvas, Tokens.surface, Tokens.sunken])
          for (final text in [Tokens.ink, Tokens.ink2, Tokens.ink3])
            '$text on $background': (text, background),
        'navigation': (Tokens.navInk, Tokens.nav),
        'navigation caption': (Tokens.navInk3, Tokens.navHover),
        'primary button': (scheme.onPrimary, scheme.primary),
        'secondary button': (scheme.onSecondary, scheme.secondary),
        'error button': (scheme.onError, scheme.error),
        'selection': (scheme.onPrimaryContainer, scheme.primaryContainer),
        'warning': (Tokens.amber, Tokens.amberBg),
        'error': (Tokens.red, Tokens.redBg),
        'success': (Tokens.green, Tokens.greenBg),
        'snackbar action': (
          theme.snackBarTheme.actionTextColor!,
          theme.snackBarTheme.backgroundColor!,
        ),
      };
      for (final entry in pairs.entries) {
        expect(
          contrast(entry.value.$1, entry.value.$2),
          greaterThanOrEqualTo(4.5),
          reason: entry.key,
        );
      }
      expect(theme.inputDecorationTheme.fillColor, scheme.surface);
      expect(theme.dialogTheme.backgroundColor, scheme.surface);
      expect(theme.scaffoldBackgroundColor, Tokens.canvas);
      expect(theme.textTheme.bodyMedium!.fontSize, 13);
      expect(theme.textTheme.bodySmall!.fontSize, 12);
      expect(
        theme.textTheme.bodyMedium!.fontFamilyFallback,
        contains('PingFang SC'),
      );
    });
  }

  testWidgets('dark workspace and ontology share neutral working surfaces', (
    tester,
  ) async {
    Tokens.dark = true;
    late RelationGraphPalette palette;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: Builder(
          builder: (context) {
            palette = RelationGraphPalette.of(context);
            return const Scaffold(body: Text('工作区'));
          },
        ),
      ),
    );
    expect(palette.canvas, Tokens.canvas);
    expect(palette.surface, Tokens.surface);
    expect(palette.ink, Tokens.ink);
    expect(palette.border, Tokens.ruleStrong);
  });
}
