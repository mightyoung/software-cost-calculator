import 'dart:async';

/// Test-only scope; no production host constructor exposes fault injection.
Future<T> withNativeRestoreFault<T>(
  Future<T> Function() action,
  Future<void> Function(String) fault,
) => runZoned(action, zoneValues: {#supplierNativeRestoreFault: fault});
