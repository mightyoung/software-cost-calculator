import 'dart:convert';
import 'package:archive/archive.dart';
import 'package:excel/excel.dart';
import 'package:xml/xml.dart';
import 'model.dart';

const snapshotFormat = 'supplier-inquiry-stage0-snapshot';
const maxCompressed = 20 * 1024 * 1024;
const maxExpanded = 200 * 1024 * 1024;

class BoundedOutput extends OutputStream {
  BoundedOutput(this.limit);
  final int limit;
  void check(int n) {
    if (n < 0 || length + n > limit) {
      invalid('xlsx.zip', 'expanded byte limit exceeded');
    }
  }

  @override
  void writeByte(int value) {
    check(1);
    super.writeByte(value);
  }

  @override
  void writeBytes(List<int> bytes, [int? len]) {
    check(len ?? bytes.length);
    super.writeBytes(bytes, len);
  }

  @override
  void writeInputStream(InputStreamBase stream) {
    check(stream.length);
    super.writeInputStream(stream);
  }
}

void validateZip(
  List<int> bytes, {
  int compressedLimit = maxCompressed,
  int expandedLimit = maxExpanded,
}) {
  if (bytes.length > compressedLimit) {
    invalid('xlsx.zip', 'compressed byte limit exceeded');
  }
  final directory = ZipDirectory.read(InputStream(bytes));
  if (directory.fileHeaders.length > 2048) {
    invalid('xlsx.zip', 'too many entries');
  }
  var declared = 0;
  var actual = 0;
  final names = <String>{};
  for (final header in directory.fileHeaders) {
    final file = header.file!;
    if (!names.add(file.filename)) invalid('xlsx.zip', 'duplicate entry');
    if (file.flags & 1 != 0) invalid('xlsx.zip', 'encrypted entry unsupported');
    declared += header.uncompressedSize!;
    if (declared > expandedLimit) {
      invalid('xlsx.zip', 'declared expanded byte limit exceeded');
    }
    final output = BoundedOutput(expandedLimit - actual);
    if (file.compressionMethod == 0) {
      output.writeInputStream(file.rawContent!);
    } else if (file.compressionMethod == 8) {
      Inflate.stream(file.rawContent!, output);
    } else {
      invalid('xlsx.zip', 'compression method unsupported');
    }
    final content = output.getBytes();
    actual += content.length;
    if (content.length != header.uncompressedSize ||
        getCrc32(content) != header.crc32) {
      invalid('xlsx.zip', 'size or CRC mismatch');
    }
    if (file.filename.startsWith('xl/worksheets/') &&
        file.filename.endsWith('.xml')) {
      final xml = XmlDocument.parse(utf8.decode(content));
      if (xml.descendants.whereType<XmlElement>().any(
        (e) => e.name.local == 'mergeCell',
      )) {
        invalid('xlsx.${file.filename}', 'merged cells unsupported');
      }
      final coordinates = <String>{};
      final rowNumbers = <String>{};
      for (final row in xml.descendants.whereType<XmlElement>().where(
        (e) => e.name.local == 'row',
      )) {
        final number = row.getAttribute('r') ?? '';
        if (!RegExp(r'^[1-9][0-9]{0,5}$').hasMatch(number) ||
            int.parse(number) > 100001 ||
            !rowNumbers.add(number)) {
          invalid('xlsx.${file.filename}', 'invalid or duplicate row number');
        }
      }
      for (final cell in xml.descendants.whereType<XmlElement>().where(
        (e) => e.name.local == 'c',
      )) {
        final address = cell.getAttribute('r') ?? '';
        final coordinate = RegExp(
          r'^([A-Z]{1,3})([1-9][0-9]{0,5})$',
        ).firstMatch(address);
        if (coordinate == null || !coordinates.add(address)) {
          invalid(
            'xlsx.${file.filename}',
            'invalid or duplicate cell coordinate',
          );
        }
        final parent = cell.parent;
        if (parent is! XmlElement ||
            parent.name.local != 'row' ||
            parent.getAttribute('r') != coordinate[2]) {
          invalid(
            'xlsx.${file.filename}.$address',
            'cell and parent row disagree',
          );
        }
        var column = 0;
        for (final letter in coordinate[1]!.codeUnits) {
          column = column * 26 + letter - 64;
        }
        if (int.parse(coordinate[2]!) > 100001 ||
            column > columns['quotations']!.length) {
          invalid(
            'xlsx.${file.filename}.$address',
            'cell coordinate outside snapshot bounds',
          );
        }
        if (cell.descendants.whereType<XmlElement>().any(
          (e) => e.name.local == 'f',
        )) {
          invalid(
            'xlsx.${file.filename}.${cell.getAttribute('r')}',
            'formula forbidden even with text cache',
          );
        }
        final type = cell.getAttribute('t');
        if (type != 's' &&
            type != 'inlineStr' &&
            (type != null ||
                cell.childElements.any((e) => e.name.local == 'v'))) {
          invalid('xlsx.${file.filename}.$address', 'text cell required');
        }
        if (cell.getAttribute('t') == 'inlineStr' &&
            cell.descendants
                .whereType<XmlElement>()
                .where((e) => e.name.local == 't')
                .any((e) => e.innerText.contains('\r\n'))) {
          invalid(
            'xlsx.${file.filename}.$address',
            'inline CRLF unsupported by selected XLSX parser',
          );
        }
        if (cell.getAttribute('t') == 'inlineStr' &&
            cell.descendants
                    .whereType<XmlElement>()
                    .where((e) => e.name.local == 't')
                    .length >
                1) {
          invalid(
            'xlsx.${file.filename}.${cell.getAttribute('r')}',
            'rich inline text unsupported by selected XLSX parser',
          );
        }
      }
    }
  }
}

