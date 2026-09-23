import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:supplier_core/supplier_core.dart';
import 'package:supplier_app/platform/native_database_host.dart';
import 'package:supplier_app/platform/native_backup_artifact.dart';
import 'package:supplier_app/platform/native_file_ports.dart';

import '../test/support/native_restore_fault.dart';

Future<void> add(NativeDatabaseHost host, String name) async {
  await host.records.createEntity('supplier', {
    'name': name,
    'notes': null,
    'aliases': <String>[],
    'categories': <String>[],
    'address': null,
  });
}

Future<void> main(List<String> args) async {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  if (args.isNotEmpty && args.first == 'child') {
    final host = await NativeDatabaseHost.open(Directory(args[1]));
    await withNativeRestoreFault(() => host.activateRestore(args[2]), (
      point,
    ) async {
      if (point == args[3]) {
        stdout.writeln('CHECKPOINT:$point');
        await stdout.flush();
        await Completer<void>().future;
      }
    });
    throw StateError('Expected interruption boundary was not reached');
  }
  final results = <String, Object?>{};
  for (final phase in [
    'before_switch',
    'inside_switch',
    'after_switch',
    'after_accept',
  ]) {
    final directory = await Directory.systemTemp.createTemp(
      'formal-restore-kill-',
    );
    Process? child;
    NativeDatabaseHost? host;
    try {
      host = await NativeDatabaseHost.open(directory);
      await add(host, 'snapshot');
      final source = File('${directory.path}/snapshot.logical');
      await BackupService(
        database: host.database,
        writeLock: host.lock,
        readActiveVersion: host.readActiveVersion,
        createArtifact: () =>
            NativeBackupArtifact.create(Directory('${directory.path}/work')),
      ).create(
        PrivateFileOutput(
          temporary: File('${source.path}.pending'),
          destination: source,
        ),
      );
      await add(host, 'retained');
      final original = await host.database.currentVersion();
      final device = host.deviceId;
      final id = await host.prepareRestore(
        NativeInputSource(source, displayName: 'snapshot'),
      );
      await host.close();
      host = null;
      child = await Process.start(Platform.resolvedExecutable, [
        'run',
        Platform.script.toFilePath(),
        'child',
        directory.path,
        id,
        phase,
      ]);
      final reached = Completer<void>();
      final stderr = StringBuffer();
      final errors = child.stderr.transform(utf8.decoder).listen(stderr.write);
      final output = child.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            if (line == 'CHECKPOINT:$phase' && !reached.isCompleted) {
              reached.complete();
            }
          });
      final exited = child.exitCode.then((code) {
        if (!reached.isCompleted) {
          reached.completeError(StateError('Child exited $code: $stderr'));
        }
        return code;
      });
      await reached.future.timeout(const Duration(seconds: 60));
      if (!child.kill(ProcessSignal.sigkill)) {
        throw StateError('SIGKILL not delivered');
      }
      final code = await exited.timeout(const Duration(seconds: 15));
      await output.cancel();
      await errors.cancel();
      if (code == 0) throw StateError('Child was not interrupted');
      host = await NativeDatabaseHost.open(directory);
      final active = await host.database.currentVersion();
      final names = (await host.database.rows(
        'SELECT name FROM supplier_projection ORDER BY name',
      )).map((row) => row.read<String>('name')).toList();
      if (active.instanceId != id ||
          active.activeEpoch != original.activeEpoch + 1 ||
          names.length != 1 ||
          names.single != 'snapshot' ||
          host.deviceId != device) {
        throw StateError('Wrong recovered state at $phase: $names');
      }
      await add(host, 'after-recovery');
      await host.close();
      host = await NativeDatabaseHost.open(directory);
      final count = (await host.database.rows(
        'SELECT count(*) n FROM supplier_projection',
      )).single.read<int>('n');
      if (count != 2 ||
          (await host.database.currentVersion()).instanceId != id) {
        throw StateError('Accepted write rolled back at $phase');
      }
      results[phase] = {
        'signal_exit': code,
        'recovered_instance': id,
        'device_preserved': true,
        'post_accept_write_preserved': true,
      };
    } finally {
      child?.kill(ProcessSignal.sigkill);
      await host?.close();
      await directory.delete(recursive: true);
    }
  }
  final encoded = const JsonEncoder.withIndent('  ')
      .convert({'status': 'PASS', 'boundaries': results});
  final report = File(
    '../../artifacts/development/native-restore-interrupt.json',
  );
  await report.parent.create(recursive: true);
  await report.writeAsString(encoded);
  stdout.writeln(encoded);
}
