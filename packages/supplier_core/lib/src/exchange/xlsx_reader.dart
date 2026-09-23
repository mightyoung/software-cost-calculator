import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:xml/xml_events.dart';
import '../contracts.dart';
import 'bounded_zip.dart';
import 'business_mapping.dart';
import 'xlsx_staging.dart';

const _sheetNs = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main';
const _relationNs =
    'http://schemas.openxmlformats.org/officeDocument/2006/relationships';
const _calcNs =
    'http://schemas.microsoft.com/office/spreadsheetml/2018/calcfeatures';
const _mcNs = 'http://schemas.openxmlformats.org/markup-compatibility/2006';
const _slicerNs =
    'http://schemas.microsoft.com/office/spreadsheetml/2009/9/main';
const _slicerExtension = '{EB79DEF2-80B8-43e5-95BD-54CBDDF9020C}';
const _calcExtension = '{B58B0392-4F1F-4190-BB64-5DF3571DCE5F}';
const _packageNs =
    'http://schemas.openxmlformats.org/package/2006/relationships';

final class XlsxProfile {
  const XlsxProfile({
    required this.sheetName,
    required this.sheetPath,
    required this.date1904,
    required this.rows,
    required this.cells,
    required this.sharedStrings,
    required this.sourceDigest,
    required this.dataRowLimit,
  });
  final String sheetName, sheetPath, sourceDigest;
  final bool date1904;

  /// Actual row elements, including the header. Declared dimensions are ignored.
  final int rows, cells, sharedStrings, dataRowLimit;
  Map<String, Object?> toJson() => {
    'sheet_name': sheetName,
    'sheet_path': sheetPath,
    'date1904': date1904,
    'rows': rows,
    'cells': cells,
    'shared_strings': sharedStrings,
    'source_digest': sourceDigest,
    'profile': 'transitional-bounded-entry-v1',
    'data_row_limit': dataRowLimit,
    'row_policy': dataRowLimit == 5000 ? 'sync-volume' : 'explicit',
  };
}

/// One bounded XLSX volume (default: 5000 data rows plus one header). This is not
/// the ordinary-large-workbook adapter. Entry bytes/text are bounded by the
/// existing 32 MiB expanded-volume limit; XML events never build a worksheet DOM.
final class BoundedXlsxReader {
  const BoundedXlsxReader({this.maxDataRows = 5000});

  /// Discovery only: selecting a sheet still requires full readVolume validation.
  Future<List<String>> sheetNames(InputSource input) async {
    final zip = await BoundedXlsxZip.read(input);
    final names = <String>{};
    await for (final part in zip.expand()) {
      if (part.name != 'xl/workbook.xml') continue;
      for (final token in _tokens(part.bytes, _sheetNs, 'workbook')) {
        if (!token.start || token.name != 'sheet') continue;
        final name = token.attrs['name'];
        if (token.parent != 'sheets' ||
            name == null ||
            name.isEmpty ||
            name.length > 31 ||
            !names.add(name) ||
            names.length > 1024) {
          _bad('Invalid or duplicate sheet');
        }
      }
    }
    if (names.isEmpty) _bad('Workbook has no sheets');
    return List.unmodifiable(names);
  }

