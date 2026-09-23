import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:supplier_core/supplier_core.dart';

import 'web_installation_store.dart';

@JS('supplierPlatform.withLock')
external JSPromise<JSAny?> _withLock(JSString name, JSFunction action);
@JS('supplierPlatform.pickInput')
external JSPromise<_Source> _pickInput();
@JS('supplierPlatform.pickOutput')
external JSPromise<JSObject> _pickOutput(JSString name);
@JS('supplierPlatform.outputFromHandle')
external JSPromise<_Output> _outputFromHandle(JSObject handle);
@JS('supplierPlatform.privateArtifact')
external JSPromise<_Artifact> _privateArtifact(JSString namespace);

extension type _Source(JSObject _) implements JSObject {
  external JSString get name;
  external JSNumber get size;
  external JSPromise<JSUint8Array> read(JSNumber start, JSNumber end);
}

extension type _Output(JSObject _) implements JSObject {
  external JSPromise<JSAny?> write(JSUint8Array bytes);
  external JSPromise<JSAny?> publish();
  external JSPromise<JSAny?> abort();
}

extension type _Artifact(JSObject _) implements JSObject {
  external _Output get output;
  external JSPromise<_Source> source();
  external JSPromise<JSAny?> dispose();
}

final class WebApplicationWriteLock implements ApplicationWriteLock {
  WebApplicationWriteLock(this.namespace);
  final String namespace;
  static const _zoneKey = #supplierWebWriteLocks;
  @override
  Future<T> run<T>(Future<T> Function() action) async {
    final held = Zone.current[_zoneKey] as Set<String>? ?? const <String>{};
    if (held.contains(namespace)) {
      throw StateError('Application write lock is not reentrant');
    }
    late T result;
    Object? failure;
    StackTrace? stack;
    JSPromise<JSAny?> invoke() => (() async {
      try {
        result = await runZoned(
          action,
          zoneValues: {
            _zoneKey: {...held, namespace},
          },
        );
      } catch (error, trace) {
        failure = error;
        stack = trace;
      }
      return null as JSAny?;
    })().toJS;
    await _withLock(namespace.toJS, invoke.toJS).toDart;
    if (failure != null) Error.throwWithStackTrace(failure!, stack!);
    return result;
  }
}

final class WebInputSource implements InputSource {
  WebInputSource._(this._source);
  final _Source _source;
  static Future<WebInputSource> pick() async =>
      WebInputSource._(await _pickInput().toDart);
  @override
  String get displayName => _source.name.toDart;
  @override
  Future<int> length() async => _source.size.toDartInt;
  @override
  Stream<List<int>> openRange(int start, int endExclusive) async* {
    final size = await length();
    if (start < 0 || endExclusive < start || endExclusive > size) {
      throw RangeError('File range exceeds source');
    }
    for (var offset = start; offset < endExclusive; offset += 65536) {
      final end = (offset + 65536).clamp(0, endExclusive);
      final bytes = (await _source.read(offset.toJS, end.toJS).toDart).toDart;
      if (bytes.length != end - offset) {
        throw const DomainFailure('IO_FAILURE', 'File range was truncated');
      }
      yield bytes;
    }
  }
}

/// A handle is acquired in the button gesture, before generating a large export.
final class WebSaveHandle {
  WebSaveHandle._(this._handle);
  final JSObject _handle;
  static Future<WebSaveHandle> pick(String suggestedName) async =>
      WebSaveHandle._(await _pickOutput(suggestedName.toJS).toDart);
  Future<WebOutputTarget> open() async =>
      WebOutputTarget._(await _outputFromHandle(_handle).toDart);
}

final class WebOutputTarget implements OutputTarget {
  WebOutputTarget._(this._output);
  final _Output _output;
  bool _started = false,
      _complete = false,
      _published = false,
      _aborted = false,
      _writing = false;
  @override
  Future<void> write(Stream<List<int>> bytes) async {
    if (_started || _aborted) throw StateError('Output stream is single-use');
    _started = true;
    _writing = true;
    try {
      await for (final chunk in bytes) {
        for (var offset = 0; offset < chunk.length; offset += 65536) {
          final end = (offset + 65536).clamp(0, chunk.length);
          await _output
              .write(Uint8List.fromList(chunk.sublist(offset, end)).toJS)
              .toDart;
        }
      }
      _complete = true;
    } finally {
      _writing = false;
    }
  }

