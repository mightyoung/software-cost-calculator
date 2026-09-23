import 'dart:io';

import 'package:drift/native.dart';
import 'package:supplier_core/supplier_core.dart';
import 'package:supplier_app/platform/native_database_host.dart';
import 'package:supplier_app/platform/native_backup_artifact.dart';
import 'package:supplier_app/platform/native_file_ports.dart';
import 'package:supplier_app/platform/native_business_import.dart';

class BusinessImportRig {
  BusinessImportRig._(this.directory, this.host);
  final Directory directory;
  NativeDatabaseHost host;
  late NativeBusinessImport adapter;
  late String filePath, supplier, product;
  static Future<BusinessImportRig> open() async {
    final directory = await Directory.systemTemp.createTemp(
      'business-import-app-',
    );
    final rig = BusinessImportRig._(
      directory,
      await NativeDatabaseHost.open(directory),
    );
    rig._connect();
    rig.supplier = await rig.host.records.createEntity('supplier', {
      'name': '测试供应商',
      'aliases': <String>[],
      'categories': <String>[],
      'address': null,
      'notes': null,
    });
    rig.product = await rig.host.records.createEntity('product', {
      'name': '紧固件',
      'unit': '件',
      'brand': null,
      'model': '0001',
      'specification': null,
      'category': null,
      'notes': null,
    });
    final validation = XlsxStaging(NativeDatabase.memory());
    try {
      final volume = await const BoundedXlsxWriter().encodeVolume(
        headers: [
          'supplier_id',
          'product_id',
          'price',
          'unit_snapshot',
          'quoted_on',
          'inquiry_date',
          'inquiry_precision',
          'project_name',
          'inquirer_name',
          'notes',
        ],
        rows: Stream.fromIterable([
          [
            rig.supplier,
            rig.product,
            '32.123456',
            '件',
            '2026-09-21',
            '2026-09-21',
            'date',
            '零件采购',
            '李工',
            '原始来件备注',
          ],
        ]),
        validation: validation,
      );
      final file = File('${directory.path}/报价.xlsx');
      await volume.publishTo(
        PrivateFileOutput(
          temporary: File('${file.path}.pending'),
          destination: file,
        ),
      );
      rig.filePath = file.path;
    } finally {
      await validation.close();
    }
    return rig;
  }

  void _connect() {
    final backups = BackupService(
      database: host.database,
      writeLock: host.lock,
      readActiveVersion: host.readActiveVersion,
      createArtifact: () => NativeBackupArtifact.create(
        Directory('${directory.path}/backup-work'),
      ),
    );
    final exchange = ExchangeService(
      coordinator: host.coordinator,
      backups: backups,
      createBackupDestination: () async {
        final artifact = await NativeBackupArtifact.create(
          Directory('${directory.path}/before-import'),
        );
        return BusinessBackupDestination(artifact.output, artifact.source);
      },
    );
    adapter = NativeBusinessImport(
      exchange: exchange,
      deviceId: host.deviceId,
      directory: Directory('${directory.path}/imports'),
    );
  }

  Future<void> reopen() async {
    await host.close();
    host = await NativeDatabaseHost.open(directory);
    _connect();
  }

  Future<void> dispose() async {
    await host.close();
    await directory.delete(recursive: true);
  }
}
