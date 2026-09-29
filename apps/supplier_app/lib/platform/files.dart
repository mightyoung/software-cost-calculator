import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

const maxPickedBytes = 20 * 1024 * 1024;
// Exchange snapshots include the entire library and attachments, so use a
// separate disk-streaming budget. Callers can explicitly raise this limit.
const maxExchangeCopyBytes = 2 * 1024 * 1024 * 1024;

/// Picker failures are displayed without starting an import or changing data.
Future<({String name, Uint8List bytes})?> pickBytesForUi(
  BuildContext context,
  List<String> extensions, {
  int maxBytes = maxPickedBytes,
}) async {
  try {
    return await pickBytes(extensions, maxBytes: maxBytes);
  } catch (e) {
    if (context.mounted) toast(context, '无法读取文件：$e');
    return null;
  }
}

Stream<List<int>> boundedFileStream(
  Stream<List<int>> input, {
  required int declaredLength,
  required int maxBytes,
}) async* {
  if (declaredLength < 0 || declaredLength > maxBytes) {
    throw FormatException('文件超过大小上限（${maxBytes ~/ 1048576} MB）');
  }
  var total = 0;
  await for (final chunk in input) {
    total += chunk.length;
    if (total > maxBytes) {
      throw FormatException('文件超过大小上限（${maxBytes ~/ 1048576} MB）');
    }
    yield chunk;
  }
}

/// Opens the system picker and returns the file's bytes, or null if the
/// user cancelled. An empty [extensions] list allows any file.
Future<({String name, Uint8List bytes})?> pickBytes(
  List<String> extensions, {
  int maxBytes = maxPickedBytes,
}) async {
  final file = await FilePicker.pickFile(
    type: extensions.isEmpty ? FileType.any : FileType.custom,
    allowedExtensions: extensions.isEmpty ? null : extensions,
  );
  if (file == null) return null;
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in boundedFileStream(
    file.xFile.openRead(),
    declaredLength: await file.xFile.length(),
    maxBytes: maxBytes,
  )) {
    bytes.add(chunk);
  }
  return (name: file.name, bytes: bytes.takeBytes());
}

/// Opens the system picker and streams the file into [tempDir] so SQLite can
/// ATTACH it (Android gives content URIs, not paths). Returns the temp path.
Future<String?> pickToTemp(
  List<String> extensions,
  Directory tempDir, {
  int maxBytes = maxExchangeCopyBytes,
}) async {
  final file = await FilePicker.pickFile(
    type: FileType.custom,
    allowedExtensions: extensions,
  );
  if (file == null) return null;
  return copyToTemp(
    file.xFile.openRead(),
    tempDir,
    declaredLength: await file.xFile.length(),
    maxBytes: maxBytes,
  );
}

/// Copies picker content without materializing the full exchange in memory.
/// The returned file owns a unique parent directory, removed on failure.
Future<String> copyToTemp(
  Stream<List<int>> input,
  Directory tempDir, {
  required int declaredLength,
  int maxBytes = maxExchangeCopyBytes,
}) async {
  await tempDir.create(recursive: true);
  final dir = await tempDir.createTemp('import-');
  final target = File('${dir.path}/import.siq');
  final sink = target.openWrite();
  try {
    await sink.addStream(
      boundedFileStream(
        input,
        declaredLength: declaredLength,
        maxBytes: maxBytes,
      ),
    );
    await sink.close();
    return target.path;
  } catch (_) {
    try {
      await sink.close();
    } catch (_) {
      // addStream can already have closed the sink after its input failed.
    }
    await dir.delete(recursive: true);
    rethrow;
  }
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
      ..showSnackBar(SnackBar(content: Text(message)));

String today() => DateTime.now().toIso8601String().substring(0, 10);
