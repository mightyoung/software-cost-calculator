import 'dart:convert';
import 'dart:js_interop';

import 'package:drift/wasm.dart';
import 'package:supplier_core/src/exchange/xlsx_reader.dart';
import 'package:supplier_core/src/exchange/xlsx_staging.dart';

import '../../../packages/supplier_core/test/support/xlsx_fixtures.dart';

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
      'xlsx-${Uri.base.queryParameters['run']}-$suffix',
    ),
  );
}

void check(bool value, String message) {
  if (!value) throw StateError(message);
}

Future<JSString> run() async {
  var passed = 0;
  stage = 'shared string persistence'.toJS;
  final db = await database('valid');
  try {
    final p = await const BoundedXlsxReader().readVolume(
      xlsxFixture(
        shared:
            '<sst xmlns="$mainNs">${List.generate(40, (i) => '<si><t>00$i</t></si>').join()}</sst>',
        sheet: worksheet(
          '${List.generate(40, (i) => '<row r="${i + 1}"><c r="A${i + 1}" t="s"><v>$i</v></c></row>').join()}<row r="41"><c r="A41" t="str"><f/><v>cached</v></c><c r="B41" t="d"><v>2026-09-18</v></c><c r="C41" t="inlineStr"><is><t>A_x000D_B_x005F_x0041_</t></is></c></row>',
        ),
      ),
      db,
    );
    check(p.sharedStrings == 40 && p.rows == 41 && p.date1904, 'Wrong profile');
    check(
      (await db.cellsPage(40)).single.cell.lexical == '0039',
      'Shared string lookup',
    );
    final raw = await db.cellsPage(41);
    check(
      raw.first.cell.formula == '' && raw[1].rawType == 'd',
      'Raw formula/date lost',
    );
    check(raw.last.cell.lexical == 'A\rB_x0041_', 'Xstring decoding');
    for (final cell in raw.take(2)) {
      var failed = false;
      try {
        cell.cell.sourcePresence;
      } catch (_) {
        failed = true;
      }
      check(failed, 'Expected mapping row error');
    }
    passed++;
  } finally {
    await db.close();
  }
  final metadata = await database('calculation');
  try {
    await const BoundedXlsxReader().readVolume(
      xlsxFixture(
        overrides: {
          'xl/styles.xml':
              '<styleSheet xmlns="$mainNs"><extLst><ext uri="{EB79DEF2-80B8-43e5-95BD-54CBDDF9020C}" xmlns:x14="http://schemas.microsoft.com/office/spreadsheetml/2009/9/main"><x14:slicerStyles defaultSlicerStyle="SlicerStyleLight1"/></ext></extLst></styleSheet>',
        },
        workbook:
            '<workbook xmlns="$mainNs" xmlns:r="$relNs"><sheets><sheet name="业务" r:id="s"/></sheets><extLst><ext uri="{B58B0392-4F1F-4190-BB64-5DF3571DCE5F}" xmlns:xcalcf="http://schemas.microsoft.com/office/spreadsheetml/2018/calcfeatures"><xcalcf:calcFeatures><xcalcf:feature name="microsoft.com:LET_WF"/></xcalcf:calcFeatures></ext></extLst></workbook>',
      ),
      metadata,
    );
    check(
      (await metadata.cellsPage(2)).first.cell.lexical == '00123',
      'Metadata altered business data',
    );
    passed++;
  } finally {
    await metadata.close();
  }
  final rejected = <String, String>{
    'duplicate': worksheet('<row r="1"><c r="A1"/><c r="A1"/></row>'),
    'unquoted': worksheet('<row r=1/>'),
    'missing_assignment': worksheet('<row r/>'),
    'scalar_child': worksheet(
      '<row r="1"><c r="A1"><v>1<garbage>9</garbage>2</v></c></row>',
    ),
    'entity': worksheet(
      '<row r="1"><c r="A1" t="inlineStr"><is><t>A&bogus;</t></is></c></row>',
    ),
    'rich_child': worksheet(
      '<row r="1"><c r="A1" t="inlineStr"><is><garbage>00123</garbage></is></c></row>',
    ),
    'escaped_control': worksheet(
      '<row r="1"><c r="A1" t="inlineStr"><is><t>_x0001_</t></is></c></row>',
    ),
    'must_understand':
        '<worksheet xmlns="$mainNs" xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006" mc:MustUnderstand="x"><sheetData/></worksheet>',
    'ignorable_business':
        '<worksheet xmlns="$mainNs" xmlns:x="urn:unknown" xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006" mc:Ignorable="x"><sheetData><x:row/></sheetData></worksheet>',
    'namespace': '<worksheet xmlns="evil"><sheetData/></worksheet>',
    'nesting': '<worksheet xmlns="$mainNs"><sheetData></worksheet>',
    'dtd':
        '<!DOCTYPE worksheet><worksheet xmlns="$mainNs"><sheetData/></worksheet>',
    'merged':
        '<worksheet xmlns="$mainNs"><sheetData/><mergeCells><mergeCell ref="A1:B1"/></mergeCells></worksheet>',
    'utf16': worksheet(
      '<row r="1"><c r="A1" t="inlineStr"><is><t>${'😀' * 16384}</t></is></c></row>',
    ),
  };
  for (final entry in rejected.entries) {
    stage = entry.key.toJS;
    final bad = await database(entry.key);
    try {
      var rejected = false;
      try {
        await const BoundedXlsxReader().readVolume(
          xlsxFixture(sheet: entry.value),
          bad,
        );
      } catch (_) {
        rejected = true;
      }
      check(rejected, 'Accepted ${entry.key}');
      var quarantined = false;
      try {
        await bad.rowsPage();
      } on StateError {
        quarantined = true;
      }
      check(quarantined, 'Exposed failed staging');
      passed++;
    } finally {
      await bad.close();
    }
  }
  final cancelDb = await database('cancel');
  try {
    var checks = 0, rejected = false;
    final failure = StateError('cancelled');
    try {
      await const BoundedXlsxReader().readVolume(
        xlsxFixture(
          sheet: worksheet(
            List.generate(130, (i) => '<row r="${i + 1}"/>').join(),
          ),
        ),
        cancelDb,
        checkpoint: () async {
          if (++checks == 7) throw failure;
        },
      );
    } catch (error) {
      rejected = identical(error, failure);
    }
    check(rejected, 'Cancellation identity lost');
    var quarantined = false;
    try {
      await cancelDb.profile();
    } on StateError {
      quarantined = true;
    }
    check(quarantined, 'Cancelled run readable');
    passed++;
  } finally {
    await cancelDb.close();
  }
  return jsonEncode({
    'status': 'PASS',
    'cases': passed,
    'storage': 'OPFS SQLite',
    'raw_formula_date': true,
  }).toJS;
}

Future<JSString> reopen() async {
  final db = await database('valid');
  try {
    check(
      (await db.cellsPage(40)).single.cell.lexical == '0039',
      'Process restart lost raw data',
    );
    check((await db.profile())['rows'] == 41, 'Process restart lost profile');
    check(
      (await db.rowsPage(afterRow: 39, limit: 1)).single.row == 40,
      'Row pagination',
    );
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
