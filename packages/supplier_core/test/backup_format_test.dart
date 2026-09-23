import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:supplier_core/src/contracts.dart';
import 'package:supplier_core/src/domain/revision.dart';
import 'package:supplier_core/src/exchange/backup_format.dart';
import 'package:test/test.dart';

const version = DatabaseVersion(
  instanceId: '00000000-0000-4000-8000-000000000001',
  activeEpoch: 2,
  generation: 7,
);
BackupHeader header({int revisions = 1, int settings = 1}) => BackupHeader(
  version: version,
  counts: {
    for (final table in backupTableKeys.keys)
      table: table == 'revision'
          ? revisions
          : table == 'local_settings'
          ? settings
          : 0,
  },
);
List<BackupEntry> entries() {
  final revision = RevisionEnvelope.create(
    entityType: 'supplier',
    entityId: version.instanceId,
    parents: const [],
    kind: 'put',
    payload: {
      'name': '备份供应商',
      'notes': null,
      'aliases': <String>[],
      'categories': <String>[],
      'address': null,
    },
    authoredAt: '2026-09-17T00:00:00.000Z',
    originDeviceId: version.instanceId,
  );
  return [
    BackupEntry('revision', {
      'revision_id': revision.revisionId,
      'entity_type': revision.entityType,
      'entity_id': revision.entityId,
      'canonical': revision.canonical,
    }),
    BackupEntry('local_settings', {'key': 'ui.theme', 'value_json': '"dark"'}),
  ];
}

Future<List<int>> encoded() async {
  final result = <int>[];
  await for (final chunk in encodeBackup(
    header(),
    Stream.fromIterable(entries()),
  )) {
    result.addAll(chunk);
  }
  return result;
}

