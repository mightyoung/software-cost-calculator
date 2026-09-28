import 'dart:io';
import 'dart:typed_data';

import 'package:supplier_core/supplier_core.dart';

/// System Chinese fonts to embed in PDFs, most suitable first. Nothing is
/// bundled with the app: the PDF writer keeps only the glyphs used.
const _candidates = [
  // Windows
  r'C:\Windows\Fonts\msyh.ttc',
  r'C:\Windows\Fonts\simhei.ttf',
  r'C:\Windows\Fonts\simsun.ttc',
  // macOS
  '/System/Library/Fonts/PingFang.ttc',
  '/System/Library/Fonts/STHeiti Light.ttc',
  '/System/Library/Fonts/Hiragino Sans GB.ttc',
  '/System/Library/Fonts/Supplemental/Arial Unicode.ttf',
  // Android
  '/system/fonts/NotoSansSC-Regular.otf',
  '/system/fonts/DroidSansFallbackFull.ttf',
  '/system/fonts/DroidSansFallback.ttf',
  '/system/fonts/NotoSansCJK-Regular.ttc',
];

Uint8List? _cached;

/// The first system font the PDF writer can embed; null when none is.
Future<Uint8List?> cjkFont() async {
  if (_cached != null) return _cached;
  for (final path in _candidates) {
    final file = File(path);
    if (!file.existsSync()) continue;
    try {
      if (embeddableFont(await file.readAsBytes()) case final font?) {
        return _cached = font;
      }
    } on FileSystemException {
      continue;
    }
  }
  return null;
}
