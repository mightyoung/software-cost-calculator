import 'dart:convert';
import 'dart:js_interop';

import 'package:drift/wasm.dart';
import 'package:supplier_core/supplier_core.dart';
import 'package:supplier_app/platform/web_file_ports.dart';

@JS('runSmoke')
external set runSmoke(JSFunction value);
@JS('reopenSmoke')
external set reopenSmoke(JSFunction value);
@JS('probeReady')
external set ready(JSBoolean value);
@JS('smokeStage')
external set stage(JSString value);
Future<WasmProbeResult>? probe;
Future<XlsxStaging> database(String suffix) async {
  final p = await (probe ??= WasmDatabase.probe(
    sqlite3Uri: Uri.base.resolve('sqlite3.wasm'),
    driftWorkerUri: Uri.base.resolve('drift_worker.js'),
  ));
  final implementations =
      p.availableStorages
          .where((x) => x.storageApi == WebStorageApi.opfs)
          .toList()
        ..sort((a, b) => a.index.compareTo(b.index));
  if (implementations.isEmpty) throw StateError('OPFS required');
  return XlsxStaging(
    await p.open(
      implementations.first,
      'xlsx-writer-${Uri.base.queryParameters['run']}-$suffix',
    ),
  );
}

void check(bool value, String message) {
  if (!value) throw StateError(message);
}

const values = <String?>[
  '000123-A',
  '12.340001',
  '2026-09-16T06:30:00.123Z',
  '中😀文e\u0301',
  'A\r\nB',
  '_x0041_',
  '_x005F_x0041_',
  '=1+1',
  null,
  '',
];
Future<JSString> run() async {
  var passed = 0;
  final validation = await database('valid');
  BoundedXlsxVolume volume;
  try {
    volume = await const BoundedXlsxWriter().encodeVolume(
      rows: Stream.value(values),
      headers: List.generate(values.length, (i) => '列$i'),
      validation: validation,
    );
    final cells = await validation.cellsPage(2);
    for (var i = 0; i < cells.length; i++) {
      check(cells[i].cell.lexical == (values[i] ?? ''), 'Lexical mismatch $i');
    }
    check(
      cells[8].cell.kind == BusinessCellKind.blank &&
          cells[9].cell.kind == BusinessCellKind.text,
      'Null/empty lost',
    );
    passed++;
  } finally {
    await validation.close();
  }
  final artifact = await WebBackupArtifact.create(
    'xlsx-writer-${Uri.base.queryParameters['run']}',
  );
  final reread = await database('reread');
  try {
    await volume.publishTo(artifact.output);
    final profile = await const BoundedXlsxReader().readVolume(
      artifact.source,
      reread,
    );
    check(
      profile.sourceDigest == volume.sha256Hex,
      'Published file bytes differ',
    );
    check(
      (await reread.cellsPage(2))[6].cell.lexical == '_x005F_x0041_',
      'Published text differs',
    );
    passed++;
  } finally {
    await reread.close();
    await artifact.dispose();
  }
  for (final item in <String, List<String?>>{
    'utf16': ['😀' * 16384],
    'width': ['one', 'extra'],
    'control': ['\u0001'],
  }.entries) {
    final db = await database(item.key);
    try {
      var rejected = false;
      try {
        await const BoundedXlsxWriter().encodeVolume(
          rows: Stream.value(item.value),
          headers: ['A'],
          validation: db,
        );
      } catch (_) {
        rejected = true;
      }
      check(rejected, 'Expected writer rejection ${item.key}');
      passed++;
    } finally {
      await db.close();
    }
  }
  final limited = await database('limit');
  try {
    var rejected = false;
    try {
      await const BoundedXlsxWriter().encodeVolume(
        rows: Stream.value(['x']),
        headers: ['A'],
        validation: limited,
        policy: const XlsxExportPolicy.syncVolume(
          zipLimits: XlsxZipLimits(compressedBytes: 200),
        ),
      );
    } on DomainFailure catch (e) {
      rejected = e.code == 'XLSX_VOLUME_LIMIT';
    }
    check(rejected, 'Byte budget not enforced');
    passed++;
  } finally {
    await limited.close();
  }
  final cancelled = await database('cancel');
  try {
    var calls = 0, rejected = false;
    final failure = StateError('cancelled');
    try {
      await const BoundedXlsxWriter().encodeVolume(
        rows: Stream.fromIterable(List.generate(70, (_) => ['x'])),
        headers: ['A'],
        validation: cancelled,
        checkpoint: () async {
          if (++calls == 2) throw failure;
        },
      );
    } catch (e) {
      rejected = identical(e, failure);
    }
    check(rejected, 'Cancelled encoding escaped');
    passed++;
  } finally {
    await cancelled.close();
  }
  return jsonEncode({
    'status': 'PASS',
    'cases': passed,
    'bytes': volume.byteLength,
    'sha256': volume.sha256Hex,
    'opfs_published_and_reread': true,
  }).toJS;
}

Future<JSString> reopen() async {
  final db = await database('valid');
  try {
    final cells = await db.cellsPage(2);
    for (var i = 0; i < cells.length; i++) {
      check(
        cells[i].cell.lexical == (values[i] ?? ''),
        'Persisted verification changed',
      );
    }
    return jsonEncode({'status': 'PASS', 'process_reopen': true}).toJS;
  } finally {
    await db.close();
  }
}

void main() {
  runSmoke = (() => run().toJS).toJS;
  reopenSmoke = (() => reopen().toJS).toJS;
  ready = true.toJS;
}
