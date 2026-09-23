import 'dart:typed_data';
import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:drift/native.dart';
import 'package:excel/excel.dart';
import 'package:supplier_probe/database.dart';
import 'package:supplier_probe/model.dart';
import 'package:supplier_probe/xlsx.dart';
import 'package:test/test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:xml/xml.dart';

class FailingMigrationDatabase extends ProbeDatabase {
  FailingMigrationDatabase(super.executor, this.failSql);
  final String failSql;
  @override
  Future<void> customStatement(String statement, [List<Object?>? args]) {
    if (statement.contains(failSql)) throw StateError('Injected DDL failure');
    return super.customStatement(statement, args);
  }
}

void main() {
  test('real WPS save roundtrip and narrow style compatibility', () {
    final bytes = File(
      '../../artifacts/supplier-probe/supplier-wps-roundtrip.xlsx',
    ).readAsBytesSync();
    expect(decodeSnapshot(bytes), sampleSnapshot());
    for (final variant in ['unsupported', 'used', 'inherited', 'numeric']) {
      final original = ZipDecoder().decodeBytes(bytes);
      final changed = Archive();
      var mutated = false;
      for (final file in original.files) {
        var content = file.content as List<int>;
        if (file.name == 'xl/styles.xml' && variant != 'numeric') {
          final xml = utf8.decode(content);
          var updated = variant == 'unsupported'
              ? xml.replaceFirst('numFmtId="41"', 'numFmtId="40"')
              : xml.replaceFirstMapped(
                  RegExp(r'(<cellXfs[^>]*>\s*<xf[^>]*numFmtId=")0"'),
                  (m) => '${m[1]}41"',
                );
          if (variant == 'inherited') {
            final parsed = XmlDocument.parse(xml);
            final bases = parsed
                .findAllElements('cellStyleXfs')
                .single
                .childElements
                .toList();
            final index = bases.indexWhere(
              (e) => e.getAttribute('numFmtId') == '41',
            );
            expect(index, greaterThanOrEqualTo(0));
            parsed
                .findAllElements('cellXfs')
                .single
                .childElements
                .first
                .setAttribute('xfId', '$index');
            updated = parsed.toXmlString();
          }
          mutated = updated != xml;
          content = utf8.encode(updated);
        }
        if (variant == 'numeric' &&
            file.name.startsWith('xl/worksheets/') &&
            file.name.endsWith('.xml')) {
          final xml = utf8.decode(content);
          final updated = xml.replaceFirst(
            RegExp(r'<c r="P2"[^>]*>.*?</c>'),
            '<c r="P2" t="n"><v>123</v></c>',
          );
          mutated = mutated || updated != xml;
          content = utf8.encode(updated);
        }
        changed.addFile(ArchiveFile(file.name, content.length, content));
      }
      expect(mutated, isTrue, reason: variant);
      expect(
        () => decodeSnapshot(ZipEncoder().encode(changed)!),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'reason',
            contains(
              variant == 'numeric' ? 'text cell required' : 'xlsx.styles',
            ),
          ),
        ),
      );
    }
  });
  test('creation and upgrade roll back DDL and version together', () async {
    final dir = Directory.systemTemp.createTempSync('supplier-ddl-');
    final file = File('${dir.path}/data.sqlite');
    var failed = FailingMigrationDatabase(
      NativeDatabase(file),
      'CREATE TABLE products',
    );
    await expectLater(failed.snapshot(), throwsStateError);
    await failed.close();
    var raw = sqlite.sqlite3.open(file.path);
    expect(raw.select('PRAGMA user_version').single['user_version'], 0);
    expect(
      raw.select("SELECT name FROM sqlite_master WHERE type='table'"),
      isEmpty,
    );
    raw.close();
    var db = ProbeDatabase(NativeDatabase(file));
    await db.restore(sampleSnapshot());
    for (final key in contextFields) {
      await db.customStatement('ALTER TABLE quotations DROP COLUMN "$key"');
    }
    await db.customStatement('PRAGMA user_version = 1');
    await db.close();
    failed = FailingMigrationDatabase(
      NativeDatabase(file),
      'ADD COLUMN "${contextFields[1]}"',
    );
    await expectLater(failed.snapshot(), throwsStateError);
    await failed.close();
    raw = sqlite.sqlite3.open(file.path);
    expect(raw.select('PRAGMA user_version').single['user_version'], 1);
    expect(
      raw.select('PRAGMA table_info(quotations)').map((r) => r['name']),
      isNot(contains(contextFields.first)),
    );
    expect(
      raw.select('SELECT price FROM quotations').single['price'],
      '12.340001',
    );
    raw.close();
    db = ProbeDatabase(NativeDatabase(file));
    expect((await db.snapshot())['quotations']!.single['price'], '12.340001');
    expect(
      (await db.customSelect('PRAGMA user_version').getSingle()).read<int>(
        'user_version',
      ),
      2,
    );
    await db.close();
    dir.deleteSync(recursive: true);
  });
  test('merged optional fields rejected before the parser can erase values', () {
    final original = ZipDecoder().decodeBytes(encodeSnapshot(sampleSnapshot()));
    final changed = Archive();
    var mutated = false;
    for (final file in original.files) {
      var content = file.content as List<int>;
      if (file.name.startsWith('xl/worksheets/') &&
          file.name.endsWith('.xml')) {
        final xml = utf8.decode(content);
        if (xml.contains('r="P2"')) {
          mutated = true;
          content = utf8.encode(
            xml.replaceFirst(
              '</worksheet>',
              '<mergeCells count="1"><mergeCell ref="P2:Q2"/></mergeCells></worksheet>',
            ),
          );
        }
      }
      changed.addFile(ArchiveFile(file.name, content.length, content));
    }
    expect(mutated, isTrue);
    expect(
      () => decodeSnapshot(ZipEncoder().encode(changed)!),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'reason',
          contains('merged cells'),
        ),
      ),
    );
  });
  test('invalid Unicode rejected while supplementary characters roundtrip', () {
    for (final value in ['\uD800', '\uDC00', '\uFFFE', '\uFFFF']) {
      final data = sampleSnapshot();
      data['quotations']![0]['project_name'] = value;
      expect(() => normalizeSnapshot(data), throwsFormatException);
    }
    final valid = sampleSnapshot();
    valid['quotations']![0]['project_name'] = '😀𠀀';
    expect(decodeSnapshot(encodeSnapshot(valid)), valid);
  });
  test('inline CRLF is rejected instead of silently normalizing text', () {
    final original = ZipDecoder().decodeBytes(encodeSnapshot(sampleSnapshot()));
    final changed = Archive();
    var mutated = false;
    for (final file in original.files) {
      var content = file.content as List<int>;
      if (file.name.startsWith('xl/worksheets/') &&
          file.name.endsWith('.xml')) {
        final xml = utf8.decode(content);
        content = utf8.encode(
          xml.replaceFirstMapped(RegExp(r'<c r="P2"[^>]*>.*?</c>'), (match) {
            mutated = true;
            return '<c r="P2" t="inlineStr"><is><t>A&#13;&#10;B</t></is></c>';
          }),
        );
      }
      changed.addFile(ArchiveFile(file.name, content.length, content));
    }
    expect(mutated, isTrue);
    expect(
      () => decodeSnapshot(ZipEncoder().encode(changed)!),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'reason',
          contains('P2: inline CRLF'),
        ),
      ),
    );
  });
  test('parent row numbers cannot silently discard or relocate cells', () {
    for (final replacement in [
      '<row r="0"',
      '<row r="1000000000"',
      '<row r="3"',
      '<row r="1"',
      '<row',
    ]) {
      final original = ZipDecoder().decodeBytes(
        encodeSnapshot(sampleSnapshot()),
      );
      final changed = Archive();
      var mutated = false;
      for (final file in original.files) {
        var content = file.content as List<int>;
        if (file.name.startsWith('xl/worksheets/') &&
            file.name.endsWith('.xml')) {
          final xml = utf8.decode(content);
          if (xml.contains('r="P2"')) {
            mutated = true;
            content = utf8.encode(xml.replaceFirst('<row r="2"', replacement));
          }
        }
        changed.addFile(ArchiveFile(file.name, content.length, content));
      }
      expect(mutated, isTrue);
      expect(
        () => decodeSnapshot(ZipEncoder().encode(changed)!),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'reason',
            contains('row'),
          ),
        ),
      );
    }
  });
  group('snapshot model', () {
    test('NFC, exact decimals and project number', () {
      final data = sampleSnapshot();
      data['quotations']![0]['project_name'] = ' Cafe\u0301 ';
      final normalized = normalizeSnapshot(data);
      expect(normalized['quotations']![0]['project_name'], 'Café');
      expect(normalized['quotations']![0]['project_number'], '000123-A');
      expect(decimal('00012.340001', 'price'), '12.340001');
      expect(priceKey('12.340001'), '000000000012340001');
      for (final value in ['1e2', '-1', '1.0000001', '1000000000000']) {
        expect(() => decimal(value, 'price'), throwsFormatException);
      }
    });
    test('strict date timezone and millisecond rules', () {
      expect(parseInquiryTime('2026-09-16T14:30:00.123+08:00'), (
        utc: '2026-09-16T06:30:00.123Z',
        offset: 480,
      ));
      expect(parseInquiryTime('2026-09-16T01:15:00.000+05:45'), (
        utc: '2026-09-15T19:30:00.000Z',
        offset: 345,
      ));
      expect(parseInquiryTime('2026-09-15T16:00:00.000-03:30'), (
        utc: '2026-09-15T19:30:00.000Z',
        offset: -210,
      ));
      for (final value in [
        '2026-09-16T14:30:00',
        '2026-02-30T00:00:00Z',
        '2026-09-16T00:00:00+14:01',
        '2026-09-16T00:00:00.1234Z',
        '2026-09-16T00:00:60Z',
      ]) {
        expect(() => parseInquiryTime(value), throwsFormatException);
      }
    });
    test(
      'null context remains null, field length and missing offset rejected',
      () {
        final data = sampleSnapshot();
        final row = data['quotations']![0];
        for (final key in contextFields) {
          row[key] = null;
        }
        expect(
          normalizeSnapshot(data)['quotations']![0]['inquired_at'],
          isNull,
        );
        row['project_number'] = 'a' * 101;
        expect(() => normalizeSnapshot(data), throwsFormatException);
        row['project_number'] = null;
        row['inquired_at'] = '2026-09-16T00:00:00.000Z';
        expect(() => normalizeSnapshot(data), throwsFormatException);
      },
    );
  });
  group('xlsx', () {
    test('all business data, nulls, project fields and offsets roundtrip', () {
      for (final zone in [480, 345, -210, 0]) {
        final sample = sampleSnapshot();
        sample['quotations']![0]['inquiry_utc_offset_minutes'] = zone;
        expect(decodeSnapshot(encodeSnapshot(sample)), sample);
      }
    });
    test(
      'nontext cell/formula/unknown header/schema and inconsistent offset rejected',
      () {
        for (final value in [IntCellValue(12), FormulaCellValue('1+1')]) {
          final book = Excel.decodeBytes(encodeSnapshot(sampleSnapshot()));
          book['quotations']
                  .cell(CellIndex.indexByColumnRow(columnIndex: 3, rowIndex: 1))
                  .value =
              value;
          expect(() => decodeSnapshot(book.encode()!), throwsFormatException);
        }
        final unknown = Excel.decodeBytes(encodeSnapshot(sampleSnapshot()));
        unknown['quotations']
            .cell(CellIndex.indexByColumnRow(columnIndex: 21, rowIndex: 0))
            .value = TextCellValue(
          'unknown',
        );
        expect(() => decodeSnapshot(unknown.encode()!), throwsFormatException);
        final schema = Excel.decodeBytes(encodeSnapshot(sampleSnapshot()));
        schema['manifest'].cell(CellIndex.indexByString('B2')).value =
            TextCellValue('999');
        expect(() => decodeSnapshot(schema.encode()!), throwsFormatException);
        final offset = Excel.decodeBytes(encodeSnapshot(sampleSnapshot()));
        offset['quotations']
            .cell(CellIndex.indexByColumnRow(columnIndex: 18, rowIndex: 1))
            .value = TextCellValue(
          '0',
        );
        expect(() => decodeSnapshot(offset.encode()!), throwsFormatException);
      },
    );
    test('declared and actual ZIP output bounded', () {
      final bytes = encodeSnapshot(sampleSnapshot());
      expect(
        () => validateZip(bytes, compressedLimit: bytes.length - 1),
        throwsFormatException,
      );
      expect(() => validateZip(bytes, expandedLimit: 1), throwsFormatException);
      final output = BoundedOutput(3);
      output.writeBytes([1, 2, 3]);
      expect(() => output.writeByte(4), throwsFormatException);
      final compressed = Deflate(List.filled(10000, 65)).getBytes();
      expect(
        () => Inflate.stream(InputStream(compressed), BoundedOutput(100)),
        throwsFormatException,
      );
    });
  });
  group('drift storage', () {
    test(
      'file close/reopen, XLSX to empty db, duplicate restore and rollback',
      () async {
        final directory = Directory.systemTemp.createTempSync('supplier-test-');
        final file = File('${directory.path}/data.sqlite');
        final db = ProbeDatabase(NativeDatabase(file));
        final sample = sampleSnapshot();
        final second = Map<String, Object?>.from(sample['quotations']!.first);
        second['id'] = '55555555-5555-4555-8555-555555555555';
        sample['quotations']!.add(second);
        await db.restore(sample);
        await db.close();
        final reopened = ProbeDatabase(NativeDatabase(file));
        final snapshot = await reopened.snapshot();
        expect(snapshot, sample);
        await reopened.close();
        final targetFile = File('${directory.path}/target.sqlite');
        var target = ProbeDatabase(NativeDatabase(targetFile));
        try {
          await expectLater(
            target.restore(
              decodeSnapshot(encodeSnapshot(snapshot)),
              failAfterRows: 1,
            ),
            throwsStateError,
          );
          await target.close();
          target = ProbeDatabase(NativeDatabase(targetFile));
          expect(
            (await target.snapshot()).values.every((r) => r.isEmpty),
            isTrue,
          );
          await target.restore(decodeSnapshot(encodeSnapshot(snapshot)));
          expect(await target.snapshot(), sample);
          await expectLater(target.restore(sample), throwsStateError);
          expect(await target.snapshot(), sample);
        } finally {
          await target.close();
          directory.deleteSync(recursive: true);
        }
      },
    );
    test('memory fallback refuses business write', () async {
      final db = ProbeDatabase(NativeDatabase.memory(), persistent: false);
      try {
        await expectLater(db.restore(sampleSnapshot()), throwsStateError);
      } finally {
        await db.close();
      }
    });
    test(
      'legacy v1 quotation schema adds nullable context without rewrite',
      () async {
        final directory = Directory.systemTemp.createTempSync(
          'supplier-migrate-',
        );
        final file = File('${directory.path}/data.sqlite');
        final db = ProbeDatabase(NativeDatabase(file));
        await db.restore(sampleSnapshot());
        for (final key in contextFields) {
          await db.customStatement('ALTER TABLE quotations DROP COLUMN "$key"');
        }
        await db.customStatement('PRAGMA user_version = 1');
        await db.close();
        final upgraded = ProbeDatabase(NativeDatabase(file));
        try {
          final row = (await upgraded.snapshot())['quotations']!.single;
          expect(row['price'], '12.340001');
          for (final key in contextFields) {
            expect(row[key], isNull);
          }
        } finally {
          await upgraded.close();
          directory.deleteSync(recursive: true);
        }
      },
    );
  });
  test(
    'selected contact needs snapshot and local time remains representable',
    () {
      final missing = sampleSnapshot();
      missing['quotations']![0]['contact_snapshot'] = null;
      expect(() => normalizeSnapshot(missing), throwsFormatException);
      for (final pair in [
        ('0001-01-01T00:00:00.000Z', -840),
        ('9999-12-31T23:59:59.999Z', 840),
      ]) {
        final data = sampleSnapshot();
        data['quotations']![0]['inquired_at'] = pair.$1;
        data['quotations']![0]['inquiry_utc_offset_minutes'] = pair.$2;
        expect(() => normalizeSnapshot(data), throwsFormatException);
      }
    },
  );
  test('forged small ZIP metadata cannot bypass actual expanded limit', () {
    final archive = Archive()
      ..addFile(ArchiveFile('bomb.txt', 10000, List.filled(10000, 65)));
    final bytes = Uint8List.fromList(ZipEncoder().encode(archive)!);
    final view = ByteData.sublistView(bytes);
    for (var i = 0; i < bytes.length - 28; i++) {
      if (view.getUint32(i, Endian.little) == 0x02014b50) {
        view.setUint32(i + 24, 1, Endian.little);
      }
      if (view.getUint32(i, Endian.little) == 0x04034b50) {
        view.setUint32(i + 22, 1, Endian.little);
      }
    }
    expect(() => validateZip(bytes, expandedLimit: 100), throwsFormatException);
  });
  test(
    'formula tagged as shared text is rejected before library cache coercion',
    () {
      final original = ZipDecoder().decodeBytes(
        encodeSnapshot(sampleSnapshot()),
      );
      final changed = Archive();
      for (final file in original.files) {
        var content = file.content as List<int>;
        if (file.name.startsWith('xl/worksheets/') &&
            file.name.endsWith('.xml')) {
          final xml = utf8
              .decode(content)
              .replaceFirstMapped(
                RegExp(r'(<c\s[^>]*>)'),
                (match) => '${match[1]}<f>1+1</f>',
              );
          content = utf8.encode(xml);
        }
        changed.addFile(ArchiveFile(file.name, content.length, content));
      }
      expect(
        () => decodeSnapshot(ZipEncoder().encode(changed)!),
        throwsFormatException,
      );
    },
  );
  test(
    'out-of-range sparse cell coordinates rejected before XLSX allocation',
    () {
      final original = ZipDecoder().decodeBytes(
        encodeSnapshot(sampleSnapshot()),
      );
      final changed = Archive();
      for (final file in original.files) {
        var content = file.content as List<int>;
        if (file.name.startsWith('xl/worksheets/') &&
            file.name.endsWith('.xml')) {
          content = utf8.encode(
            utf8.decode(content).replaceFirst('r="A1"', 'r="XFD1048576"'),
          );
        }
        changed.addFile(ArchiveFile(file.name, content.length, content));
      }
      expect(
        () => decodeSnapshot(ZipEncoder().encode(changed)!),
        throwsFormatException,
      );
    },
  );
}