List<int> encodeSnapshot(Snapshot snapshot) {
  final data = normalizeSnapshot(snapshot);
  final book = Excel.createExcel();
  book.rename('Sheet1', 'manifest');
  book['manifest'].appendRow([
    TextCellValue('format'),
    TextCellValue(snapshotFormat),
  ]);
  book['manifest'].appendRow([
    TextCellValue('schema_version'),
    TextCellValue('2'),
  ]);
  for (final table in columns.keys) {
    final sheet = book[table];
    sheet.appendRow(columns[table]!.map(TextCellValue.new).toList());
    for (final row in data[table]!) {
      sheet.appendRow(
        columns[table]!.map((key) {
          final value = cellText(row, key);
          return value == null ? null : TextCellValue(value);
        }).toList(),
      );
    }
  }
  final bytes = book.encode()!;
  validateZip(bytes);
  return bytes;
}

Snapshot decodeSnapshot(List<int> bytes) {
  validateZip(bytes);
  final book = Excel.decodeBytes(_compatibleWpsStyles(bytes));
  if (book.tables.length != columns.length + 1 ||
      !['manifest', ...columns.keys].every(book.tables.containsKey)) {
    invalid('xlsx', 'unknown/missing sheet');
  }
  String? read(Data? cell, String where) {
    final value = cell?.value;
    if (value == null) return null;
    if (value is! TextCellValue) {
      invalid(where, 'text cell required; formulas/numbers/errors unsupported');
    }
    return value.value.toString().isEmpty ? null : value.value.toString();
  }

  final manifest = book['manifest'].rows;
  if (manifest.length != 2 ||
      manifest.any((r) => r.length != 2) ||
      read(manifest[0][0], 'manifest') != 'format' ||
      read(manifest[0][1], 'manifest') != snapshotFormat ||
      read(manifest[1][0], 'manifest') != 'schema_version' ||
      read(manifest[1][1], 'manifest') != '2') {
    invalid('manifest', 'unsupported format/schema');
  }
  final result = <String, List<Row>>{};
  for (final table in columns.keys) {
    final sheet = book[table];
    final keys = columns[table]!;
    if (sheet.maxRows > 100001 || sheet.maxColumns != keys.length) {
      invalid(table, 'row/column limit or unknown/missing header');
    }
    final rows = sheet.rows;
    if (rows.isEmpty ||
        keys.asMap().entries.any(
          (e) => read(rows.first[e.key], '$table header') != e.value,
        )) {
      invalid(table, 'missing/reordered/unknown header');
    }
    result[table] = [];
    for (var index = 1; index < rows.length; index++) {
      final row = <String, Object?>{};
      for (var col = 0; col < keys.length; col++) {
        final key = keys[col];
        final value = read(
          col < rows[index].length ? rows[index][col] : null,
          '$table!R${index + 1}C${col + 1} ($key)',
        );
        if (value == null) {
          row[key] = null;
        } else if (jsonFields.contains(key)) {
          row[key] = jsonDecode(value);
        } else if (integerFields.contains(key)) {
          if (!RegExp(r'^-?\d+$').hasMatch(value)) {
            invalid(key, 'integer text required');
          }
          row[key] = int.parse(value);
        } else {
          row[key] = value;
        }
      }
      if (row.values.every((v) => v == null)) continue;
      if (table == 'quotations' && row['inquired_at'] != null) {
        final parsed = parseInquiryTime(row['inquired_at'] as String);
        if (row['inquiry_utc_offset_minutes'] != null &&
            row['inquiry_utc_offset_minutes'] != parsed.offset) {
          invalid('inquiry_utc_offset_minutes', 'does not match time offset');
        }
        row['inquired_at'] = parsed.utc;
        row['inquiry_utc_offset_minutes'] = parsed.offset;
      }
      result[table]!.add(row);
    }
  }
  return normalizeSnapshot(result);
}

