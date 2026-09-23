import 'dart:convert';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import '../contracts.dart';
import 'bounded_zip.dart';
import 'business_mapping.dart';
import 'xlsx_reader.dart';
import 'xlsx_staging.dart';

/// Byte limits only tighten this adapter's bounded single-volume ceilings.
/// A separate coordinator owns snapshots, automatic volume splitting and bundles.
final class XlsxExportPolicy {
  const XlsxExportPolicy.syncVolume({
    this.maxDataRows = 5000,
    this.zipLimits = const XlsxZipLimits(),
  }) : name = 'sync-volume';
  const XlsxExportPolicy.boundedBusiness({
    required this.maxDataRows,
    this.zipLimits = const XlsxZipLimits(),
  }) : name = 'bounded-business';
  final String name;
  final int maxDataRows;
  final XlsxZipLimits zipLimits;
  void _validate() {
    if (maxDataRows < 1 ||
        maxDataRows > (name == 'sync-volume' ? 5000 : 1048575) ||
        zipLimits.compressedBytes < 22 ||
        zipLimits.compressedBytes > 8 * 1024 * 1024 ||
        zipLimits.expandedBytes < 1 ||
        zipLimits.expandedBytes > 32 * 1024 * 1024 ||
        zipLimits.entries < 6 ||
        zipLimits.entries > 2048) {
      throw ArgumentError('Invalid bounded XLSX export policy');
    }
  }
}

/// All cells are textual. Null emits an explicit blank cell; '' emits a text
/// cell with an empty value. Row width must equal headers: absent columns are a
/// separate mapping decision, never silently padded or inferred from headings.
final class BoundedXlsxWriter {
  const BoundedXlsxWriter();
  Future<BoundedXlsxVolume> encodeVolume({
    required Stream<List<String?>> rows,
    required List<String> headers,
    required XlsxStaging validation,
    String sheetName = '业务数据',
    XlsxExportPolicy policy = const XlsxExportPolicy.syncVolume(),
    Future<void> Function()? checkpoint,
  }) async {
    policy._validate();
    if (headers.isEmpty ||
        headers.length > 16384 ||
        headers.any((h) => h.isEmpty) ||
        headers.toSet().length != headers.length) {
      throw ArgumentError('Headers must be nonempty, unique and within XFD');
    }
    _text(sheetName, 'sheet name');
    if (sheetName.isEmpty ||
        sheetName.length > 31 ||
        sheetName.trim().isEmpty ||
        RegExp(r'[\r\n\t]').hasMatch(sheetName) ||
        RegExp(r'[\[\]:*?/\\]').hasMatch(sheetName) ||
        sheetName.startsWith("'") ||
        sheetName.endsWith("'") ||
        RegExp(r'_x[0-9a-fA-F]{4}_').hasMatch(sheetName)) {
      throw ArgumentError('Unsupported worksheet name');
    }
    final columns = List<String>.unmodifiable(headers);
    await checkpoint?.call();
    final zipOutput = _LimitedOutput(
      policy.zipLimits.compressedBytes,
      'compressed',
    );
    final encoder = ZipEncoder()
      ..startEncode(zipOutput, modified: DateTime.utc(1980));
    var expanded = 0, entries = 0;
    void addPart(String name, List<int> bytes) {
      if (++entries > policy.zipLimits.entries ||
          bytes.length > policy.zipLimits.expandedBytes - expanded) {
        _limit('expanded or entry budget');
      }
      expanded += bytes.length;
      encoder.addFile(ArchiveFile(name, bytes.length, bytes), autoClose: true);
    }

    const mainNs = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main';
    const relationNs =
        'http://schemas.openxmlformats.org/officeDocument/2006/relationships';
    const packageNs =
        'http://schemas.openxmlformats.org/package/2006/relationships';
    addPart(
      '[Content_Types].xml',
      utf8.encode(
        '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/></Types>',
      ),
    );
    addPart(
      '_rels/.rels',
      utf8.encode(
        '<Relationships xmlns="$packageNs"><Relationship Id="office" Type="$relationNs/officeDocument" Target="xl/workbook.xml"/></Relationships>',
      ),
    );
    addPart(
      'xl/_rels/workbook.xml.rels',
      utf8.encode(
        '<Relationships xmlns="$packageNs"><Relationship Id="sheet" Type="$relationNs/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="styles" Type="$relationNs/styles" Target="styles.xml"/></Relationships>',
      ),
    );
    addPart(
      'xl/workbook.xml',
      utf8.encode(
        '<workbook xmlns="$mainNs" xmlns:r="$relationNs"><workbookPr date1904="0"/><sheets><sheet name="${_xml(sheetName)}" sheetId="1" r:id="sheet"/></sheets></workbook>',
      ),
    );
    addPart(
      'xl/styles.xml',
      utf8.encode(
        '<styleSheet xmlns="$mainNs"><fonts count="1"><font><sz val="11"/><name val="Calibri"/></font></fonts><fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills><borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="2"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="49" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/></cellXfs><cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>',
      ),
    );
    final sheet = _LimitedOutput(
      policy.zipLimits.expandedBytes - expanded,
      'expanded',
    );
    void write(String text) => sheet.writeBytes(utf8.encode(text));
    write('<worksheet xmlns="$mainNs"><sheetData>');
    final expected = _CellDigest();
    var rowNumber = 0, cellCount = 0;
    Future<void> writeRow(List<String?> input) async {
      if (input.length != columns.length) {
        throw ArgumentError(
          'Row width differs from the explicit column contract',
        );
      }
      final values = List<String?>.of(input);
      rowNumber++;
      write('<row r="$rowNumber">');
      for (var column = 0; column < values.length; column++) {
        final coordinate = '${_column(column + 1)}$rowNumber',
            value = values[column];
        if (value == null) {
          write('<c r="$coordinate"/>');
          expected.add(coordinate, BusinessCellKind.blank, '');
        } else {
          _text(value, coordinate);
          write(
            '<c r="$coordinate" t="inlineStr" s="1"><is><t xml:space="preserve">${_xml(_xstring(value))}</t></is></c>',
          );
          expected.add(coordinate, BusinessCellKind.text, value);
        }
        if (++cellCount % 256 == 0) await checkpoint?.call();
      }
      write('</row>');
      if (rowNumber % 64 == 0) await checkpoint?.call();
    }

    await writeRow(columns);
    await for (final row in rows) {
      if (rowNumber > policy.maxDataRows) _limit('data row budget');
      await writeRow(row);
    }
    write('</sheetData></worksheet>');
    addPart('xl/worksheets/sheet1.xml', sheet.getBytes());
    encoder.endEncode();
    final bytes = Uint8List.fromList(zipOutput.getBytes());
    final volume = BoundedXlsxVolume._(
      bytes,
      rowNumber - 1,
      expanded,
      policy.name,
    );
    await checkpoint?.call();
    final profile = await BoundedXlsxReader(maxDataRows: policy.maxDataRows)
        .readVolume(
          volume,
          validation,
          sheetName: sheetName,
          checkpoint: checkpoint,
        );
    if (profile.rows != rowNumber ||
        profile.cells != cellCount ||
        profile.sourceDigest != volume.sha256Hex) {
      throw const DomainFailure(
        'XLSX_SELF_CHECK',
        'Export counts or bytes failed self-check',
      );
    }
    final actual = _CellDigest();
    var afterRow = 0;
    while (true) {
      final page = await validation.rowsPage(afterRow: afterRow);
      if (page.isEmpty) break;
      for (final row in page) {
        var afterColumn = 0;
        while (true) {
          final cells = await validation.cellsPage(
            row.row,
            afterColumn: afterColumn,
          );
          if (cells.isEmpty) break;
          for (final cell in cells) {
            actual.add(cell.cell.coordinate, cell.cell.kind, cell.cell.lexical);
          }
          afterColumn = cells.last.column;
          await checkpoint?.call();
        }
      }
      afterRow = page.last.row;
    }
    if (actual.finish() != expected.finish()) {
      throw const DomainFailure(
        'XLSX_SELF_CHECK',
        'Export raw cells differ after reading back',
      );
    }
    return volume;
  }
}

