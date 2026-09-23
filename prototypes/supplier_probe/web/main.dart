import 'dart:convert';
import 'dart:js_interop';
import 'package:drift/wasm.dart';
import 'package:web/web.dart';
import 'package:supplier_probe/database.dart';
import 'package:supplier_probe/model.dart';
import 'package:supplier_probe/xlsx.dart';

Future<void> main() async {
  final output = document.querySelector('#output')!;
  final query = Uri.base.queryParameters;
  try {
    final opened = await WasmDatabase.open(
      databaseName: query['database'] ?? 'supplier-probe',
      sqlite3Uri: Uri.parse('sqlite3.wasm'),
      driftWorkerUri: Uri.parse('drift_worker.js'),
    );
    final persistent =
        opened.chosenImplementation != WasmStorageImplementation.inMemory &&
        opened.chosenImplementation !=
            WasmStorageImplementation.unsafeIndexedDb;
    final db = ProbeDatabase(opened.resolvedExecutor, persistent: persistent);
    try {
      if (query['action'] == 'seed') {
        await db.restore(sampleSnapshot());
      }
      final snapshot = await db.snapshot();
      final roundtrip = decodeSnapshot(encodeSnapshot(snapshot));
      if (jsonEncode(roundtrip) != jsonEncode(snapshot)) {
        throw StateError('XLSX mismatch');
      }
      output.textContent = jsonEncode({
        'status': persistent ? 'PASS' : 'UNSAFE_OR_MEMORY_WRITES_DISABLED',
        'storage': opened.chosenImplementation.name,
        'missingFeatures': opened.missingFeatures
            .map((feature) => feature.name)
            .toList(),
        'snapshot': snapshot,
        'xlsxRoundtrip': true,
      });
      document.documentElement!.setAttribute(
        'data-result',
        persistent ? 'pass' : 'memory',
      );
      final button = document.querySelector('#download') as HTMLButtonElement;
      button.disabled = !persistent;
      button.addEventListener(
        'click',
        ((Event event) {
          final bytes = encodeSnapshot(snapshot);
          final anchor = HTMLAnchorElement()
            ..href =
                'data:application/vnd.openxmlformats-officedocument.spreadsheetml.sheet;base64,${base64Encode(bytes)}'
            ..download = 'supplier-stage0.xlsx';
          anchor.click();
        }).toJS,
      );
    } finally {
      await db.close();
    }
  } catch (error, stack) {
    output.textContent = 'FAIL: $error\n$stack';
    document.documentElement!.setAttribute('data-result', 'fail');
  }
}