// excel 4.0.6 rejects WPS's unused built-in accounting format declarations.
// Preserve every cell and all other styles; unsupported variants fail explicitly.
List<int> _compatibleWpsStyles(List<int> bytes) {
  final archive = ZipDecoder().decodeBytes(bytes);
  final styles = archive.findFile('xl/styles.xml');
  if (styles == null) return bytes;
  final xml = XmlDocument.parse(utf8.decode(styles.content as List<int>));
  final declarations = xml.rootElement.childElements
      .where((e) => e.name.local == 'numFmts')
      .expand((e) => e.childElements.where((c) => c.name.local == 'numFmt'))
      .toList();
  final low = declarations.where((e) {
    final id = int.tryParse(e.getAttribute('numFmtId') ?? '');
    if (id == null) invalid('xlsx.styles', 'invalid format identifier');
    return id < 164;
  }).toList();
  if (low.isEmpty) return bytes;
  const supported = {41, 42, 43, 44};
  final ids = low.map((e) => int.parse(e.getAttribute('numFmtId')!)).toSet();
  if (ids.length != low.length || !ids.every(supported.contains)) {
    invalid('xlsx.styles', 'unsupported built-in format declaration');
  }
  final used = xml.descendants
      .whereType<XmlElement>()
      .where((e) => e.name.local == 'cellXfs')
      .expand((e) => e.childElements)
      .map((e) => int.tryParse(e.getAttribute('numFmtId') ?? '0'));
  if (used.any(ids.contains)) {
    invalid('xlsx.styles', 'built-in override used by cell style');
  }
  final bases = xml.descendants
      .whereType<XmlElement>()
      .where((e) => e.name.local == 'cellStyleXfs')
      .expand((e) => e.childElements)
      .toList();
  for (final style
      in xml.descendants
          .whereType<XmlElement>()
          .where((e) => e.name.local == 'cellXfs')
          .expand((e) => e.childElements)) {
    final base = int.tryParse(style.getAttribute('xfId') ?? '0');
    if (base == null ||
        base < 0 ||
        base >= bases.length ||
        ids.contains(
          int.tryParse(bases[base].getAttribute('numFmtId') ?? '0'),
        )) {
      invalid('xlsx.styles', 'unsupported inherited built-in override');
    }
  }
  for (final node in low) {
    node.parent!.children.remove(node);
  }
  for (final node in xml.descendants.whereType<XmlElement>().where(
    (e) => e.name.local == 'numFmts',
  )) {
    node.setAttribute('count', node.childElements.length.toString());
  }
  final result = Archive();
  for (final file in archive.files) {
    final content = file.name == 'xl/styles.xml'
        ? utf8.encode(xml.toXmlString())
        : file.content as List<int>;
    result.addFile(ArchiveFile(file.name, content.length, content));
  }
  return ZipEncoder().encode(result)!;
}