/// A validated single volume, never an accumulated outer bundle. Encoding owns
/// no caller output. If encoding fails, callers still own any pre-opened target.
/// publishTo assumes ownership of its target and aborts it on any failure.
final class BoundedXlsxVolume implements InputSource {
  BoundedXlsxVolume._(
    this._bytes,
    this.dataRows,
    this.expandedBytes,
    this.policy,
  ) : sha256Hex = sha256.convert(_bytes).toString();
  final Uint8List _bytes;
  final int dataRows, expandedBytes;
  final String policy, sha256Hex;
  int get byteLength => _bytes.length;
  @override
  String get displayName => '业务数据.xlsx';
  @override
  Future<int> length() async => byteLength;
  @override
  Stream<List<int>> openRange(int start, int endExclusive) async* {
    if (start < 0 || endExclusive < start || endExclusive > byteLength) {
      throw RangeError('Invalid XLSX range');
    }
    for (var offset = start; offset < endExclusive; offset += 65536) {
      // Copies protect the validated content from a mutating caller/sink.
      yield _bytes.sublist(
        offset,
        (offset + 65536).clamp(offset, endExclusive),
      );
    }
  }

  Future<void> publishTo(
    OutputTarget target, {
    Future<void> Function()? checkpoint,
  }) async {
    try {
      Stream<List<int>> chunks() async* {
        await for (final chunk in openRange(0, byteLength)) {
          await checkpoint?.call();
          yield chunk;
        }
      }

      await target.write(chunks());
      await checkpoint?.call();
      await target.publish();
    } catch (primary, stack) {
      try {
        await target.abort();
      } catch (cleanup, cleanupStack) {
        throw DomainFailure(
          'XLSX_OUTPUT_CLEANUP',
          'Publishing and abort failed',
          cause: (
            primary: primary,
            stack: stack,
            cleanup: cleanup,
            cleanupStack: cleanupStack,
          ),
        );
      }
      Error.throwWithStackTrace(primary, stack);
    }
  }
}

