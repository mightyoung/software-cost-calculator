import 'dart:convert';
import 'dart:js_interop';

@JS('supplierPlatform.readMetadata')
external JSPromise<JSString> _read(JSString namespace, JSString key);
@JS('supplierPlatform.compareAndSetMetadata')
external JSPromise<JSAny?> _cas(
  JSString namespace,
  JSString expected,
  JSString changes,
);
@JS('supplierPlatform.uuid')
external JSString _uuid();

String newWebInstanceId() => _uuid().toDart;

/// Installation identity and activation records live outside every business DB.
/// Mutation callers hold the installation-wide application write lock.
final class WebInstallationStore {
  WebInstallationStore(this.namespace);
  final String namespace;
  Future<Map<String, Object?>?> read(String key) async {
    final value = jsonDecode(
      (await _read(namespace.toJS, key.toJS).toDart).toDart,
    );
    if (value == null) return null;
    if (value is! Map<String, Object?>) {
      throw StateError('Invalid installation metadata');
    }
    return value;
  }

  Future<void> compareAndSet({
    required Map<String, Map<String, Object?>?> expected,
    required Map<String, Map<String, Object?>?> changes,
  }) async {
    await _cas(
      namespace.toJS,
      jsonEncode(expected).toJS,
      jsonEncode(changes).toJS,
    ).toDart;
  }
}
