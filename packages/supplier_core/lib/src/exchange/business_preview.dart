import 'dart:convert';
import '../contracts.dart';
import '../domain/canonical.dart';
import '../domain/quotation.dart';
import '../domain/revision.dart';
import '../domain/values.dart';
import 'business_mapping.dart';

enum BusinessConversion { text, decimal, integer, json, date, inquiryTime }

/// Column indexes are one-based. They describe placement, never source identity.
final class BusinessColumnMapping {
  const BusinessColumnMapping(this.column, this.conversion);
  final int column;
  final BusinessConversion conversion;
}

final class BusinessMapping {
  factory BusinessMapping.fromJson(Map<String, Object?> value) {
    final columns = (value['columns']! as Map).cast<String, Object?>();
    final semantics = (value['semantics']! as Map).cast<String, Object?>();
    final conversions = (semantics['fields']! as Map).cast<String, Object?>();
    return BusinessMapping(
      columns: {
        for (final entry in columns.entries)
          entry.key: BusinessColumnMapping(
            entry.value! as int,
            BusinessConversion.values.byName(conversions[entry.key]! as String),
          ),
      },
      captureMode: CaptureMode.values.byName(value['capture_mode']! as String),
      defaults: (value['defaults']! as Map).cast<String, Object?>(),
      headerRow: value['header_row']! as int,
      utcOffsetMinutes: semantics['utc_offset_minutes'] as int?,
    );
  }
  BusinessMapping({
    required Map<String, BusinessColumnMapping> columns,
    this.captureMode = CaptureMode.standard,
    Map<String, Object?> defaults = const {},
    this.headerRow = 1,
    this.utcOffsetMinutes,
  }) : columns = Map.unmodifiable(columns),
       defaults = Map.unmodifiable(
         jsonDecode(canonicalJson(defaults)) as Map<String, Object?>,
       ) {
    if (headerRow < 1 ||
        headerRow > 1048576 ||
        columns.isEmpty ||
        columns.length > 40 ||
        columns.keys.any((key) => !fields.contains(key)) ||
        columns.entries.any(
          (entry) => entry.value.conversion != conversionFor(entry.key),
        ) ||
        columns.values.any(
          (value) => value.column < 1 || value.column > 16384,
        ) ||
        defaults.keys.any((key) => !Quotation.fields.contains(key)) ||
        defaults.containsKey('capture_mode') ||
        utcOffsetMinutes != null && utcOffsetMinutes!.abs() > 840) {
      throw ArgumentError('Invalid business column mapping or batch defaults');
    }
    if (columns.containsKey('inquiry_time') &&
        [
          'inquiry_precision',
          'inquiry_date',
          'inquired_at',
          'inquiry_utc_offset_minutes',
        ].any(columns.containsKey)) {
      throw ArgumentError(
        'Map inquiry_time or its component columns, not both',
      );
    }
  }
  static BusinessConversion conversionFor(String field) => switch (field) {
    'price' || 'min_qty' || 'tax_rate' => BusinessConversion.decimal,
    'lead_time_days' ||
    'inquiry_utc_offset_minutes' => BusinessConversion.integer,
    'quoted_on' || 'valid_until' || 'inquiry_date' => BusinessConversion.date,
    'inquiry_time' => BusinessConversion.inquiryTime,
    'contact_snapshot' => BusinessConversion.json,
    _ => BusinessConversion.text,
  };
  static const fields = [
    ...Quotation.fields,
    'record_id',
    'export_revision_id',
    'supplier_name',
    'product_name',
    'product_brand',
    'product_model',
    'product_specification',
    'inquiry_time',
  ];
  final Map<String, BusinessColumnMapping> columns;
  final Map<String, Object?> defaults;
  final CaptureMode captureMode;
  final int headerRow;
  final int? utcOffsetMinutes;
  Map<String, Object?> get semantics => {
    'fields': {for (final e in columns.entries) e.key: e.value.conversion.name},
    'utc_offset_minutes': utcOffsetMinutes,
  };
  Map<String, Object?> get configuration => {
    'columns': {for (final e in columns.entries) e.key: e.value.column},
    'semantics': semantics,
    'defaults': defaults,
    'capture_mode': captureMode.name,
    'header_row': headerRow,
  };