  /// Explicit row policy. The default is the sync volume contract. A future
  /// ordinary-workbook service must choose its own budget and entry adapter;
  /// changing this does not relax the compressed/expanded ZIP bounds.
  final int maxDataRows;
  Future<XlsxProfile> readVolume(
    InputSource input,
    XlsxStaging staging, {
    String? sheetName,
    Future<void> Function()? checkpoint,
  }) async {
    if (maxDataRows < 1 || maxDataRows > 1048575) {
      throw RangeError.range(maxDataRows, 1, 1048575, 'maxDataRows');
    }
    // Checkpoints run in the caller zone, not the staging transaction's Drift
    // zone. They may inspect the separate business JobStore; never re-enter this
    // isolated staging database or start untracked asynchronous work.
    final callerZone = Zone.current;
    Future<void> check() => callerZone.run(() async {
      await checkpoint?.call();
    });
    await check();
    final source = _HashedSource(input, check);
    final zip = await BoundedXlsxZip.read(source);
    final names = zip.names.toSet();
    const first = [
      '[Content_Types].xml',
      '_rels/.rels',
      'xl/_rels/workbook.xml.rels',
      'xl/workbook.xml',
      'xl/sharedStrings.xml',
    ];
    if (!names.containsAll(first.take(4))) {
      _bad('Required workbook parts are missing');
    }
    await staging.begin();
    try {
      return await staging.transaction(() async {
        var date1904 = false, selectedPath = '', selectedName = '';
        var stringCount = 0, rowCount = 0, cellCount = 0, selectedSeen = false;
        final relationships = <String, ({String type, String target})>{};
        final cache = <int, String>{};
        Future<String> shared(int index) async {
          final cached = cache.remove(index);
          final value = cached ?? await staging.stringAt(index);
          cache[index] = value;
          if (cache.length > 32) cache.remove(cache.keys.first);
          return value;
        }

        await for (final part in zip.expand(
          order: [
            ...first.where(names.contains),
            ...names.where((n) => !first.contains(n)),
          ],
        )) {
          await check();
          if (part.name == '[Content_Types].xml') {
            _tokens(
              part.bytes,
              'http://schemas.openxmlformats.org/package/2006/content-types',
              'Types',
            ).drain();
          } else if (part.name == '_rels/.rels' ||
              part.name == 'xl/_rels/workbook.xml.rels') {
            var office = 0;
            for (final token in _tokens(
              part.bytes,
              _packageNs,
              'Relationships',
            )) {
              if (token.start && token.name == 'Relationship') {
                if (token.parent != 'Relationships') {
                  _bad('Misplaced relationship');
                }
                final id = token.attrs['Id'],
                    type = token.attrs['Type'],
                    target = token.attrs['Target'];
                if (id == null ||
                    type == null ||
                    target == null ||
                    token.attrs['TargetMode'] == 'External') {
                  _bad('Invalid or external relationship');
                }
                if (part.name == '_rels/.rels') {
                  if (type == '$_relationNs/officeDocument') {
                    office++;
                    if (target != 'xl/workbook.xml' &&
                        target != '/xl/workbook.xml') {
                      _bad('Unsupported workbook path');
                    }
                  }
                } else {
                  if (relationships.length >= 2048 ||
                      relationships.containsKey(id)) {
                    _bad('Duplicate or excessive relationships');
                  }
                  final path = _target(target);
                  if (!names.contains(path)) {
                    _bad('Missing relationship target $path');
                  }
                  if (type == '$_relationNs/sharedStrings' &&
                      path != 'xl/sharedStrings.xml') {
                    _bad('Unsupported shared strings path');
                  }
                  relationships[id] = (type: type, target: path);
                }
              }
            }
            if (part.name == '_rels/.rels' && office != 1) {
              _bad('Workbook relationship is not unique');
            }
          } else if (part.name == 'xl/workbook.xml') {
            final sheets = <String>{};
            var properties = false;
            for (final token in _tokens(part.bytes, _sheetNs, 'workbook')) {
              if (!token.start) continue;
              if (token.name == 'workbookPr') {
                if (properties || token.parent != 'workbook') {
                  _bad('Duplicate or misplaced workbook properties');
                }
                properties = true;
                final date = token.attrs['date1904'];
                if (date != null &&
                    !['true', 'false', '1', '0'].contains(date)) {
                  _bad('Invalid date1904');
                }
                date1904 = date == '1' || date == 'true';
              } else if (token.name == 'sheet') {
                final name = token.attrs['name'],
                    id = token.attrs['{$_relationNs}id'];
                if (token.parent != 'sheets' ||
                    name == null ||
                    name.length > 31 ||
                    !sheets.add(name) ||
                    sheets.length > 1024) {
                  _bad('Invalid or duplicate sheet');
                }
                final relation = relationships[id];
                if (relation == null ||
                    relation.type != '$_relationNs/worksheet') {
                  _bad('Sheet relationship is not a worksheet');
                }
                if ((sheetName == null && selectedPath.isEmpty) ||
                    name == sheetName) {
                  selectedPath = relation.target;
                  selectedName = name;
                }
              }
            }
            if (selectedPath.isEmpty) _bad('Selected worksheet does not exist');
          } else if (part.name == 'xl/sharedStrings.xml') {
            if (!relationships.values.any(
              (r) => r.type == '$_relationNs/sharedStrings',
            )) {
              _bad('Unbound shared strings part');
            }
            StringBuffer? value, textRun;
            for (final token in _tokens(part.bytes, _sheetNs, 'sst')) {
              if (token.start && token.name == 'si') {
                if (token.parent != 'sst' || value != null) {
                  _bad('Misplaced shared string');
                }
                value = StringBuffer();
              } else if (token.start &&
                  token.name == 't' &&
                  !token.ancestors.contains('rPh')) {
                if (value == null || textRun != null) {
                  _bad('Misplaced shared text');
                }
                textRun = StringBuffer();
              } else if (token.text != null &&
                  token.parent == 't' &&
                  !token.ancestors.contains('rPh')) {
                if (textRun == null) _bad('Text outside shared string');
                _appendEncoded(textRun, token.text!);
              } else if (token.end &&
                  token.name == 't' &&
                  !token.ancestors.contains('rPh')) {
                if (value == null || textRun == null) {
                  _bad('Misplaced shared text');
                }
                _append(value, _decodeXstring(textRun.toString()));
                textRun = null;
              } else if (token.end && token.name == 'si') {
                if (value == null) _bad('Unmatched shared string');
                final text = value.toString();
                RawBusinessCell(
                  coordinate: 'shared:$stringCount',
                  kind: BusinessCellKind.text,
                  lexical: text,
                );
                await staging.putString(stringCount++, text);
                if (stringCount % 64 == 0) await check();
                value = null;
              }
            }
          } else if (part.name == selectedPath) {
            selectedSeen = true;
            var lastRow = 0, row = 0, lastColumn = 0, rowCells = 0;
            _Cell? cell;
            var dataSeen = false;
            for (final token in _tokens(part.bytes, _sheetNs, 'worksheet')) {
              if (token.start && token.name == 'mergeCell') {
                _bad('Merged cells are not business data');
              }
              if (token.start && token.name == 'sheetData') {
                if (dataSeen || token.parent != 'worksheet') {
                  _bad('Duplicate or misplaced sheetData');
                }
                dataSeen = true;
              } else if (token.start && token.name == 'row') {
                if (token.parent != 'sheetData' || row != 0) {
                  _bad('Misplaced row');
                }
                row = _integer(token.attrs['r'], 'row', 1048576);
                if (row <= lastRow || ++rowCount > maxDataRows + 1) {
                  _bad(
                    'Duplicate/out-of-order row or single-volume row limit exceeded',
                  );
                }
                lastRow = row;
                lastColumn = 0;
                rowCells = 0;
              } else if (token.start && token.name == 'c') {
                if (token.parent != 'row' || row == 0 || cell != null) {
                  _bad('Misplaced cell');
                }
                cell = _Cell(token.attrs);
                if (cell.row != row || cell.column <= lastColumn) {
                  _bad(
                    'Duplicate, misplaced or out-of-order coordinate ${cell.coordinate}',
                  );
                }
                lastColumn = cell.column;
              } else if (token.start && ['v', 'f', 'is'].contains(token.name)) {
                if (cell == null || token.parent != 'c') {
                  _bad('Misplaced cell value');
                }
                if (!cell.seen.add(token.name)) _bad('Duplicate cell value');
                if (token.name == 'f') cell.formula = StringBuffer();
              } else if (token.start &&
                  token.name == 't' &&
                  cell != null &&
                  token.ancestors.contains('is') &&
                  !token.ancestors.contains('rPh')) {
                if (cell.textRun != null) _bad('Nested inline text');
                cell.textRun = StringBuffer();
              } else if (token.end &&
                  token.name == 't' &&
                  cell != null &&
                  token.ancestors.contains('is') &&
                  !token.ancestors.contains('rPh')) {
                if (cell.textRun == null) _bad('Misplaced inline text');
                _append(cell.inline, _decodeXstring(cell.textRun.toString()));
                cell.textRun = null;
              } else if (token.text != null && cell != null) {
                if (token.parent == 'v') {
                  if (cell.type == 'str') {
                    _appendEncoded(cell.value, token.text!);
                  } else {
                    _append(cell.value, token.text!);
                  }
                }
                if (token.parent == 'f') {
                  _append(cell.formula!, token.text!);
                }
                if (token.parent == 't' &&
                    token.ancestors.contains('is') &&
                    !token.ancestors.contains('rPh')) {
                  _appendEncoded(cell.textRun!, token.text!);
                }
              } else if (token.end && token.name == 'c') {
                if (cell == null) _bad('Unmatched cell');
                final raw = await cell.raw(shared);
                await staging.putCell(
                  row,
                  cell.column,
                  raw,
                  cell.type,
                  cell.style,
                );
                rowCells++;
                cellCount++;
                if (cellCount % 256 == 0) await check();
                cell = null;
              } else if (token.end && token.name == 'row') {
                await staging.putRow(row, rowCells);
                if (rowCount % 64 == 0) await check();
                row = 0;
              }
            }
            if (!dataSeen) _bad('Worksheet has no sheetData');
          } else if (part.name == 'xl/styles.xml') {
            _tokens(part.bytes, _sheetNs, 'styleSheet').drain();
          }
        }
        if (!zip.verified || !selectedSeen) {
          _bad('Selected worksheet was not verified');
        }
        final profile = XlsxProfile(
          sheetName: selectedName,
          sheetPath: selectedPath,
          date1904: date1904,
          rows: rowCount,
          cells: cellCount,
          sharedStrings: stringCount,
          sourceDigest: source.digest!,
          dataRowLimit: maxDataRows,
        );
        await check();
        await staging.finish(profile.toJson());
        return profile;
      });
    } catch (primary, stack) {
      try {
        await staging.fail();
      } catch (cleanup, cleanupStack) {
        throw DomainFailure(
          'XLSX_CLEANUP',
          'Parse and quarantine failed',
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

final class _Cell {
  _Cell(Map<String, String> attributes)
    : coordinate = attributes['r'] ?? '',
      type = attributes['t'] ?? 'n',
      style = attributes['s'] == null
          ? null
          : _integer(attributes['s'], 'style', 1000000, zero: true) {
    final match = RegExp(
      r'^([A-Z]{1,3})([1-9][0-9]{0,6})$',
    ).firstMatch(coordinate);
    if (match == null) _bad('Invalid coordinate $coordinate');
    row = _integer(match.group(2), 'coordinate row', 1048576);
    column = 0;
    for (final ch in match.group(1)!.codeUnits) {
      column = column * 26 + ch - 64;
    }
    if (column > 16384) _bad('Column exceeds XFD');
  }
  final String coordinate, type;
  final int? style;
  late final int row;
  late int column;
  final value = StringBuffer(), inline = StringBuffer();
  StringBuffer? formula, textRun;
  final seen = <String>{};
  Future<RawBusinessCell> raw(Future<String> Function(int) shared) async {
    var lexical = value.toString();
    BusinessCellKind kind;
    if (type == 's') {
      lexical = await shared(
        _integer(lexical, 'shared string index', 2147483647, zero: true),
      );
      kind = BusinessCellKind.text;
    } else if (type == 'inlineStr') {
      if (seen.contains('v')) _bad('Inline cell has numeric value');
      lexical = inline.toString();
      kind = BusinessCellKind.text;
    } else if (type == 'str') {
      lexical = _decodeXstring(lexical);
      kind = BusinessCellKind.text;
    } else if (type == 'n') {
      kind = lexical.isEmpty ? BusinessCellKind.blank : BusinessCellKind.number;
    } else if (type == 'd') {
      kind = BusinessCellKind.date;
    } else if (type == 'b') {
      kind = BusinessCellKind.boolean;
    } else if (type == 'e') {
      kind = BusinessCellKind.error;
    } else {
      _bad('Unsupported cell type $type at $coordinate');
    }
    if (type != 'inlineStr' && seen.contains('is')) {
      _bad('Unexpected inline string');
    }
    return RawBusinessCell(
      coordinate: coordinate,
      kind: kind,
      lexical: lexical,
      formula: formula?.toString(),
    );
  }
}

int _integer(String? value, String field, int max, {bool zero = false}) {
  if (value == null ||
      !RegExp(zero ? r'^(0|[1-9][0-9]*)$' : r'^[1-9][0-9]*$').hasMatch(value)) {
    _bad('Invalid $field');
  }
  final number = int.tryParse(value);
  if (number == null || number > max) _bad('Out-of-range $field');
  return number;
}

void _append(StringBuffer buffer, String text) {
  if (buffer.length + text.length > 32767) {
    _bad('Cell exceeds 32767 UTF-16 units');
  }
  buffer.write(text);
}

String _target(String target) {
  if (target.contains('\\') ||
      target.contains(':') ||
      target.contains('?') ||
      target.contains('#') ||
      target.contains('%')) {
    _bad('Unsafe relationship target');
  }
  final parts = <String>[];
  for (final part
      in (target.startsWith('/') ? target.substring(1) : 'xl/$target').split(
        '/',
      )) {
    if (part == '..') {
      if (parts.isEmpty) _bad('Relationship escapes package');
      parts.removeLast();
    } else if (part != '.' && part.isNotEmpty) {
      parts.add(part);
    }
  }
  return parts.join('/');
}

Never _bad(String message) => throw DomainFailure('INVALID_XLSX', message);

final class _HashedSource implements InputSource {
  _HashedSource(this.source, this.checkpoint);
  final Future<void> Function() checkpoint;
  final InputSource source;
  String? digest;
  @override
  String get displayName => source.displayName;
  @override
  Future<int> length() => source.length();
  @override
  Stream<List<int>> openRange(int start, int endExclusive) async* {
    final sink = _DigestSink();
    final hash = sha256.startChunkedConversion(sink);
    var sinceCheckpoint = 0;
    await for (final chunk in source.openRange(start, endExclusive)) {
      hash.add(chunk);
      yield chunk;
      sinceCheckpoint += chunk.length;
      if (sinceCheckpoint >= 1024 * 1024) {
        await checkpoint();
        sinceCheckpoint = 0;
      }
    }
    hash.close();
    digest = sink.value;
  }
}

final class _DigestSink implements Sink<Digest> {
  String? value;
  @override
  void add(Digest data) {
    value = data.toString();
  }

  @override
  void close() {}
}

final class _Token {
  _Token(
    this.name,
    this.parent,
    this.ancestors, {
    this.start = false,
    this.end = false,
    this.text,
    this.attrs = const {},
  });
  final String name, parent;
  final List<String> ancestors;
  final bool start, end;
  final String? text;
  final Map<String, String> attrs;
}

Iterable<_Token> _tokens(List<int> bytes, String namespace, String root) sync* {
  final text = utf8.decode(bytes);
  _strictLexical(text);
  final names = <String>[];
  final namespaces = <Map<String, String>>[];
  var roots = 0, extensionDepth = 0;
  String? extensionKind;
  for (final event in parseEvents(
    text,
    validateNesting: true,
    validateDocument: true,
    withParent: true,
  )) {
    if (event is XmlDoctypeEvent) _bad('DTD is forbidden');
    if (event is XmlStartElementEvent) {
      if (names.length >= 64 || event.attributes.length > 64) {
        _bad('XML structure limit');
      }
      final scope = <String, String>{
        'xml': 'http://www.w3.org/XML/1998/namespace',
        if (namespaces.isNotEmpty) ...namespaces.last,
      };
      final rawNames = <String>{};
      for (final attribute in event.attributes) {
        if (!rawNames.add(attribute.name)) _bad('Duplicate XML attribute');
        if (attribute.name == 'xmlns') {
          if ([
            'http://www.w3.org/XML/1998/namespace',
            'http://www.w3.org/2000/xmlns/',
          ].contains(attribute.value)) {
            _bad('Reserved default namespace');
          }
          scope[''] = attribute.value;
        } else if (attribute.name.startsWith('xmlns:')) {
          final prefix = attribute.name.substring(6);
          if (!RegExp(r'^[A-Za-z_][A-Za-z0-9_.-]*$').hasMatch(prefix) ||
              attribute.value == 'http://www.w3.org/2000/xmlns/' ||
              (prefix != 'xml' &&
                  attribute.value == 'http://www.w3.org/XML/1998/namespace')) {
            _bad('Reserved or malformed namespace');
          }
          if (prefix.isEmpty ||
              prefix == 'xmlns' ||
              (prefix == 'xml' &&
                  attribute.value != 'http://www.w3.org/XML/1998/namespace') ||
              attribute.value.isEmpty) {
            _bad('Invalid namespace declaration');
          }
          scope[prefix] = attribute.value;
        }
      }
      (String, String) resolve(String qname, {bool attribute = false}) {
        final parts = qname.split(':');
        if (parts.length > 2 ||
            parts.any(
              (p) => !RegExp(r'^[A-Za-z_][A-Za-z0-9_.-]*$').hasMatch(p),
            )) {
          _bad('Invalid XML qualified name');
        }
        final prefix = parts.length == 2 ? parts.first : '';
        final uri = prefix.isEmpty && attribute ? '' : scope[prefix];
        if (uri == null && prefix.isNotEmpty) _bad('Unbound XML prefix');
        return (uri ?? '', parts.last);
      }

      final expanded = resolve(event.name);
      final name = expanded.$2, parent = names.isEmpty ? '' : names.last;
      final calculationNode =
          extensionDepth > 0 &&
          extensionKind == 'calculation' &&
          expanded.$1 == _calcNs &&
          ((names.length == extensionDepth &&
                  parent == 'ext' &&
                  name == 'calcFeatures') ||
              (names.length == extensionDepth + 1 &&
                  parent == 'calcFeatures' &&
                  name == 'feature'));
      final slicerNode =
          extensionDepth > 0 &&
          extensionKind == 'slicer' &&
          expanded.$1 == _slicerNs &&
          names.length == extensionDepth &&
          parent == 'ext' &&
          name == 'slicerStyles';
      if ((expanded.$1 != namespace && !calculationNode && !slicerNode) ||
          (extensionDepth > 0 && !calculationNode && !slicerNode)) {
        _bad(
          'Unsupported XML namespace or extension structure ${expanded.$1}:$name',
        );
      }
      const allowedChildren = <String, Set<String>>{
        'si': {'t', 'r', 'rPh', 'phoneticPr'},
        'is': {'t', 'r', 'rPh', 'phoneticPr'},
        'r': {'rPr', 't'},
        'rPh': {'t'},
        'c': {'v', 'f', 'is', 'extLst'},
        'sheetData': {'row'},
        'row': {'c', 'extLst'},
        'sst': {'si', 'extLst'},
      };
      if (allowedChildren[parent] case final allowed?) {
        if (!allowed.contains(name)) _bad('Unsupported $parent child $name');
      }
      if (['v', 'f', 't'].contains(parent)) {
        _bad('Scalar XML value contains child elements');
      }
      if (names.isEmpty) {
        if (name != root || ++roots != 1) _bad('Invalid XML root');
      }
      final attrs = <String, String>{};
      for (final attribute in event.attributes) {
        if (attribute.name == 'xmlns' || attribute.name.startsWith('xmlns:')) {
          continue;
        }
        final key = resolve(attribute.name, attribute: true);
        final expandedKey = key.$1.isEmpty ? key.$2 : '{${key.$1}}${key.$2}';
        if (attrs.containsKey(expandedKey)) {
          _bad('Duplicate expanded attribute');
        }
        attrs[expandedKey] = attribute.value;
      }
      for (final attribute in attrs.entries) {
        if (!attribute.key.startsWith('{$_mcNs}')) continue;
        if (attribute.key != '{$_mcNs}Ignorable') {
          _bad('Unsupported markup-compatibility instruction');
        }
        for (final prefix
            in attribute.value
                .trim()
                .split(RegExp(r'\s+'))
                .where((p) => p.isNotEmpty)) {
          if (!RegExp(r'^[A-Za-z_][A-Za-z0-9_.-]*$').hasMatch(prefix) ||
              !scope.containsKey(prefix) ||
              scope[prefix]!.isEmpty) {
            _bad('Unbound MC Ignorable prefix');
          }
        }
      }
      if (calculationNode) {
        if (name == 'calcFeatures' && attrs.isNotEmpty) {
          _bad('Unsupported calculation metadata attribute');
        }
        if (name == 'feature' &&
            (attrs.length != 1 || (attrs['name'] ?? '').isEmpty)) {
          _bad('Invalid calculation feature metadata');
        }
      }
      if (namespace == _sheetNs &&
          expanded.$1 == _sheetNs &&
          name == 'ext' &&
          names.length == 2 &&
          names[0] == 'workbook' &&
          names[1] == 'extLst' &&
          attrs['uri'] == _calcExtension) {
        if (attrs.length != 1) _bad('Unsupported workbook extension attribute');
        extensionDepth = names.length + 1;
        extensionKind = 'calculation';
      }
      if (namespace == _sheetNs &&
          expanded.$1 == _sheetNs &&
          name == 'ext' &&
          names.length == 2 &&
          names[0] == 'styleSheet' &&
          names[1] == 'extLst' &&
          attrs['uri'] == _slicerExtension) {
        if (attrs.length != 1) _bad('Unsupported style extension attribute');
        extensionDepth = names.length + 1;
        extensionKind = 'slicer';
      }
      if (slicerNode &&
          (attrs.length != 1 || (attrs['defaultSlicerStyle'] ?? '').isEmpty)) {
        _bad('Unsupported slicer style metadata');
      }
      if (name == 'sheets' && parent != 'workbook') _bad('Misplaced sheets');
      if (name == 't' && !['si', 'is', 'r', 'rPh'].contains(parent)) {
        _bad('Misplaced rich text');
      }
      if (name == 'r' && !['si', 'is'].contains(parent)) {
        _bad('Misplaced rich text run');
      }
      yield _Token(name, parent, List.of(names), start: true, attrs: attrs);
      if (event.isSelfClosing) {
        yield _Token(name, parent, List.of(names), end: true);
        if (extensionDepth == names.length + 1) extensionDepth = 0;
      } else {
        names.add(name);
        namespaces.add(scope);
      }
    } else if (event is XmlEndElementEvent) {
      final name = names.removeLast();
      namespaces.removeLast();
      if (extensionDepth == names.length + 1) extensionDepth = 0;
      yield _Token(
        name,
        names.isEmpty ? '' : names.last,
        List.of(names),
        end: true,
      );
    } else if (event is XmlTextEvent || event is XmlCDATAEvent) {
      final value = event is XmlTextEvent
          ? event.value
          : (event as XmlCDATAEvent).value;
      if (names.isNotEmpty &&
          [
            'si',
            'is',
            'r',
            'rPh',
            'c',
            'sheetData',
            'row',
            'sst',
            'workbook',
            'sheets',
            'ext',
            'calcFeatures',
            'slicerStyles',
            'feature',
          ].contains(names.last) &&
          value.trim().isNotEmpty) {
        _bad('Unexpected text in XML container');
      }
      yield _Token(
        '',
        names.isEmpty ? '' : names.last,
        List.of(names),
        text: value,
      );
    }
  }
  if (roots != 1 || names.isNotEmpty) _bad('Incomplete XML document');
}

extension on Iterable<_Token> {
  void drain() {
    for (final _ in this) {}
  }
}

// xml 6.6.1 accepts HTML-like missing/unquoted assignments. Enforce XML syntax
// before its event parser; entry and token bounds avoid pathological events.
void _strictLexical(String text) {
  _validateXmlCharacters(text);
  final name = RegExp(r'[A-Za-z_][A-Za-z0-9_.:-]*');
  bool space(int at) =>
      at < text.length && [9, 10, 13, 32].contains(text.codeUnitAt(at));
  for (var at = 0; at < text.length;) {
    final open = text.indexOf('<', at);
    if (open < 0) {
      _entities(text.substring(at));
      break;
    }
    _entities(text.substring(at, open));
    if (open - at > 512 * 1024) _bad('Oversized XML text token');
    at = open;
    String? terminator;
    if (text.startsWith('<!--', at)) {
      terminator = '-->';
    } else if (text.startsWith('<![CDATA[', at)) {
      terminator = ']]>';
    } else if (text.startsWith('<?', at) &&
        !(text.startsWith('<?xml', at) && space(at + 5))) {
      terminator = '?>';
    }
    if (terminator != null) {
      final end = text.indexOf(terminator, at + 2);
      if (end < 0 || end - at > 512 * 1024) {
        _bad('Invalid or oversized XML token');
      }
      if (terminator == '-->' && text.substring(at + 4, end).contains('--')) {
        _bad('Invalid XML comment');
      }
      at = end + terminator.length;
      continue;
    }
    if (text.startsWith('<!', at)) _bad('DTD and declarations are forbidden');
    final start = at;
    final declaration = text.startsWith('<?xml', at) && space(at + 5);
    at += declaration ? 2 : 1;
    final closing = text.startsWith('/', at);
    if (closing) at++;
    final tag = name.matchAsPrefix(text, at);
    if (tag == null) _bad('Invalid XML tag');
    at = tag.end;
    while (true) {
      final before = at;
      while (space(at)) {
        at++;
      }
      if (at >= text.length || at - start > 512 * 1024) {
        _bad('Incomplete or oversized XML tag');
      }
      if (text.startsWith(declaration ? '?>' : '>', at)) {
        at += declaration ? 2 : 1;
        break;
      }
      if (!declaration && !closing && text.startsWith('/>', at)) {
        at += 2;
        break;
      }
      if (closing || before == at) _bad('Invalid attribute separator');
      final attr = name.matchAsPrefix(text, at);
      if (attr == null) _bad('Invalid attribute name');
      at = attr.end;
      while (space(at)) {
        at++;
      }
      if (!text.startsWith('=', at)) _bad('XML attribute assignment required');
      at++;
      while (space(at)) {
        at++;
      }
      if (at >= text.length || !['"', "'"].contains(text[at])) {
        _bad('XML attributes must be quoted');
      }
      final quote = text[at++], end = text.indexOf(quote, at);
      if (end < 0 ||
          end - at > 32767 ||
          text.substring(at, end).contains('<')) {
        _bad('Invalid XML attribute');
      }
      _entities(text.substring(at, end));
      at = end + 1;
    }
  }
}

// One pass: _x005F_x0041_ becomes the literal _x0041_, never recursively A.
String _decodeXstring(String text) => text.replaceAllMapped(
  RegExp(r'_x([0-9A-Fa-f]{4})_'),
  (match) => String.fromCharCode(int.parse(match.group(1)!, radix: 16)),
);
void _appendEncoded(StringBuffer buffer, String text) {
  if (buffer.length + text.length > 32767 * 7) {
    _bad('Encoded cell text limit exceeded');
  }
  buffer.write(text);
}

bool _xmlCharacter(int point) =>
    point == 9 ||
    point == 10 ||
    point == 13 ||
    (point >= 0x20 && point <= 0xd7ff) ||
    (point >= 0xe000 && point <= 0xfffd) ||
    (point >= 0x10000 && point <= 0x10ffff);
void _validateXmlCharacters(String text) {
  for (final point in text.runes) {
    if (!_xmlCharacter(point)) _bad('Illegal XML character');
  }
}

void _entities(String text) {
  if (text.contains(']]>')) _bad('CDATA terminator in ordinary XML text');
  for (var at = text.indexOf('&'); at >= 0; at = text.indexOf('&', at)) {
    final end = text.indexOf(';', at + 1);
    if (end < 0 || end - at > 16) _bad('Malformed XML entity reference');
    final entity = text.substring(at + 1, end);
    if (!['amp', 'lt', 'gt', 'quot', 'apos'].contains(entity)) {
      final hex = entity.startsWith('#x');
      if (!RegExp(hex ? r'^#x[0-9a-fA-F]+$' : r'^#[0-9]+$').hasMatch(entity)) {
        _bad('Unknown XML entity');
      }
      final point = int.tryParse(
        entity.substring(hex ? 2 : 1),
        radix: hex ? 16 : 10,
      );
      if (point == null || !_xmlCharacter(point)) {
        _bad('Illegal XML character reference');
      }
    }
    at = end + 1;
  }
}
