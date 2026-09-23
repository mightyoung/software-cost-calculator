# Native data directory

`openSupplierWorkspace` resolves the persistent directory before opening the
installation metadata, database, lock, backup, or import files.

- A nonempty `--dart-define=SUPPLIER_DATA_DIRECTORY=...` takes precedence.
- Android uses `path_provider.getApplicationSupportDirectory()`, the application
  private support directory. No shared storage permission or hard-coded package
  identifier is needed. Provider failures reach the startup error/retry screen;
  there is no temporary-directory or current-directory fallback.
- Existing desktop locations remain unchanged: macOS uses
  `$HOME/Library/Application Support/SupplierInquiry`; Windows uses
  `%LOCALAPPDATA%/SupplierInquiry`; Linux uses
  `$XDG_DATA_HOME/supplier-inquiry` or `$HOME/.local/share/supplier-inquiry`.

`path_provider` is pinned to **2.1.6** in `pubspec.yaml`, with platform packages
locked in `pubspec.lock`. This Flutter-maintained plugin is necessary to obtain
Android's application-owned persistent directory through the platform API.
See the [official package documentation](https://pub.dev/packages/path_provider).

`test/native_data_directory_test.dart` injects the operating system, environment,
and support-directory provider to check Android selection, explicit overrides,
failure propagation, invalid provider paths, and unchanged desktop policy.
These host tests do not validate Android plugin registration or device storage.
Android and Windows target validation remain **DEFERRED** by user decision.
