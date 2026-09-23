import 'dart:convert';
import 'dart:io';
import 'package:drift/native.dart';
import 'package:supplier_probe/database.dart';
import 'package:supplier_probe/model.dart';
import 'package:supplier_probe/xlsx.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty ||
      !['create', 'verify', 'import'].contains(args[0]) ||
      args.length != (args[0] == 'verify' ? 2 : 3)) {
    stderr.writeln(
      'Usage: dart run bin/probe.dart create <db> <xlsx> | verify <db> | import <xlsx> <empty-db>',
    );
    exitCode = 64;
    return;
  }
  final path = args[0] == 'import' ? args[2] : args[1];
  final db = ProbeDatabase(NativeDatabase(File(path)));
  try {
    if (args[0] == 'create') {
      await db.restore(sampleSnapshot());
      File(args[2]).writeAsBytesSync(encodeSnapshot(await db.snapshot()));
    } else if (args[0] == 'import') {
      await db.restore(decodeSnapshot(File(args[1]).readAsBytesSync()));
    }
    stdout.writeln(jsonEncode(await db.snapshot()));
  } finally {
    await db.close();
  }
}
