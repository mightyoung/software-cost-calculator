import 'dart:convert';
import 'dart:io';
import 'package:supplier_app/features/data_center/ontology_payload.dart';

/// Read-only schema fixture for the G6 feasibility study. No database is opened.
void main() =>
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(graphFixture()));

Map<String, Object?> graphFixture() => ontologyGraphSchema();
