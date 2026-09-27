import 'dart:async';
import 'dart:isolate';

import 'store.dart';

extension Background on Store {
  /// Runs [action] on a second connection to this database in a background
  /// isolate, so imports, syncs and exports don't freeze the window. SQLite
  /// (WAL) lets the window keep reading meanwhile; its writes wait for the
  /// lock. [action] is copied to the isolate: it must not capture this store
  /// or anything else holding native resources. Its result and errors come
  /// back as-is. In-memory databases run it inline.
  Future<T> inBackground<T>(FutureOr<T> Function(Store store) action) async {
    final path = db.select('PRAGMA database_list').first['file'] as String;
    if (path.isEmpty) return action(this);
    final result = await _runOn(path, device, action);
    clockSeen();
    return result;
  }
}

// Top level so the isolate closure captures only these arguments.
Future<T> _runOn<T>(
  String path,
  String device,
  FutureOr<T> Function(Store store) action,
) => Isolate.run(() async {
  final store = Store.open(path, device: device);
  try {
    return await action(store);
  } finally {
    store.close();
  }
});
