import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:supplier_core/supplier_core.dart';
import 'package:supplier_app/platform/native_backup_artifact.dart';
import 'package:supplier_app/platform/native_database_host.dart';
import 'package:supplier_app/platform/native_file_ports.dart';

void main() {
  test(
    'real SQLite backup is reread and published after private artifact cleanup',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'supplier-backup-host-',
      );
      final host = await NativeDatabaseHost.open(
        Directory('${directory.path}/db'),
      );
      try {
        await host.records.createEntity('supplier', {
          'name': '文件备份',
          'notes': null,
          'aliases': <String>[],
          'categories': <String>[],
          'address': null,
        });
        final work = Directory('${directory.path}/work');
        final target = PrivateFileOutput(
          temporary: File('${directory.path}/export.pending'),
          destination: File('${directory.path}/export.backup'),
        );
        final service = BackupService(
          database: host.database,
          writeLock: host.lock,
          readActiveVersion: host.readActiveVersion,
          createArtifact: () => NativeBackupArtifact.create(work),
        );
        final result = await service.create(target);
        final verified = await decodeBackup(
          NativeInputSource(target.destination, displayName: 'export.backup'),
        );
        expect(verified.digest, result.digest);
        expect(verified.header.counts['revision'], 1);
        expect(verified.header.counts['commit_receipt'], 1);
        expect(await work.list().isEmpty, isTrue);
        expect((await host.database.currentVersion()).generation, 1);
      } finally {
        await host.close();
        await directory.delete(recursive: true);
      }
    },
  );
}
