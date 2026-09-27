// Read-only MCP server for AI tools (Claude Desktop, Cursor, …) over the
// ledger's local database. Configure the client to run:
//   siq_mcp [--db <path to supplier.db>]
// Without --db it uses the app's default location on this computer.
import 'dart:io';

import 'package:supplier_core/supplier_core.dart';

Future<void> main(List<String> args) async {
  if (args.contains('--version')) {
    stdout.writeln('siq_mcp, data schema $schemaVersion');
    return;
  }
  final at = args.indexOf('--db');
  final path = at >= 0 && at + 1 < args.length
      ? args[at + 1]
      : defaultDatabasePath();
  if (path == null) {
    stderr.writeln('请用 --db 指定 supplier.db 的位置');
    exitCode = 64;
    return;
  }
  final Store store;
  try {
    store = openReadOnly(path);
  } on Object catch (e) {
    // stdout carries the protocol; problems go to stderr, which MCP clients
    // show in their logs.
    stderr.writeln(e is StateError ? e.message : '$e');
    exitCode = 1;
    return;
  }
  try {
    await McpServer(store, version: 'schema $schemaVersion').serve();
  } finally {
    store.close();
  }
}
