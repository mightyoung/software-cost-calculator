import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';
import 'package:supplier_core/supplier_core.dart';
import 'package:supplier_core/src/exchange/bounded_zip.dart';
import 'package:test/test.dart';

final class Target implements OutputTarget {
  Target({
    this.writeFailure = false,
    this.publishFailure = false,
    this.abortFailure = false,
    this.mutate = false,
  });
  final bool writeFailure, publishFailure, abortFailure, mutate;
  bool published = false, aborted = false;
  final bytes = <int>[];
  int maxChunk = 0;
  @override
  Future<void> write(Stream<List<int>> chunks) async {
    await for (final chunk in chunks) {
      if (chunk.length > maxChunk) maxChunk = chunk.length;
      bytes.addAll(chunk);
      if (mutate && chunk.isNotEmpty) chunk[0] ^= 255;
      if (writeFailure) throw StateError('write failed');
    }
  }

  @override
  Future<void> publish() async {
    if (publishFailure) throw StateError('publish failed');
    published = true;
  }

  @override
  Future<void> abort() async {
    aborted = true;
    if (abortFailure) throw StateError('abort failed');
  }
}

void main() {
  late XlsxStaging validation;
  setUp(() => validation = XlsxStaging(NativeDatabase.memory()));
  tearDown(() => validation.close());
  const writer = BoundedXlsxWriter();
  for (final entry in {'CR': '\r', 'LF': '\n', 'tab': '\t'}.entries) {
    test('rejects ${entry.key} in worksheet names', () async {
      await expectLater(
        writer.encodeVolume(
          rows: Stream.value(['value']),
          headers: ['field'],
          validation: validation,
          sheetName: 'before${entry.value}after',
        ),
        throwsArgumentError,
      );
    });
  }
  Future<BoundedXlsxVolume> encode(
    List<List<String?>> rows, {
    List<String>? headers,
    XlsxExportPolicy policy = const XlsxExportPolicy.syncVolume(),
  }) => writer.encodeVolume(
    rows: Stream.fromIterable(rows),
    headers: headers ?? ['字段'],
    validation: validation,
    policy: policy,
  );
  test(
    'inline text preserves identifiers, exact decimals, UTC and raw Unicode',
    () async {
      final values = <String?>[
        '000123-A',
        '12.340001',
        '2026-09-16T06:30:00.123Z',
        '中😀文e\u0301',
        ' =SUM(A1:A2)',
        '\t leading trailing \n',
        'A\r\nB',
        '<>&"\'',
        '_x0041_',
        '_x005F_x0041_',
        null,
        '',
      ];
      final volume = await encode([
        values,
      ], headers: List.generate(values.length, (i) => '列$i'));
      final cells = await validation.cellsPage(2);
      expect(cells.map((c) => c.cell.lexical), values.map((v) => v ?? ''));
      expect(cells[10].cell.kind, BusinessCellKind.blank);
      expect(cells[11].cell.kind, BusinessCellKind.text);
      expect(
        cells
            .where((c) => c.cell.kind != BusinessCellKind.blank)
            .every((c) => c.rawType == 'inlineStr'),
        isTrue,
      );
      final bytes = (await volume.openRange(0, volume.byteLength).toList())
          .expand((x) => x)
          .toList();
      expect(volume.sha256Hex, sha256.convert(bytes).toString());
      final zip = await BoundedXlsxZip.read(volume);
      var entries = 0;
      await for (final part in zip.expand()) {
        entries++;
        if (part.name == 'xl/worksheets/sheet1.xml') {
          final xml = utf8.decode(part.bytes);
          expect(xml, contains('_x005F_x0041_'));
          expect(xml, contains('_x000D_'));
          expect(xml, isNot(contains('<f>')));
        }
      }
      expect(entries, 6);
      expect(zip.verified, isTrue);
    },
  );
  test(
    'maximum UTF16 cell with escaping passes; no implicit trim or normalization',
    () async {
      final value = '\r' * 32767;
      await encode([
        [value],
      ]);
      expect((await validation.cellsPage(2)).single.cell.lexical, value);
    },
  );
  for (final value in [
    'x' * 32768,
    '😀' * 16384,
    '\u0001',
    String.fromCharCode(0xd800),
  ]) {
    test('reject invalid cell length or scalar ${value.length}', () async {
      await expectLater(
        encode([
          [value],
        ]),
        throwsA(anything),
      );
      await expectLater(validation.profile(), throwsStateError);
    });
  }
  test('null and empty string remain distinct throughout readback', () async {
    await encode([
      [null],
      [''],
    ]);
    expect(
      (await validation.cellsPage(2)).single.cell.kind,
      BusinessCellKind.blank,
    );
    expect(
      (await validation.cellsPage(3)).single.cell.kind,
      BusinessCellKind.text,
    );
  });
  test('row width mismatch cannot silently erase missing columns', () async {
    await expectLater(
      encode(
        [
          ['one'],
        ],
        headers: ['A', 'B'],
      ),
      throwsArgumentError,
    );
  });
  test('sync and ordinary row policies are explicit', () async {
    await expectLater(
      encode([
        ['a'],
        ['b'],
      ], policy: const XlsxExportPolicy.syncVolume(maxDataRows: 1)),
      throwsA(
        isA<DomainFailure>().having((e) => e.code, 'code', 'XLSX_VOLUME_LIMIT'),
      ),
    );
    final v = await encode([
      ['a'],
      ['b'],
    ], policy: const XlsxExportPolicy.boundedBusiness(maxDataRows: 2));
    expect(v.dataRows, 2);
    expect(v.policy, 'bounded-business');
  });
  test(
    'sync cannot raise default row cap; adapter cannot raise byte ceilings',
    () async {
      await expectLater(
        encode(
          [],
          policy: const XlsxExportPolicy.syncVolume(maxDataRows: 5001),
        ),
        throwsArgumentError,
      );
      await expectLater(
        encode(
          [],
          policy: const XlsxExportPolicy.boundedBusiness(
            maxDataRows: 1,
            zipLimits: XlsxZipLimits(compressedBytes: 9 * 1024 * 1024),
          ),
        ),
        throwsArgumentError,
      );
    },
  );
  test(
    'actual expanded XML budget includes escaping and all package parts',
    () async {
      await expectLater(
        encode(
          [
            ['&' * 2000],
          ],
          policy: const XlsxExportPolicy.syncVolume(
            zipLimits: XlsxZipLimits(expandedBytes: 5000),
          ),
        ),
        throwsA(
          isA<DomainFailure>().having(
            (e) => e.code,
            'code',
            'XLSX_VOLUME_LIMIT',
          ),
        ),
      );
    },
  );
  test(
    'compressed output budget is enforced during package construction',
    () async {
      await expectLater(
        encode(
          [
            ['abc'],
          ],
          policy: const XlsxExportPolicy.syncVolume(
            zipLimits: XlsxZipLimits(compressedBytes: 200),
          ),
        ),
        throwsA(
          isA<DomainFailure>().having(
            (e) => e.code,
            'code',
            'XLSX_VOLUME_LIMIT',
          ),
        ),
      );
    },
  );
  test(
    'reader requires a fresh validation database and preserves existing run',
    () async {
      await encode([
        ['first'],
      ]);
      await expectLater(
        encode([
          ['second'],
        ]),
        throwsStateError,
      );
      expect((await validation.cellsPage(2)).single.cell.lexical, 'first');
    },
  );
  test(
    'cancel during rows preserves the original failure and does not validate',
    () async {
      final cancelled = StateError('cancel');
      var checks = 0;
      await expectLater(
        writer.encodeVolume(
          rows: Stream.fromIterable(List.generate(70, (_) => ['x'])),
          headers: ['A'],
          validation: validation,
          checkpoint: () async {
            if (++checks == 2) throw cancelled;
          },
        ),
        throwsA(same(cancelled)),
      );
      await expectLater(validation.profile(), throwsStateError);
    },
  );
  test(
    'publish chunking is bounded and sink mutation cannot alter validated bytes',
    () async {
      final volume = await encode([
        ['exact'],
      ]);
      final target = Target(mutate: true);
      await volume.publishTo(target);
      expect(target.published, isTrue);
      expect(target.aborted, isFalse);
      expect(target.maxChunk, lessThanOrEqualTo(65536));
      final after = (await volume.openRange(0, volume.byteLength).toList())
          .expand((x) => x)
          .toList();
      expect(sha256.convert(after).toString(), volume.sha256Hex);
    },
  );
  for (final publish in [false, true]) {
    test('output ${publish ? 'publish' : 'write'} failure aborts', () async {
      final volume = await encode([
        ['x'],
      ]);
      final target = Target(writeFailure: !publish, publishFailure: publish);
      await expectLater(volume.publishTo(target), throwsStateError);
      expect(target.aborted, isTrue);
      expect(target.published, isFalse);
    });
  }
  test('primary and abort failures retain both stacks', () async {
    final volume = await encode([
      ['x'],
    ]);
    final target = Target(writeFailure: true, abortFailure: true);
    await expectLater(
      volume.publishTo(target),
      throwsA(
        isA<DomainFailure>()
            .having((e) => e.code, 'code', 'XLSX_OUTPUT_CLEANUP')
            .having(
              (e) => e.cause.toString(),
              'cause',
              allOf(contains('write failed'), contains('abort failed')),
            ),
      ),
    );
  });
  test('quotation headers cover payload and four non-authoritative hints', () {
    final keys = businessQuotationColumns.map((c) => c.key).toSet();
    expect(keys, containsAll(Quotation.fields));
    expect(
      keys,
      containsAll([
        'record_id',
        'record_type',
        'export_revision_id',
        'template_version',
        'missing_context',
      ]),
    );
    expect(keys.length, businessQuotationColumns.length);
  });

  test('actual sync volume row boundary includes header separately', () async {
    final volume = await writer.encodeVolume(
      rows: Stream.fromIterable(List.generate(5000, (_) => ['x'])),
      headers: ['A'],
      validation: validation,
    );
    expect(volume.dataRows, 5000);
    expect((await validation.profile())['rows'], 5001);
  });
  test('source stream failure cannot produce a publishable volume', () async {
    final failure = StateError('source failed');
    Stream<List<String?>> source() async* {
      yield ['x'];
      throw failure;
    }

    await expectLater(
      writer.encodeVolume(
        rows: source(),
        headers: ['A'],
        validation: validation,
      ),
      throwsA(same(failure)),
    );
    await expectLater(validation.profile(), throwsStateError);
  });
  test(
    'output checkpoint cancellation aborts target before publication',
    () async {
      final volume = await encode([
        ['x'],
      ]);
      final target = Target();
      final cancelled = StateError('cancel output');
      await expectLater(
        volume.publishTo(
          target,
          checkpoint: () async {
            throw cancelled;
          },
        ),
        throwsA(same(cancelled)),
      );
      expect(target.aborted, isTrue);
      expect(target.published, isFalse);
    },
  );
}