  BusinessMappedRow convert(
    int row,
    Map<int, RawBusinessCell> cells, {
    required bool date1904,
  }) {
    final source = <String, SourceCell>{}, values = <String, Object?>{};
    final issues = <BusinessRowIssue>[],
        conversions = <BusinessValueConversion>[];
    for (final field in fields) {
      final mapping = columns[field];
      if (mapping == null) {
        source[field] = const SourceCell.missing();
        continue;
      }
      // An omitted XML cell in a mapped column is a present blank column.
      final cell =
          cells[mapping.column] ??
          RawBusinessCell(
            coordinate: 'row $row column ${mapping.column}',
            kind: BusinessCellKind.blank,
            lexical: '',
          );
      try {
        if (cell.sourcePresence == SourcePresence.blank) {
          source[field] = const SourceCell.blank();
          continue;
        }
        Object value;
        switch (mapping.conversion) {
          case BusinessConversion.text:
            value = cell.text()!;
          case BusinessConversion.decimal:
            value = cell.decimal(positive: field == 'min_qty')!;
          case BusinessConversion.integer:
            final text = cell.kind == BusinessCellKind.number
                ? cell.decimal()!
                : cell.text()!;
            value = int.tryParse(text) ?? invalid(field, 'integer required');
          case BusinessConversion.json:
            value = jsonDecode(cell.text()!) as Object;
          case BusinessConversion.date:
            value = cell.kind == BusinessCellKind.number
                ? cell.excelDate(date1904: date1904).time.date!
                : requireDate(cell.text(), field);
          case BusinessConversion.inquiryTime:
            InquiryTime time;
            if (cell.kind == BusinessCellKind.number) {
              time = cell
                  .excelDate(
                    date1904: date1904,
                    instant: utcOffsetMinutes != null,
                    offsetMinutes: utcOffsetMinutes,
                  )
                  .time;
            } else {
              var text = cell.text()!;
              if (RegExp(
                r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(?::\d{2}(?:\.\d{1,3})?)?$',
              ).hasMatch(text)) {
                final offset = utcOffsetMinutes;
                if (offset == null) {
                  invalid(field, 'choose an explicit batch UTC offset');
                }
                text +=
                    '${offset < 0 ? '-' : '+'}${(offset.abs() ~/ 60).toString().padLeft(2, '0')}:${(offset.abs() % 60).toString().padLeft(2, '0')}';
              }
              time = InquiryTime.parseInput(text);
            }
            value = time.toJson();
        }
        source[field] = SourceCell.value(value);
        values[field] = value;
        if (cell.kind != BusinessCellKind.text ||
            value is! String ||
            value != cell.lexical) {
          conversions.add(
            BusinessValueConversion(
              field,
              cell.coordinate,
              cell.lexical,
              value,
            ),
          );
        }
      } on DomainFailure catch (error) {
        issues.add(BusinessRowIssue(field, cell.coordinate, error.message));
      } on FormatException catch (error) {
        issues.add(BusinessRowIssue(field, cell.coordinate, error.message));
      } on TypeError {
        issues.add(
          BusinessRowIssue(
            field,
            cell.coordinate,
            'unsupported converted value',
          ),
        );
      }
    }
    final input = {
      for (final key in [
        'record_id',
        'supplier_id',
        'product_id',
        'contact_id',
        'supplier_name',
        'product_name',
      ])
        key: values[key],
    };
    return BusinessMappedRow(
      row,
      Map.unmodifiable(values),
      List.unmodifiable(issues),
      List.unmodifiable(conversions),
      issues.isEmpty
          ? SourceFingerprint.create(
              fields: source,
              inputIdentity: input,
              mappingSemantics: {
                ...semantics,
                if (columns.values.any(
                  (c) =>
                      c.conversion == BusinessConversion.date ||
                      c.conversion == BusinessConversion.inquiryTime,
                ))
                  'date1904': date1904,
              },
              batchDefaults: defaults,
              captureMode: captureMode.name,
            )
          : null,
    );
  }
}

final class BusinessMappedRow {
  const BusinessMappedRow(
    this.row,
    this.values,
    this.issues,
    this.conversions,
    this.source,
  );
  final int row;
  final Map<String, Object?> values;
  final List<BusinessRowIssue> issues;
  final List<BusinessValueConversion> conversions;
  final SourceFingerprint? source;
}

final class BusinessRowIssue {
  const BusinessRowIssue(this.field, this.coordinate, this.message);
  final String field, coordinate, message;
}

final class BusinessValueConversion {
  const BusinessValueConversion(
    this.field,
    this.coordinate,
    this.original,
    this.converted,
  );
  final String field, coordinate, original;
  final Object converted;
  Map<String, Object?> toJson() => {
    'field': field,
    'coordinate': coordinate,
    'original': original,
    'converted': converted,
  };
}
