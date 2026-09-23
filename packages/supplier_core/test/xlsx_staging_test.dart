import 'dart:io';
import 'package:drift/native.dart';
import 'package:supplier_core/src/exchange/xlsx_reader.dart';
import 'package:supplier_core/src/exchange/xlsx_staging.dart';
import 'package:test/test.dart';
import 'support/xlsx_fixtures.dart';

void main() {
  test('ready raw cells and shared strings survive disk reopen', () async {
    final directory = await Directory.systemTemp.createTemp('xlsx-staging-');
    final file = File('${directory.path}/parse.sqlite');
    var db = XlsxStaging(NativeDatabase(file));
    try {
      await const BoundedXlsxReader().readVolume(xlsxFixture(), db);
      await db.close();
      db = XlsxStaging(NativeDatabase(file));
      expect((await db.cellsPage(2)).first.cell.lexical, '00123');
      expect((await db.profile())['rows'], 2);
      await expectLater(
        const BoundedXlsxReader().readVolume(xlsxFixture(), db),
        throwsStateError,
      );
    } finally {
      await db.close();
      await directory.delete(recursive: true);
    }
  });
  test('unfinished parse remains quarantined after reopen', () async {
    final directory = await Directory.systemTemp.createTemp('xlsx-staging-');
    final file = File('${directory.path}/parse.sqlite');
    var db = XlsxStaging(NativeDatabase(file));
    try {
      await db.begin();
      await db.putString(0, 'partial');
      await db.close();
      db = XlsxStaging(NativeDatabase(file));
      await expectLater(db.rowsPage(), throwsStateError);
      await expectLater(db.profile(), throwsStateError);
    } finally {
      await db.close();
      await directory.delete(recursive: true);
    }
  });
}
