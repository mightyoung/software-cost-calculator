import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../app/motion.dart';

/// Opens the system picker and returns the file's bytes, or null if the
/// user cancelled. An empty [extensions] list allows any file.
Future<({String name, Uint8List bytes})?> pickBytes(
  List<String> extensions,
) async {
  final file = await FilePicker.pickFile(
    type: extensions.isEmpty ? FileType.any : FileType.custom,
    allowedExtensions: extensions.isEmpty ? null : extensions,
  );
  if (file == null) return null;
  return (name: file.name, bytes: await file.xFile.readAsBytes());
}

/// Opens the system picker and streams the file into [tempDir] so SQLite can
/// ATTACH it (Android gives content URIs, not paths). Returns the temp path.
Future<String?> pickToTemp(List<String> extensions, Directory tempDir) async {
  final file = await FilePicker.pickFile(
    type: FileType.custom,
    allowedExtensions: extensions,
  );
  if (file == null) return null;
  await tempDir.create(recursive: true);
  final target = File(
    '${tempDir.path}/import-${DateTime.now().millisecondsSinceEpoch}.siq',
  );
  final sink = target.openWrite();
  await sink.addStream(file.xFile.openRead());
  await sink.close();
  return target.path;
}

/// System "save as" (desktop) or document creation (Android). Returns false
/// if the user cancelled.
Future<bool> saveBytes(
  String fileName,
  Uint8List bytes, {
  List<String>? extensions,
}) async {
  final uri = await FilePicker.saveFile(
    fileName: fileName,
    bytes: bytes,
    type: extensions == null ? FileType.any : FileType.custom,
    allowedExtensions: extensions,
  );
  return uri != null;
}

void toast(BuildContext context, String message) =>
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message)),
        snackBarAnimationStyle: AppMotion.reduced(context)
            ? AnimationStyle.noAnimation
            : const AnimationStyle(
                duration: Duration(milliseconds: 160),
                reverseDuration: Duration(milliseconds: 120),
              ),
      );

String today() => DateTime.now().toIso8601String().substring(0, 10);
