import 'package:drift/wasm.dart';

/// Compile using this app's lockfile so remote transaction protocol and VFS
/// implementation match the client exactly.
void main() => WasmDatabase.workerMainForOpen();
