// Renders the actual generated transparent sources on white for inspection.
@Tags(['screenshot'])
library;

import 'dart:io';
import 'dart:convert';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supplier_app/widgets/app_icon.dart';
import 'package:supplier_app/widgets/icon_paths.g.dart';

void main() {
  testWidgets('generated icon sheets retain visible transparent geometry', (
    tester,
  ) async {
    await tester.runAsync(() async {
      for (var index = 1; index <= 7; index++) {
        final file = File('../../output/imagegen/icons/sheet-$index.png');
        final codec = await ui.instantiateImageCodec(await file.readAsBytes());
        final frame = await codec.getNextFrame();
        final source = frame.image;
        final rgba = await source.toByteData(
          format: ui.ImageByteFormat.rawStraightRgba,
        );
        var visible = 0;
        var transparent = 0;
        for (var pixel = 3; pixel < rgba!.lengthInBytes; pixel += 4) {
          if (rgba.getUint8(pixel) > 127) visible++;
          if (rgba.getUint8(pixel) == 0) transparent++;
        }
        expect(visible, greaterThan(1000));
        expect(transparent, greaterThan(source.width * source.height ~/ 2));
        final recorder = ui.PictureRecorder();
        final canvas = ui.Canvas(recorder)
          ..drawColor(const ui.Color(0xFFFFFFFF), ui.BlendMode.src);
        canvas.drawImage(source, ui.Offset.zero, ui.Paint());
        final picture = recorder.endRecording();
        final rendered = await picture.toImage(source.width, source.height);
        final bytes = await rendered.toByteData(format: ui.ImageByteFormat.png);
        await File(
          '../../output/imagegen/icons/review-$index.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        source.dispose();
        rendered.dispose();
        picture.dispose();
        codec.dispose();
      }
    });
  });

  testWidgets(
    'review all generated vectors at production sizes in both themes',
    (tester) async {
      final loader = FontLoader('Noto Sans SC')
        ..addFont(
          Future.value(
            ByteData.sublistView(
              File('assets/fonts/NotoSansSC-VF.ttf').readAsBytesSync(),
            ),
          ),
        );
      await loader.load();
      final catalog =
          jsonDecode(
                File('../../docs/design/icons/catalog.json').readAsStringSync(),
              )
              as List;
      expect(catalog, hasLength(102));
      tester.view.physicalSize = const Size(1200, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const key = ValueKey('gallery');
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: RepaintBoundary(
            key: key,
            child: Row(
              children: [
                for (final dark in [false, true])
                  Expanded(
                    child: ColoredBox(
                      color: dark ? const Color(0xFF181716) : Colors.white,
                      child: GridView.count(
                        crossAxisCount: 5,
                        childAspectRatio: .85,
                        padding: const EdgeInsets.all(12),
                        children: [
                          for (final item in catalog)
                            Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    for (final size in [16.0, 20.0, 24.0])
                                      Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 5,
                                        ),
                                        child: AppIcon(
                                          businessIconNames[(item['material']
                                                  as List)
                                              .first]!,
                                          size: size,
                                          color: dark
                                              ? const Color(0xFFEEEDEA)
                                              : const Color(0xFF111827),
                                        ),
                                      ),
                                  ],
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  item['label'] as String,
                                  style: TextStyle(
                                    fontFamily: 'Noto Sans SC',
                                    fontSize: 12,
                                    color: dark ? Colors.white : Colors.black,
                                    decoration: TextDecoration.none,
                                  ),
                                ),
                              ],
                            ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(key),
      );
      await tester.runAsync(() async {
        final image = await boundary.toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(
          '../../docs/design/icons/vector-review-v3.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    },
  );
}