void main() {
  test('rejects oversized escaped preferences before parsing or encoding', () {
    expect(
      () => BackupEntry('local_settings', {
        'key': 'ui.large',
        'value_json': List.filled(100000, '\u0000').join(),
      }),
      throwsA(
        isA<DomainFailure>().having((e) => e.code, 'code', 'BACKUP_ROW_LIMIT'),
      ),
    );
    expect(
      () => BackupEntry('local_settings', {
        'key': 'ui.large',
        'value_json': List.filled(maxBackupLineBytes + 1, 'x').join(),
      }),
      throwsA(
        isA<DomainFailure>().having((e) => e.code, 'code', 'BACKUP_ROW_LIMIT'),
      ),
    );
  });
  test(
    'receipt numeric columns require safe numbers and normalize integral doubles',
    () {
      Map<String, Object?> receipt(Object? epoch) => {
        'event_id': 'event',
        'instance_id': version.instanceId,
        'active_epoch': epoch,
        'generation': 1,
        'result_count': 0,
      };
      for (final invalid in ['9007199254740992', '1', null, 1.5, -1]) {
        expect(
          () => BackupEntry('commit_receipt', receipt(invalid)),
          throwsA(anything),
        );
      }
      expect(
        BackupEntry('commit_receipt', receipt(1.0)).row['active_epoch'],
        1,
      );
      expect(
        () => BackupEntry('confirmation_event', {
          'event_id': 'e',
          'job_id': 'j',
          'sealed_digest': 's',
          'decisions_digest': 'd',
          'instance_id': version.instanceId,
          'active_epoch': 0,
          'generation': 0,
          'schema_version': 3,
        }),
        throwsA(isA<DomainFailure>()),
      );
    },
  );
  test(
    'strict wrappers reject unknown fields even with a matching digest',
    () async {
      for (final kind in ['header', 'row', 'footer']) {
        final rows = const LineSplitter()
            .convert(utf8.decode(await encoded()))
            .map((line) => jsonDecode(line) as Map<String, dynamic>)
            .toList();
        rows.firstWhere((row) => row['kind'] == kind)['unknown'] = 'extra';
        final body =
            '${rows.take(rows.length - 1).map(jsonEncode).join('\n')}\n';
        rows.last['sha256'] = sha256.convert(utf8.encode(body)).toString();
        final bytes = utf8.encode('$body${jsonEncode(rows.last)}\n');
        await expectLater(
          decodeBackup(_Source(bytes)),
          throwsA(isA<DomainFailure>()),
        );
      }
    },
  );
  test(
    'format diagnostics are structured but callback failures retain identity',
    () async {
      for (final bytes in [
        <int>[255, 10],
        utf8.encode('{invalid}\n'),
      ]) {
        await expectLater(
          decodeBackup(_Source(bytes)),
          throwsA(
            isA<DomainFailure>()
                .having((e) => e.code, 'code', 'CORRUPT_BACKUP')
                .having((e) => e.cause, 'cause', isNotNull),
          ),
        );
      }
      expect(
        () => BackupEntry('local_settings', {
          'key': 'ui.x',
          'value_json': '{bad}',
        }),
        throwsA(
          isA<DomainFailure>().having((e) => e.code, 'code', 'CORRUPT_BACKUP'),
        ),
      );
      final failure = StateError('candidate storage failed');
      await expectLater(
        decodeBackup(
          _Source(await encoded()),
          onEntry: (_) async => throw failure,
        ),
        throwsA(same(failure)),
      );
    },
  );
  test(
    'logical backup round trip keeps revisions settings version and digest',
    () async {
      final bytes = await encoded();
      final source = _Source(bytes);
      final restored = <BackupEntry>[];
      final summary = await decodeBackup(
        source,
        onEntry: (row) async => restored.add(row),
      );
      expect(summary.header.version.instanceId, version.instanceId);
      expect(summary.header.version.generation, 7);
      expect(summary.bytes, bytes.length);
      expect(summary.digest.length, 64);
      expect(restored.map((r) => r.row), entries().map((r) => r.row));
      expect(source.largestRange, lessThanOrEqualTo(65536));
    },
  );
  test('modified bytes fail digest even when JSON stays valid', () async {
    final bytes = utf8.encode(
      utf8.decode(await encoded()).replaceAll('dark', 'lite'),
    );
    await expectLater(
      decodeBackup(_Source(bytes)),
      throwsA(isA<DomainFailure>()),
    );
  });
  test(
    'truncation missing footer and trailing data never return success',
    () async {
      final bytes = await encoded();
      await expectLater(
        decodeBackup(_Source(bytes.sublist(0, bytes.length - 1))),
        throwsA(isA<DomainFailure>()),
      );
      final lines = const LineSplitter().convert(utf8.decode(bytes));
      await expectLater(
        decodeBackup(
          _Source(utf8.encode('${lines.take(lines.length - 1).join('\n')}\n')),
        ),
        throwsA(isA<DomainFailure>()),
      );
      await expectLater(
        decodeBackup(_Source([...bytes, ...utf8.encode('{}\n')])),
        throwsA(isA<DomainFailure>()),
      );
    },
  );
  test('encoder rejects snapshot counts before producing a footer', () async {
    await expectLater(
      encodeBackup(
        header(revisions: 2),
        Stream.fromIterable(entries()),
      ).drain<void>(),
      throwsA(isA<DomainFailure>()),
    );
    await expectLater(
      encodeBackup(
        header(revisions: 0),
        Stream.fromIterable(entries()),
      ).drain<void>(),
      throwsA(isA<DomainFailure>()),
    );
  });
  test('oversize row rejected independently of stream chunking', () async {
    await expectLater(
      decodeBackup(_Source(List.filled(maxBackupLineBytes + 1, 32))),
      throwsA(
        isA<DomainFailure>().having((e) => e.code, 'code', 'BACKUP_ROW_LIMIT'),
      ),
    );
  });
  test('short range cannot silently drop source bytes', () async {
    final source = _Source(await encoded(), truncateRange: true);
    await expectLater(decodeBackup(source), throwsA(isA<DomainFailure>()));
  });
  test('unknown tables or extra columns and unfinished jobs are refused', () {
    expect(
      () => BackupEntry('device_identity', {'key': 'device'}),
      throwsA(isA<DomainFailure>()),
    );
    expect(
      () => BackupEntry('local_settings', {
        'key': 'theme',
        'value_json': 'null',
        'extra': 'bad',
      }),
      throwsA(anything),
    );
    expect(
      () => BackupEntry('import_job', {
        'job_id': 'job',
        'state': 'previewReady',
        'sealed_digest': 'a',
        'decisions_digest': 'b',
      }),
      throwsA(isA<DomainFailure>()),
    );
  });
  test('semantic parse errors retain line and byte position', () async {
    for (final targetLine in [0, 1]) {
      final lines = utf8.decode(await encoded()).split('\n');
      final object = jsonDecode(lines[targetLine]) as Map<String, dynamic>;
      if (targetLine == 0) {
        object['source_epoch'] = '2';
      } else {
        (object['row'] as Map<String, dynamic>)['unexpected'] = true;
      }
      lines[targetLine] = jsonEncode(object);
      try {
        await decodeBackup(_Source(utf8.encode(lines.join('\n'))));
        fail('Expected invalid semantic content');
      } on DomainFailure catch (error) {
        expect(error.code, 'CORRUPT_BACKUP');
        final dynamic cause = error.cause;
        expect(cause.line, targetLine + 1);
        expect(cause.byteOffset, targetLine == 0 ? 0 : utf8.encode('${lines[0]}\n').length);
        expect(cause.error, isNotNull);
      }
    }
  });
  test('callback failures are preserved without parser relabeling', () async {
    final failure = StateError('candidate disk failed');
    await expectLater(decodeBackup(_Source(await encoded()), onEntry: (_) async {
      throw failure;
    }), throwsA(same(failure)));
  });
  test('revision row cannot relabel a valid canonical envelope', () {
    final original = entries().first.row;
    expect(
      () => BackupEntry('revision', {
        ...original,
        'entity_id': '00000000-0000-4000-8000-000000000099',
      }),
      throwsA(isA<DomainFailure>()),
    );
  });
}

class _Source implements InputSource {
  _Source(this.bytes, {this.truncateRange = false});
  final List<int> bytes;
  final bool truncateRange;
  int largestRange = 0;
  @override
  String get displayName => 'fixture.backup';
  @override
  Future<int> length() async => bytes.length;
  @override
  Stream<List<int>> openRange(int start, int endExclusive) async* {
    largestRange = largestRange > endExclusive - start
        ? largestRange
        : endExclusive - start;
    final end = truncateRange ? endExclusive - 1 : endExclusive;
    for (var offset = start; offset < end; offset += 23) {
      yield bytes.sublist(offset, (offset + 23).clamp(0, end));
    }
  }
}
