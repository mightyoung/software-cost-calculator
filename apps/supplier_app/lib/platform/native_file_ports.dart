import 'dart:async';
import 'dart:io';

import 'package:supplier_core/supplier_core.dart';

/// Keeps the initiating error when releasing a handle or removing a partial
/// output also fails. A caller can retain the job for a later cleanup attempt.
final class FileOperationFailure implements Exception {
  FileOperationFailure(this.primary, this.primaryStack, List<Object> cleanup)
    : cleanup = List.unmodifiable(cleanup);
  final Object primary;
  final StackTrace primaryStack;
  final List<Object> cleanup;
  @override
  String toString() => 'File operation failed: $primary; cleanup: $cleanup';
}

final class NativeInputSource implements InputSource {
  NativeInputSource(this.file, {required this.displayName});
  final File file;
  @override
  final String displayName;
  @override
  Future<int> length() => file.length();

  @override
  Stream<List<int>> openRange(int start, int endExclusive) async* {
    final handle = await file.open();
    Object? primary;
    StackTrace? primaryStack;
    try {
      if (start < 0 ||
          endExclusive < start ||
          endExclusive > await handle.length()) {
        throw RangeError('Range is outside the opened input');
      }
      await handle.setPosition(start);
      var remaining = endExclusive - start;
      while (remaining > 0) {
        final chunk = await handle.read(remaining.clamp(0, 65536));
        if (chunk.isEmpty) {
          throw const FileSystemException('Input truncated while reading');
        }
        remaining -= chunk.length;
        yield chunk;
      }
    } catch (error, stack) {
      primary = error;
      primaryStack = stack;
      rethrow;
    } finally {
      try {
        await handle.close();
      } catch (cleanup) {
        if (primary != null) {
          throw FileOperationFailure(primary, primaryStack!, [cleanup]);
        }
        rethrow;
      }
    }
  }
}

/// A publication boundary inside an application-owned private job directory.
/// The two paths must be reserved to this job. External save-dialog destinations
/// use their own platform publication adapter; this class does not overwrite one.
final class PrivateFileOutput implements OutputTarget {
  PrivateFileOutput({required this.temporary, required this.destination});
  final File temporary, destination;
  bool _started = false, _writing = false, _owned = false;
  bool _closed = false, _published = false;
  bool _publishing = false;

  @override
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
    } catch (primary, stack) {
      final cleanup = <Object>[];
      try {
        await handle?.close();
      } catch (error) {
        cleanup.add(error);
      }
      try {
        await _remove();
      } catch (error) {
        cleanup.add(error);
      }
      if (cleanup.isNotEmpty) {
        throw FileOperationFailure(primary, stack, cleanup);
      }
      Error.throwWithStackTrace(primary, stack);
    } finally {
      _writing = false;
    }
  }

  @override
  Future<void> publish() async {
    if (!_closed || _writing || _published || _publishing) {
      throw StateError('Output is not ready to publish');
    }
    _publishing = true;
    try {
      final parent = await temporary.parent.resolveSymbolicLinks();
      if (parent != await destination.parent.resolveSymbolicLinks() ||
          temporary.absolute.path == destination.absolute.path) {
        throw ArgumentError(
          'Publication must stay in its private job directory',
        );
      }
      if (await FileSystemEntity.type(destination.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw const FileSystemException(
          'Publication destination already exists',
        );
      }
      await temporary.rename(destination.path);
      _published = true;
      _owned = false;
    } finally {
      _publishing = false;
    }
  }

  @override
  Future<void> abort() async {
    if (_writing || _published || _publishing) {
      throw StateError('Cannot abort in this state');
    }
    _started = true;
    _closed = false;
    await _remove();
  }

  Future<void> _remove() async {
    if (_owned && await temporary.exists()) await temporary.delete();
    _owned = false;
  }
}

/// One owning isolate per process: all UI/background write requests must route
/// to that owner. A local queue complements the OS lock because POSIX locks are
/// process-scoped. The stable lock file must never be replaced during use.
final class NativeApplicationWriteLock implements ApplicationWriteLock {
  NativeApplicationWriteLock(this.file);
  final File file;
  static final _zoneKey = Object();
  static final Map<String, Future<void>> _tails = {};

  @override
  Future<T> run<T>(Future<T> Function() action) async {
    final parent = await file.parent.resolveSymbolicLinks();
    final unresolved =
        '$parent${Platform.pathSeparator}${file.uri.pathSegments.last}';
    // Resolve an existing final symlink without opening another descriptor:
    // closing such a descriptor could release this process's existing lock.
    final key =
        await FileSystemEntity.type(file.path, followLinks: false) ==
            FileSystemEntityType.notFound
        ? unresolved
        : await file.resolveSymbolicLinks();
    final held = Zone.current[_zoneKey] as Set<String>? ?? const <String>{};
    if (held.contains(key)) {
      throw StateError(
        'Reuse the held context instead of reacquiring its lock',
      );
    }
    final previous = _tails[key] ?? Future<void>.value();
    final done = Completer<void>();
    _tails[key] = done.future;
    await previous;
    RandomAccessFile? handle;
    Object? primary;
    StackTrace? primaryStack;
    try {
      handle = await File(key).open(mode: FileMode.append);
      await handle.lock(FileLock.blockingExclusive);
      return await runZoned(
        action,
        zoneValues: {
          _zoneKey: {...held, key},
        },
      );
    } catch (error, stack) {
      primary = error;
      primaryStack = stack;
      rethrow;
    } finally {
      try {
        await handle?.close();
      } catch (cleanup) {
        if (primary != null) {
          throw FileOperationFailure(primary, primaryStack!, [cleanup]);
        }
        rethrow;
      } finally {
        done.complete();
        if (identical(_tails[key], done.future)) _tails.remove(key);
      }
    }
  }
}
