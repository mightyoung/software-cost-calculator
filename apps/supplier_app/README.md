# Supplier and quotation app

Local-first Flutter app for supplier, product, contact, quotation, business Excel and full-history bundle workflows. The shared repository and import/export implementations are present; see `../../docs/verification/release-matrix.md` for current platform and release evidence. Android and Windows device validation is deferred.

Toolchain: Flutter **3.47.4**, framework **9584c6713b**, Dart **3.13.3**. Use the committed `pubspec.lock`.

From this directory:

```sh
flutter pub get
flutter analyze
flutter test
python3 tool/build_web_offline.py
flutter test integration_test/platform_probe_test.dart -d <real-device-id>
```

Run Windows build on Windows and Android build with the Android SDK when those platform checks resume. See `../../docs/verification/platform-capabilities.md` for the remaining real-device acceptance experiments.

Web release deployment must use `tool/build_web_offline.py` and publish its whole
`build/web` output. Plain `flutter build web` leaves an unprepared release that
intentionally refuses to open the database. `FLUTTER=/path/to/flutter` selects
the SDK. For an existing release, use `--package-only`; it does not compile Dart.
The wrapper bundles the licensed Chinese/Latin font and verifies all offline
assets. Updates remain waiting until every old application tab closes.

For browser debugging of the packaged release, serve `build/web` on localhost
and use Chrome DevTools. This exercises the production offline gate; it does
not provide Flutter hot reload. Use `flutter test` for widget debug workflows.
Do not deploy a debug/bootstrap bypass as a release.