void _text(String text, String coordinate) {
  RawBusinessCell(
    coordinate: coordinate,
    kind: BusinessCellKind.text,
    lexical: text,
  );
}

// Match only the leading underscore, so overlapping literal sequences such as
// _x005F_x0041_ each get their own escape. The reader decodes exactly once.
String _xstring(String text) => text
    .replaceAll(RegExp(r'_(?=x[0-9a-fA-F]{4}_)'), '_x005F_')
    .replaceAll('\r', '_x000D_');
String _xml(String text) => text
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');
String _column(int number) {
  var result = '';
  while (number > 0) {
    number--;
    result = String.fromCharCode(65 + number % 26) + result;
    number ~/= 26;
  }
  return result;
}

Never _limit(String message) =>
    throw DomainFailure('XLSX_VOLUME_LIMIT', message);

final class _LimitedOutput extends OutputStream {
  _LimitedOutput(this.limit, this.kind) : super(size: 1024);
  final int limit;
  final String kind;
  void _check(int added) {
    if (added < 0 || length + added > limit) _limit('$kind byte budget');
  }

  @override
  void writeByte(int value) {
    _check(1);
    super.writeByte(value);
  }

  @override
  void writeBytes(List<int> bytes, [int? len]) {
    _check(len ?? bytes.length);
    super.writeBytes(bytes, len);
  }

  @override
  void writeInputStream(InputStreamBase stream) {
    _check(stream.length);
    super.writeInputStream(stream);
  }

  @override
  void writeUint16(int value) {
    _check(2);
    super.writeUint16(value);
  }

  @override
  void writeUint32(int value) {
    _check(4);
    super.writeUint32(value);
  }

  @override
  void writeUint64(int value) {
    _check(8);
    super.writeUint64(value);
  }
}

final class _DigestSink implements Sink<Digest> {
  String? value;
  @override
  void add(Digest value) {
    this.value = value.toString();
  }

  @override
  void close() {}
}

final class _CellDigest {
  _CellDigest() {
    _sink = sha256.startChunkedConversion(_result);
  }
  final _result = _DigestSink();
  late ByteConversionSink _sink;
  void add(String coordinate, BusinessCellKind kind, String lexical) => _sink
      .add(utf8.encode('${jsonEncode([coordinate, kind.name, lexical])}\n'));
  String finish() {
    _sink.close();
    return _result.value!;
  }
}

/// Stable keys, not translated headings, are the mapping contract. This slice
/// defines the quotation template; an export service supplies validated values,
/// canonical JSON for contact_snapshot and an explicit missing-context display.
final class BusinessXlsxColumn {
  const BusinessXlsxColumn(this.key, this.heading);
  final String key, heading;
}

const businessQuotationTemplateVersion = '1';
const businessQuotationColumns = <BusinessXlsxColumn>[
  BusinessXlsxColumn('record_id', '记录ID'),
  BusinessXlsxColumn('record_type', '记录类型'),
  BusinessXlsxColumn('export_revision_id', '导出时修订ID'),
  BusinessXlsxColumn('template_version', '导出模板版本'),
  BusinessXlsxColumn('supplier_id', '供应商ID'),
  BusinessXlsxColumn('supplier_name', '供应商名称'),
  BusinessXlsxColumn('product_id', '产品ID'),
  BusinessXlsxColumn('product_name', '产品名称'),
  BusinessXlsxColumn('product_brand', '品牌'),
  BusinessXlsxColumn('product_model', '型号'),
  BusinessXlsxColumn('product_specification', '规格'),
  BusinessXlsxColumn('price', '价格'),
  BusinessXlsxColumn('currency', '币种'),
  BusinessXlsxColumn('tax_mode', '含税方式'),
  BusinessXlsxColumn('tax_rate', '税率'),
  BusinessXlsxColumn('unit_snapshot', '报价单位'),
  BusinessXlsxColumn('min_qty', '最小数量'),
  BusinessXlsxColumn('quoted_on', '报价日期'),
  BusinessXlsxColumn('valid_until', '有效期至'),
  BusinessXlsxColumn('lead_time_days', '交货天数'),
  BusinessXlsxColumn('contact_id', '联系人ID'),
  BusinessXlsxColumn('contact_snapshot', '联系人快照'),
  BusinessXlsxColumn('project_name', '项目名称'),
  BusinessXlsxColumn('project_number', '项目编号'),
  BusinessXlsxColumn('inquiry_location', '询价地点'),
  BusinessXlsxColumn('inquirer_name', '询价人'),
  BusinessXlsxColumn('inquiry_precision', '询价时间精度'),
  BusinessXlsxColumn('inquiry_date', '询价日期'),
  BusinessXlsxColumn('inquired_at', '询价时间（UTC）'),
  BusinessXlsxColumn('inquiry_utc_offset_minutes', '询价原时区偏移（分钟）'),
  BusinessXlsxColumn('capture_mode', '资料模式'),
  BusinessXlsxColumn('missing_context', '缺失信息提示'),
  BusinessXlsxColumn('notes', '备注'),
];
