import 'dart:io';

import 'package:supplier_core/supplier_core.dart';

import 'native_file_ports.dart';

/// Owns only the unique task directory it creates. The frozen file is reread for
/// integrity checks before copying to the caller's external publication adapter.
final class NativeBackupArtifact implements BackupArtifact {
  NativeBackupArtifact._(this._directory)
    : output = PrivateFileOutput(
        temporary: File('${_directory.path}/backup.pending'),
        destination: File('${_directory.path}/backup.logical'),
      ),
      source = NativeInputSource(
        File('${_directory.path}/backup.logical'),
        displayName: '临时逻辑备份',
      );
  final Directory _directory;
  @override
  final PrivateFileOutput output;
  @override
  final NativeInputSource source;

  static Future<NativeBackupArtifact> create(Directory workDirectory) async {
    await workDirectory.create(recursive: true);
    return NativeBackupArtifact._(await workDirectory.createTemp('backup-'));
  }

  /// Call only after all awaited writes/reads have ended, including on failure.
  @override
  Future<void> dispose() async {
    if (await _directory.exists()) await _directory.delete(recursive: true);
  }
}
