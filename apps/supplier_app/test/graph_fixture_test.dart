import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import '../tool/export_graph_fixture.dart';

void main() {
  test(
    'G6 fixture exactly matches live ontology including every field and edge',
    () {
      final file = File('../../docs/design/g6/schema.json');
      final actual = graphFixture();
      // Explicit artifact-generation mode; normal tests only verify the fixture.
      if (const bool.fromEnvironment('UPDATE_GRAPH_FIXTURE')) {
        file.writeAsStringSync(
          '${const JsonEncoder.withIndent('  ').convert(actual)}\n',
        );
      }
      expect(jsonDecode(file.readAsStringSync()), actual);
    },
  );
}
