import 'dart:io';

/// Retains the initiating failure when cleanup also encounters an I/O failure.
final class FileWriteFailure implements Exception {
  FileWriteFailure(
    this.primary,
    this.primaryStack,
    List<({Object error, StackTrace stack})> cleanup,
  ) : cleanup = List.unmodifiable(cleanup);
  final Object primary;
  final StackTrace primaryStack;
  final List<({Object error, StackTrace stack})> cleanup;
  @override
  String toString() => 'Write failed: $primary; cleanup failures: $cleanup';
}

/// Host experiment only; source ownership must prevent in-place modification.
final class FileRangeSource {
  FileRangeSource(this.file);
  final File file;
  Stream<List<int>> openRange(int start, int endExclusive) async* {
    final handle = await file.open();
    try {
      final size = await handle.length();
      if (start < 0 || endExclusive < start || endExclusive > size) {
        throw RangeError('Range is outside the opened file');
      }
      await handle.setPosition(start);
      var remaining = endExclusive - start;
      while (remaining > 0) {
        final bytes = await handle.read(remaining.clamp(0, 65536));
        if (bytes.isEmpty) throw const FileSystemException('Source truncated');
        remaining -= bytes.length;
        yield bytes;
      }
    } finally {
      await handle.close();
    }
  }
}

/// Single-use output in a caller-owned private job directory. Await write before
/// publish/abort. This experiment does not prove arbitrary user-file durability.
final class FileOutputExperiment {
  FileOutputExperiment(this.temporary);
  final File temporary;
  bool _started = false, _writing = false, _owned = false;
  bool _closed = false, _published = false;

  Future<void> write(Stream<List<int>> bytes) async {
    if (_started) throw StateError('Output is single-use');
    _started = true;
    _writing = true;
    RandomAccessFile? handle;
    try {
      await temporary.create(exclusive: true);
      _owned = true;
      handle = await temporary.open(mode: FileMode.writeOnly);
      await for (final chunk in bytes) {
        await handle.writeFrom(chunk);
      }
      await handle.flush();
      await handle.close();
      handle = null;
      _closed = true;
    } catch (primary, primaryStack) {
      final cleanup = <({Object error, StackTrace stack})>[];
      try {
        await handle?.close();
      } catch (error, stack) {
        cleanup.add((error: error, stack: stack));
      }
      try {
        await _remove();
      } catch (error, stack) {
        cleanup.add((error: error, stack: stack));
      }
      if (cleanup.isNotEmpty) {
        throw FileWriteFailure(primary, primaryStack, cleanup);
      }
      Error.throwWithStackTrace(primary, primaryStack);
    } finally {
      _writing = false;
    }
  }

  Future<File> publish(String destination) async {
    if (!_closed || _published || _writing) throw StateError('Not publishable');
    if (File(destination).parent.absolute.path !=
        temporary.parent.absolute.path) {
      throw ArgumentError('Destination must be in the private job directory');
    }
    if (await File(destination).exists()) {
      throw const FileSystemException('Destination already exists');
    }
    final result = await temporary.rename(destination);
    _published = true;
    _owned = false;
    return result;
  }

  Future<void> abort() async {
    if (_published || _writing) throw StateError('Cannot abort in this state');
    _started = true;
    _closed = false;
    await _remove();
  }

  Future<void> _remove() async {
    if (_owned && await temporary.exists()) await temporary.delete();
    _owned = false;
  }
}
