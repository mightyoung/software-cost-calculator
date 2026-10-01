import 'dart:convert';
import 'dart:io';

import 'package:supplier_core/supplier_core.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

void main() {
  late Store s;
  late String id;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('assistant_matching');
    s = device('matching');
    id = s.save('product', {...product('工控机'), 'spec_class': 'computer.ipc'});
  });
  tearDown(() {
    s.close();
    tmp.deleteSync(recursive: true);
  });
  Map<String, dynamic> match(String requirement) =>
      jsonDecode(
            s.runTool(
              'match_item',
              jsonEncode({'class': 'computer.ipc', 'requirement': requirement}),
            ),
          )
          as Map<String, dynamic>;

  test(
    'text-only origin requirement remains pending, never fully satisfied',
    () {
      final result = match('提供逐件激光铭牌溯源报告');
      final candidate = (result['candidates'] as List).single as Map;
      expect(result['text_clauses'], isNotEmpty);
      expect(candidate['group'], isNot('完全满足'));
      expect(candidate['qualification'], 'pending');
      expect(
        candidate['price_basis'],
        containsPair('project_normalized', false),
      );
    },
  );

  test('empty constraint list cannot certify any material', () {
    expect(
      s.matchSpec('computer.ipc', []).candidates.single.group,
      MatchGroup.partial,
    );
  });

  test('unconfirmed matching value remains visible and pending', () {
    s.setParam(id, 'cpu.cores', {'v': '8'}, confirmed: false);
    final candidate =
        (match('CPU物理核数不低于8核')['candidates'] as List).single as Map;
    expect(candidate['results'], isNotEmpty);
    expect(
      (candidate['results'] as List).first,
      containsPair('unconfirmed', true),
    );
    expect(candidate['qualification'], 'pending');
    expect(candidate['group'], isNot('完全满足'));
  });

  test(
    'a hard contradiction still fails despite unknown text and confirmation',
    () {
      s.setParam(id, 'cpu.cores', {'v': '4'}, confirmed: false);
      final candidate =
          (match('CPU物理核数不低于8核；所有零部件必须为国产')['candidates'] as List).single
              as Map;
      expect(candidate['group'], '不满足');
      expect(candidate['qualification'], 'contradicted');
    },
  );

  test('derived values inherit unconfirmed supporting parameters', () {
    s.setParam(id, 'mem.dimm_size', {'v': '8', 'u': 'GiB'}, confirmed: false);
    s.setParam(id, 'mem.dimm_count', {'v': '2'});
    final candidate = s
        .matchSpec('computer.ipc', [
          SpecConstraint('mem.total', 'ge', {'v': '16', 'u': 'GiB'}),
        ])
        .candidates
        .single;
    expect(candidate.results.single.unconfirmed, isTrue);
    expect(candidate.group, MatchGroup.partial);
  });

  test('reviewed stored requirements support confirmed values only', () {
    s.setParam(id, 'cpu.cores', {'v': '8'});
    s.createSpecRequest('测试需求', [
      draftItem('工控机', 'CPU物理核数不低于8核', specClass: 'computer.ipc'),
    ]);
    final itemId =
        s.db.select('SELECT id FROM spec_item').single['id'] as String;
    Map candidate() =>
        (jsonDecode(
                      s.runTool('match_item', jsonEncode({'item_id': itemId})),
                    )['candidates']
                    as List)
                .single
            as Map;
    expect(candidate()['qualification'], 'pending');
    s.saveClauses(itemId, [
      for (final clause in clausesOf(s.get('spec_item', itemId)!))
        clause.copyWith(reviewed: true),
    ]);
    expect(candidate()['qualification'], 'supported');
    expect(candidate()['group'], '完全满足');
    s.setParam(id, 'cpu.cores', {'v': '8'}, confirmed: false);
    expect(candidate()['qualification'], 'pending');
  });

  test('unknown parameters and dropping the sole clause never certify', () {
    final result = s.matchSpec('computer.ipc', [
      SpecConstraint('unknown.property', 'eq', {'v': '8'}),
    ]);
    expect(result.candidates.single.group, MatchGroup.partial);
    expect(result.relaxGain, isEmpty);
  });

  test('unconfirmed full-scale range propagates into converted accuracy', () {
    s.setParam(id, 'gas.range', {
      'min': '0',
      'max': '100',
      'u': 'ppm',
    }, confirmed: false);
    s.setParam(id, 'gas.accuracy', {'v': '1', 'basis': 'FS'});
    final result = s.matchSpec('computer.ipc', [
      SpecConstraint('gas.accuracy', 'le', {'v': '1', 'u': 'ppm'}),
    ]);
    expect(result.candidates.single.results.single.unconfirmed, isTrue);
    expect(result.candidates.single.group, MatchGroup.partial);
  });
}
