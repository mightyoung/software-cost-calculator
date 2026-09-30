import 'dart:convert';

import 'package:supplier_core/supplier_core.dart';

/// Schema only: no record contents, database paths, queries or write commands.
Map<String, Object?> ontologyGraphSchema() => {
  'schemaVersion': 1,
  'nodes': [
    for (final type in ontology.values)
      {
        'id': type.name,
        'data': {
          'label': type.label,
          'description': type.description,
          'fieldCount': type.fields.length,
          'fields': [
            for (final field in type.fields)
              {
                'name': field.name,
                'label': field.label,
                'kind': field.kind.label,
                'required': field.required,
                'description': field.description,
                'values': field.values,
                'target': field.target,
              },
          ],
        },
      },
  ],
  'groups': [
    for (final (name, ids) in objectGroups) {'name': name, 'ids': ids},
  ],
  'edges': [
    for (final link in links)
      {
        'id': link.name,
        'source': link.from,
        'target': link.to,
        'data': {
          'field': link.field,
          'label': ontology[link.from]!.field(link.field)!.label,
          'meaning': link.toJson()['meaning'],
          'many': link.many,
        },
      },
  ],
};

Map<String, Object?> ontologyHostPayload({
  required Map<String, int> counts,
  required String selected,
  required bool dark,
  required bool reducedMotion,
  required double textScale,
}) => {
  'version': 1,
  'schema': ontologyGraphSchema(),
  'counts': {for (final id in ontology.keys) id: counts[id] ?? 0},
  'selected': ontology.containsKey(selected) ? selected : 'quotation',
  'dark': dark,
  'reducedMotion': reducedMotion,
  'textScale': textScale,
};

String? ontologySelection(List<dynamic> args) =>
    args.length == 1 && args.first is String && ontology.containsKey(args.first)
    ? args.first as String
    : null;

/// JSON as an expression, never interpolation of labels as executable code.
String ontologyUpdateScript(Map<String, Object?> payload) =>
    'window.ontologyHost && window.ontologyHost.update(${jsonEncode(payload)}); null;';
