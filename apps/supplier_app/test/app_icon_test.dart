import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supplier_app/widgets/app_icon.dart';
import 'package:supplier_app/widgets/icon_paths.g.dart';

void main() {
  const boundaryKey = ValueKey('icon-boundary');

  test('every handwritten Material icon reference is covered by the atlas', () {
    final pattern = RegExp(r'\bIcons\.(\w+)');
    for (final file in Directory(
      'lib',
    ).listSync(recursive: true).whereType<File>()) {
      if (!file.path.endsWith('.dart') || file.path.endsWith('.g.dart')) {
        continue;
      }
      for (final match in pattern.allMatches(file.readAsStringSync())) {
        final name = match.group(1)!;
        expect(
          businessIconNames,
          contains(name),
          reason: '${file.path}: $name',
        );
        expect(businessIconPaths, contains(businessIconNames[name]));
      }
    }
  });

  Future<Uint8List> pixels(
    WidgetTester tester,
    Widget icon, {
    IconThemeData theme = const IconThemeData(size: 48, color: Colors.black),
    TextDirection direction = TextDirection.ltr,
    double textScale = 1,
  }) async {
    await tester.pumpWidget(
      MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
        child: Directionality(
          textDirection: direction,
          child: Center(
            child: RepaintBoundary(
              key: boundaryKey,
              child: IconTheme(data: theme, child: icon),
            ),
          ),
        ),
      ),
    );
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(boundaryKey),
    );
    return (await tester.runAsync(() async {
      final image = await boundary.toImage();
      final data = await image.toByteData(
        format: ui.ImageByteFormat.rawStraightRgba,
      );
      image.dispose();
      return data!.buffer.asUint8List();
    }))!;
  }

  testWidgets(
    'inherits theme color and multiplies foreground alpha by opacity',
    (tester) async {
      final bytes = await pixels(
        tester,
        const AppIcon(Icons.add),
        theme: const IconThemeData(
          size: 48,
          color: Color(0x800066cc),
          opacity: .5,
        ),
      );
      var strongest = 0;
      for (var i = 3; i < bytes.length; i += 4) {
        if (bytes[i] > bytes[strongest + 3]) strongest = i - 3;
      }
      expect(bytes[strongest + 3], closeTo(64, 1));
      expect(bytes[strongest], 0);
      expect(bytes[strongest + 1], closeTo(102, 3));
      expect(bytes[strongest + 2], closeTo(204, 3));
      expect(find.byIcon(Icons.add), findsOneWidget);
    },
  );

  testWidgets(
    'explicit size/color, semantics and inherited text scaling work',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final bytes = await pixels(
        tester,
        const AppIcon(
          Icons.add,
          size: 20,
          color: Colors.red,
          semanticLabel: '添加物料',
        ),
        theme: const IconThemeData(
          size: 48,
          color: Colors.blue,
          applyTextScaling: true,
        ),
        textScale: 1.5,
      );
      expect(tester.getSize(find.byKey(boundaryKey)), const Size.square(30));
      expect(find.bySemanticsLabel('添加物料'), findsOneWidget);
      expect(
        [
          for (var i = 0; i < bytes.length; i += 4) bytes[i],
        ].reduce((a, b) => a > b ? a : b),
        255,
      );
      semantics.dispose();
    },
  );

  testWidgets('directional arrows mirror in RTL; explicit direction wins', (
    tester,
  ) async {
    final ltr = await pixels(tester, const AppIcon(Icons.arrow_back));
    final rtl = await pixels(
      tester,
      const AppIcon(Icons.arrow_back),
      direction: TextDirection.rtl,
    );
    expect(ltr, isNot(orderedEquals(rtl)));
    for (var y = 0; y < 48; y++) {
      for (var x = 0; x < 48; x++) {
        expect(
          rtl[(y * 48 + x) * 4 + 3],
          // Opposite raster directions can vary edge antialiasing slightly.
          closeTo(ltr[(y * 48 + 47 - x) * 4 + 3], 8),
        );
      }
    }
    final override = await pixels(
      tester,
      const AppIcon(Icons.arrow_back, textDirection: TextDirection.ltr),
      direction: TextDirection.rtl,
    );
    expect(override, orderedEquals(ltr));
  });

  testWidgets('every atlas path paints visible geometry without exceptions', (
    tester,
  ) async {
    expect(businessIconPaths, isNotEmpty);
    for (final icon in businessIconPaths.keys) {
      final bytes = await pixels(tester, AppIcon(icon));
      expect(
        [for (var i = 3; i < bytes.length; i += 4) bytes[i]].any((a) => a > 0),
        isTrue,
        reason: 'Empty icon: $icon',
      );
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('unknown and null icons retain the standard Icon fallback', (
    tester,
  ) async {
    const unknown = IconData(0x41, fontFamily: 'test-font');
    await pixels(tester, const AppIcon(unknown));
    expect(find.byType(RichText), findsOneWidget);
    final blank = await pixels(tester, const AppIcon(null));
    expect(blank.every((byte) => byte == 0), isTrue);
    expect(tester.takeException(), isNull);
  });
}
