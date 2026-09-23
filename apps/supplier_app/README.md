# Supplier platform capability probe

Engineering shell for Windows, Android and Web. No business repository or CRUD is installed. Every capability starts BLOCKED and production writes remain disabled. The shell only reports the absence of verified evidence; it does not yet execute storage experiments.

Toolchain: Flutter **3.47.4**, framework **9584c6713b**, Dart **3.13.3**. Use the committed `pubspec.lock`; no Drift/SQLite/WASM backend is selected or represented as verified by this app.

From this directory:

```sh
flutter pub get
flutter analyze
flutter test
flutter build web
flutter test integration_test/platform_probe_test.dart -d <real-device-id>
```

Run Windows build on Windows and Android build with the Android SDK. Integration smoke only proves startup and a closed write gate. See `../../docs/verification/platform-capabilities.md` for the remaining real-device acceptance experiments.