  @override
  Future<void> publish() async {
    if (!_complete || _published || _aborted || _writing) {
      throw StateError('Output is not ready for publication');
    }
    await _output.publish().toDart;
    _published = true;
  }

  @override
  Future<void> abort() async {
    if (_writing) throw StateError('Await the stream before aborting');
    if (_aborted || _published) return;
    await _output.abort().toDart;
    _aborted = true;
  }
}

final class WebBackupArtifact implements BackupArtifact {
  WebBackupArtifact._(this._artifact)
    : output = WebOutputTarget._(_artifact.output);
  final _Artifact _artifact;
  static Future<WebBackupArtifact> create(String namespace) async =>
      WebBackupArtifact._(await _privateArtifact(namespace.toJS).toDart);
  @override
  final WebOutputTarget output;
  @override
  InputSource get source => _ArtifactInput(_artifact);
  @override
  Future<void> dispose() async {
    await _artifact.dispose().toDart;
  }
}

final class _ArtifactInput implements InputSource {
  _ArtifactInput(this._artifact);
  final _Artifact _artifact;
  WebInputSource? _frozen;
  Future<WebInputSource> _input() async =>
      _frozen ??= WebInputSource._(await _artifact.source().toDart);
  @override
  String get displayName => '临时逻辑备份';
  @override
  Future<int> length() async => (await _input()).length();
  @override
  Stream<List<int>> openRange(int start, int endExclusive) async* {
    yield* (await _input()).openRange(start, endExclusive);
  }
}

@JS('supplierPlatform.durableBackupOutput')
external JSPromise<_Output> _durableBackupOutput(
  JSString namespace,
  JSString locator,
);
@JS('supplierPlatform.durableBackupSource')
external JSPromise<_Source> _durableBackupSource(
  JSString namespace,
  JSString locator,
);
@JS('supplierPlatform.uuid')
external JSString _backupLocator();

/// Published restore safety backups remain addressable after page/process exit.
/// Locators are installation-owned UUIDs, never arbitrary paths or JS handles.
final class WebDurableBackup {
  WebDurableBackup._(this.namespace, this.locator, this.output);
  final String namespace, locator;
  final OutputTarget output;
  InputSource get source => _DurableBackupSource(namespace, locator);

  /// The exchange service invokes this under the installation write lock after
  /// full readback and before committing. Every successful retry keeps its own
  /// record; prior verified safety backups remain discoverable after restart.
  Future<void> associateWithJob(String jobId) async {
    final store = WebInstallationStore(namespace);
    final key = 'import_backup:$jobId:$locator';
    final record = <String, Object?>{
      'job_id': jobId,
      'locator': locator,
      'namespace': namespace,
    };
    await store.compareAndSet(expected: {key: null}, changes: {key: record});
    final latest = 'import_backup:$jobId';
    await store.compareAndSet(
      expected: {latest: await store.read(latest)},
      changes: {latest: record},
    );
  }

  static Future<WebDurableBackup> create(String namespace) async {
    final locator = _backupLocator().toDart;
    return WebDurableBackup._(
      namespace,
      locator,
      WebOutputTarget._(
        await _durableBackupOutput(namespace.toJS, locator.toJS).toDart,
      ),
    );
  }

  static Future<InputSource> read(String namespace, String locator) async {
    requireUuid(locator, 'backup_locator');
    return WebInputSource._(
      await _durableBackupSource(namespace.toJS, locator.toJS).toDart,
    );
  }
}

final class _DurableBackupSource implements InputSource {
  _DurableBackupSource(this.namespace, this.locator);
  final String namespace, locator;
  @override
  String get displayName => '$locator.logical';
  @override
  Future<int> length() async =>
      (await WebDurableBackup.read(namespace, locator)).length();
  @override
  Stream<List<int>> openRange(int start, int endExclusive) async* {
    yield* (await WebDurableBackup.read(
      namespace,
      locator,
    )).openRange(start, endExclusive);
  }
}
