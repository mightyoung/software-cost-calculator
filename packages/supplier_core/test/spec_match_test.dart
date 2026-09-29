import 'dart:io';

import 'package:supplier_core/supplier_core.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

void main() {
  setUp(() => tmp = Directory.systemTemp.createTempSync('supplier_match'));
  tearDown(() => tmp.deleteSync(recursive: true));
  final asOf = DateTime.utc(2026, 9, 29);

  String material(
    Store s,
    String name,
    String cls,
    Map<String, Map<String, Object?>> params,
  ) {
    final id = s.save('product', {
      ...product(name, unit: '台'),
      'spec_class': cls,
    });
    for (final e in params.entries) {
      s.setParam(id, e.key, e.value);
    }
    return id;
  }

  SpecConstraint c(
    String p,
    String op,
    Map<String, Object?> v, [
    ClauseMark m = ClauseMark.none,
  ]) => SpecConstraint(p, op, v, mark: m);

  test('the worked example of §8.9: industrial PCs', () {
    final s = device('A');
    final a = material(s, 'A', 'computer.ipc', {
      'cpu.cores': {'v': '8'},
      'cpu.base_freq': {'v': '2.5', 'u': 'GHz'},
      'mem.type': {'v': 'DDR4'},
      'mem.total': {'v': '32', 'u': 'GiB'},
    });
    final b = material(s, 'B', 'computer.ipc', {
      'cpu.cores': {'v': '16'},
      'cpu.base_freq': {'v': '2.1', 'u': 'GHz'},
      'mem.type': {'v': 'DDR5'},
      // Total derived from 2 × 8 GB.
      'mem.dimm_size': {'v': '8', 'u': 'GiB'},
      'mem.dimm_count': {'v': '2'},
      'comp.catalog': {
        'entries': [
          {
            'name': '安全可靠测评结果',
            'batch': null,
            'level': null,
            'valid_until': null,
          },
        ],
      },
    });
    final cc = material(s, 'C', 'computer.ipc', {
      'cpu.cores': {'v': '4'},
      'cpu.base_freq': {'v': '3.0', 'u': 'GHz'},
      'mem.type': {'v': 'DDR4'},
      'mem.total': {'v': '16', 'u': 'GiB'},
    });
    // A server is a computer but not an IPC: not a candidate.
    material(s, 'S', 'computer.server', {
      'cpu.cores': {'v': '64'},
    });

    final want = [
      c('cpu.cores', 'ge', {'v': '8'}, ClauseMark.star),
      c('cpu.base_freq', 'ge', {'v': '2.3', 'u': 'GHz'}),
      c('mem.type', 'ge', {'v': 'DDR4'}),
      c('mem.total', 'ge', {'v': '16', 'u': 'GiB'}),
      c('comp.catalog', 'listed', {
        'entries': [
          {
            'name': '军用关键软硬件自主可控产品目录',
            'batch': null,
            'level': null,
            'valid_until': null,
          },
        ],
      }),
    ];
    final r = s.matchSpec('computer.ipc', want, asOf: asOf);
    expect([for (final x in r.candidates) x.id], [a, b, cc]);
    expect(r.allHard, isFalse);
    Candidate by(String id) => r.candidates.firstWhere((x) => x.id == id);
    List<Outcome> outcomes(String id) => [
      for (final x in by(id).results) x.verdict.outcome,
    ];
    expect(outcomes(a), [
      Outcome.exact,
      Outcome.better,
      Outcome.exact,
      Outcome.better,
      Outcome.unknown,
    ]);
    expect(outcomes(b), [
      Outcome.better,
      Outcome.worse,
      Outcome.unknown,
      Outcome.exact,
      Outcome.unknown,
    ]);
    expect(outcomes(cc).first, Outcome.worse);
    expect(by(a).group, MatchGroup.partial);
    expect(by(b).group, MatchGroup.partial, reason: 'only soft clauses fail');
    expect(by(cc).group, MatchGroup.failed, reason: '★ cores');
    expect(by(b).results[3].derived, isTrue);
    expect(by(b).results[4].verdict.note, contains('其他目录'));
    // Relaxation: dropping the catalog clause makes A fully satisfying.
    expect(r.relaxGain, {4: 1});

    // Without marks every clause is hard: B now fails.
    final plain = [for (final x in want) c(x.property, x.op, x.value)];
    final r2 = s.matchSpec('computer', plain, asOf: asOf);
    expect(r2.allHard, isTrue);
    expect(r2.candidates.firstWhere((x) => x.id == b).group, MatchGroup.failed);
    expect(
      r2.candidates,
      hasLength(4),
      reason: 'parent class includes the server',
    );
  });

  test(
    'gas accuracy in %FS converts with the material range; price breaks ties',
    () {
      final s = device('A');
      final sup = s.save('supplier', supplier('甲'));
      final pro = s.save('project', project('P1'));
      String probe(String name, String price) {
        final id = material(s, name, 'sensor.gas', {
          'gas.range': {'min': '0', 'max': '100', 'u': 'ppm'},
          'gas.accuracy': {'v': '1', 'basis': 'FS'},
          'prot.ex': {
            'marks': [
              {
                'types': ['db'],
                'group': 'IIC',
                'temp': 'T6',
                'epl': 'Gb',
              },
            ],
          },
        });
        s.save('quotation', {
          ...quotation(sup, id, pro, price),
          'unit_snapshot': '台',
        });
        return id;
      }

      final dear = probe('贵', '5000');
      final cheap = probe('便宜', '3900');
      final want = [
        c('gas.range', 'covers', {'min': '0', 'max': '100', 'u': 'ppm'}),
        c('gas.accuracy', 'le', {'v': '1', 'u': 'ppm'}),
        c('prot.ex', 'ex_ge', {
          'marks': [
            {
              'types': ['d'],
              'group': 'IIB',
              'temp': 'T4',
              'epl': 'Gb',
            },
          ],
        }),
      ];
      final r = s.matchSpec('sensor.gas', want, asOf: asOf);
      expect([for (final x in r.candidates) x.id], [cheap, dear]);
      expect(r.size(MatchGroup.full), 2);
      expect(r.candidates.first.price, '3900');
      expect(r.candidates.first.results[1].verdict.outcome, Outcome.exact);
      expect(r.candidates.first.results[2].verdict.outcome, Outcome.better);
    },
  );

  test('constraints round-trip as JSON and describe themselves', () {
    final x = c('cpu.cores', 'ge', {'v': '8'}, ClauseMark.triangle);
    final back = SpecConstraint.fromJson(x.toJson());
    expect(
      (back.property, back.op, back.mark, back.weight),
      ('cpu.cores', 'ge', ClauseMark.triangle, 3),
    );
    expect(back.value, {'v': '8'});
    expect(x.describe(), '物理核数 不低于 8 核');
    expect(opsFor(specProperty('gas.t90')!).first, 'le');
    expect(opsFor(specProperty('mem.type')!), ['ge', 'eq']);
  });

  test('matching a class of 500 materials stays quick', () {
    final s = device('A');
    s.transaction(() {
      for (var i = 0; i < 500; i++) {
        material(s, 'IPC$i', 'computer.ipc', {
          'cpu.cores': {'v': '${4 + i % 16}'},
          'cpu.base_freq': {'v': '2.${i % 9}', 'u': 'GHz'},
          'mem.total': {'v': '${8 * (1 + i % 4)}', 'u': 'GiB'},
        });
      }
    });
    final sw = Stopwatch()..start();
    final r = s.matchSpec('computer.ipc', [
      c('cpu.cores', 'ge', {'v': '8'}),
      c('cpu.base_freq', 'ge', {'v': '2.3', 'u': 'GHz'}),
      c('mem.total', 'ge', {'v': '16', 'u': 'GiB'}),
    ], asOf: asOf);
    expect(r.candidates, hasLength(500));
    expect(sw.elapsedMilliseconds, lessThan(2000));
  });
}
