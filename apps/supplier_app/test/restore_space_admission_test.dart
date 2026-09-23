import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:supplier_core/supplier_core.dart';
import 'package:supplier_app/platform/native_database_host.dart';
import 'package:supplier_app/platform/native_backup_artifact.dart';
import 'package:supplier_app/platform/native_file_ports.dart';

void main() {
  test('space admission is before prepare artifacts and resampled before activation', () async {
    final directory = await Directory.systemTemp.createTemp('restore-space-');
    int? available;
    final host = await NativeDatabaseHost.open(
      directory,
      readCapacity: () async => CapacitySample(
        status: available == null ? 'unsupported' : 'estimated',
        scope: 'test',
        availableBytes: available,
      ),
    );
    try {
      final file = File('${directory.path}/snapshot.logical');
      await BackupService(
        database: host.database,
        writeLock: host.lock,
        readActiveVersion: host.readActiveVersion,
        createArtifact: () =>
            NativeBackupArtifact.create(Directory('${directory.path}/work')),
      ).create(
        PrivateFileOutput(
          temporary: File('${file.path}.pending'),
          destination: file,
        ),
      );
      final source = NativeInputSource(file, displayName: 'backup');
      final before = await host.database.currentVersion();
      final initialFiles = (await directory.list().toList())
          .map((e) => e.path)
          .toSet();
      available = 0;
      await expectLater(
        host.prepareRestore(source),
        throwsA(
          isA<DomainFailure>().having((e) => e.code, 'code', 'SPACE_REQUIRED'),
        ),
      );
      expect(
        (await directory.list().toList()).map((e) => e.path).toSet(),
        initialFiles,
      );
      available = null;
      final preview = await host.estimateRestore(source);
      expect(preview.budget.fits, isNull);
      final candidate = await host.prepareRestore(source);
      available = 0;
      await expectLater(
        host.activateRestore(candidate),
        throwsA(
          isA<DomainFailure>().having((e) => e.code, 'code', 'SPACE_REQUIRED'),
        ),
      );
      expect(host.lastRestoreEstimate!.phase, 'activate');
      expect(await Directory('${directory.path}/backups').exists(), isFalse);
      expect(
        (await host.database.currentVersion()).instanceId,
        before.instanceId,
      );
      // The ready candidate survives rejection, and can be activated later.
      available = null;
      final activated = await host.activateRestore(candidate);
      expect(activated.instanceId, candidate);
    } finally {
      await host.close();
      await directory.delete(recursive: true);
    }
  });
}
