import 'dart:convert';
import 'dart:io';

import 'package:supplier_core/supplier_core.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

/// A model that answers every request with [reply], recording the prompts.
LlmClient fakeModel(Map<String, Object?> reply, List<String> prompts) =>
    LlmClient(
      const LlmConfig(apiKey: 'test'),
      transport: (body) async {
        prompts.add(jsonEncode(body['messages']));
        return {
          'choices': [
            {
              'message': {'content': jsonEncode(reply)},
            },
          ],
        };
      },
    );

void main() {
  setUp(() => tmp = Directory.systemTemp.createTempSync('supplier_fill'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('cable models decode after GB/T 9330, 5023, 12706 and 19666', () {
    Map<String, Object?> flat(String m) => {
      for (final MapEntry(:key, :value) in decodeCableModel(m).entries)
        key: value['v'],
    };
    expect(flat('ZR-KVVP-4×1.5'), {
      'cable.use': 'control',
      'cable.conductor': 'Cu',
      'cable.insulation': 'V',
      'cable.sheath': 'V',
      'cable.shield': 'P',
      'cable.flame': 'ZR',
      'cable.cores': '4',
      'cable.csa': '1.5',
    });
    expect(flat('RVV 3x2.5'), containsPair('cable.use', 'flexible'));
    expect(flat('RVV 3x2.5'), containsPair('cable.shield', 'none'));
    final power = flat('WDZB-YJLV22-0.6/1kV 3×120+1×70');
    expect(power['cable.use'], 'power');
    expect(power['cable.conductor'], 'Al');
    expect(power['cable.insulation'], 'YJ');
    expect(power['cable.flame'], 'ZB');
    expect(power['cable.cores'], '4');
    expect(power['cable.csa'], '120');
    expect(flat('NH-KYJVP2-7×2.5')['cable.fire_resistant'], true);
    expect(decodeCableModel('IS80-65-160'), isEmpty);
    expect(decodeCableModel('DN100'), isEmpty);
  });

  test('materials fill from model and text, unconfirmed with evidence', () {
    final s = device('A');
    final sensor = s.save('product', {
      ...product('温湿度变送器', unit: '个'),
      'specification': '测量范围-40~85℃；精度±0.2℃；RS485输出；IP66',
    });
    final cable = s.save('product', {
      ...product('控制电缆', unit: '米'),
      'model': 'ZR-KVVP-4×1.5',
      'spec_class': 'cable',
    });
    s.setParam(cable, 'cable.cores', {'v': '4'});
    s.save('product', product('离心泵')); // no template: skipped
    final plans = s.planParamFill();
    expect({for (final p in plans) p.productId}, {sensor, cable});
    final ps = plans.firstWhere((p) => p.productId == sensor);
    expect(ps.newClass, isTrue);
    expect(ps.classCode, 'sensor.th');
    expect(
      {for (final g in ps.guesses) g.property},
      {'th.temp_range', 'th.temp_accuracy', 'io.output', 'prot.ip'},
    );
    final pc = plans.firstWhere((p) => p.productId == cable);
    expect(pc.guesses.every((g) => g.source == 'decoder'), isTrue);
    expect(
      pc.guesses.map((g) => g.property),
      isNot(contains('cable.cores')),
      reason: 'values already set are kept',
    );

    final n = s.applyParamFill(plans);
    expect(n, ps.guesses.length + pc.guesses.length);
    expect(s.get('product', sensor)!.data['spec_class'], 'sensor.th');
    final range = s.paramsOf(sensor)['th.temp_range']!.data;
    expect(range['confirmed'], isFalse);
    expect(range['source'], 'rule');
    expect(range['evidence'], contains('-40~85'));
    expect(s.planParamFill(), isEmpty, reason: 'nothing left to fill');

    final issues = {for (final c in s.dataQuality()) c.key: c.count};
    expect(issues['products_unconfirmed_params'], 2);
    expect(issues['products_missing_key_params'], 1, reason: 'cable complete');
    expect(issues['products_unclassified'], 0);
  });

  test('a slash shares the prefix: OPC DA/UA names both', () {
    final c = parseClause('comm.gateway', 1, '支持Modbus TCP、OPC DA/UA协议');
    expect(c.constraints.single.value['vs'], [
      'Modbus TCP',
      'OPC DA',
      'OPC UA',
    ]);
    expect(c.hint, isNull);
  });

  group('AI reading', () {
    test('keeps what traces to the clause and drops the rest', () async {
      final clauses = draftItem(
        '网关',
        '支持Modbus TCP、OPC DA/UA；\n与现有系统适配；\n通道数不少于16路',
      ).clauses;
      expect(clauses[0].hint, isNull, reason: 'rules read OPC DA/UA');
      final prompts = <String>[];
      final llm = fakeModel({
        'clauses': [
          {
            'n': 1,
            'constraints': [
              // Rules read clause 1 fully, so it is not asked and this
              // answer is ignored.
              {
                'property': 'io.protocol',
                'op': 'all',
                'value': 'Modbus TCP、OPC DA、OPC UA',
                'evidence': 'Modbus TCP、OPC DA/UA',
              },
            ],
          },
          {
            'n': 2,
            'constraints': [
              // Invented number: dropped.
              {
                'property': 'gw.channels',
                'op': 'ge',
                'value': '32',
                'evidence': '与现有系统适配',
              },
              // Evidence not in the clause: dropped.
              {
                'property': 'gen.industrial',
                'op': 'is',
                'value': '是',
                'evidence': '工业级设计',
              },
              // Unknown parameter: dropped.
              {
                'property': 'x.made_up',
                'op': 'eq',
                'value': '1',
                'evidence': '适配',
              },
            ],
          },
        ],
      }, prompts);
      final r = await aiReadClauses(llm, 'comm.gateway', clauses);
      expect(r.added, 0);
      expect(r.dropped, 3);
      expect(r.clauses[1].isText, isTrue);
      expect(r.clauses[1].hint, contains('已丢弃'));
      expect(r.clauses[2], same(clauses[2]), reason: 'clean clauses stay');
      // Only the open clauses and the dictionary are sent.
      expect(prompts.single, contains('[2] 与现有系统适配'));
      expect(prompts.single, isNot(contains('[1]')));
      expect(prompts.single, isNot(contains('[3]')));
    });

    test('fills a text clause when every part is in the evidence', () async {
      final clauses = [SpecClause(1, '显卡：独立显卡显存两个G', hint: '待读')];
      final llm = fakeModel({
        'clauses': [
          {
            'n': 1,
            'constraints': [
              {
                'property': 'gpu.mem',
                'op': 'ge',
                'value': '2GB',
                'evidence': '显存两个G',
              },
              {
                'property': 'gpu.discrete',
                'op': 'is',
                'value': '是',
                'evidence': '独立显卡',
              },
              // Unit not written in the evidence: dropped.
              {
                'property': 'gpu.outputs',
                'op': 'ge',
                'value': '2路',
                'evidence': '显存两个',
              },
            ],
          },
        ],
      }, []);
      final r = await aiReadClauses(llm, 'computer.ipc', clauses);
      final c = r.clauses.single;
      expect(c.by, 'ai');
      expect(
        [for (final k in c.constraints) k.describe()],
        ['显存 不低于 2 GB', '独立显卡 为 是'],
      );
      expect(c.hint, allOf(contains('AI 补充了 2 个条件'), contains('1 个结果')));
      expect(c.reviewed, isFalse);
    });

    test('does not add a parameter another clause already reads', () async {
      final clauses = [
        SpecClause(1, '通过以太网分流转发', hint: '待读'),
        parseClause('comm.gateway', 2, '上行接口：以太网'),
      ];
      expect(clauses[1].constraints, isNotEmpty);
      final llm = fakeModel({
        'clauses': [
          {
            'n': 1,
            'constraints': [
              {
                'property': clauses[1].constraints.single.property,
                'op': 'any',
                'value': '以太网',
                'evidence': '以太网',
              },
            ],
          },
        ],
      }, []);
      final r = await aiReadClauses(llm, 'comm.gateway', clauses);
      expect(r.added, 0);
      expect(r.clauses.first.constraints, isEmpty);
    });

    test('verification rules one by one', () {
      final c = SpecClause(1, '温度测量范围-20℃~+80℃，防护等级不低于IP65');
      SpecConstraint? v(String p, String op, String value, String ev) =>
          verifyAiConstraint('sensor.th', c, {
            'property': p,
            'op': op,
            'value': value,
            'evidence': ev,
          });
      expect(v('th.temp_range', 'covers', '-20~80℃', '-20℃~+80℃'), isNotNull);
      expect(v('th.temp_range', 'ge', '-20~80℃', '-20℃~+80℃'), isNull);
      expect(v('th.temp_range', 'covers', '-20~85℃', '-20℃~+80℃'), isNull);
      expect(v('th.temp_range', 'covers', '-20~80K', '-20℃~+80℃'), isNull);
      expect(v('prot.ip', 'ip_ge', 'IP66', '防护等级不低于IP65'), isNull);
      expect(v('prot.ip', 'ip_ge', 'IP65', '防护等级不低于IP65'), isNotNull);
      expect(v('cpu.cores', 'ge', '8', '防护等级'), isNull, reason: 'not in class');
    });
  });

  test('spec tools for agents: dictionary and matching', () {
    final s = device('A');
    final p = s.save('product', {
      ...product('温湿度变送器', unit: '个'),
      'spec_class': 'sensor.th',
    });
    s.setParam(p, 'prot.ip', {
      'codes': ['IP66'],
    });
    Object? run(String name, Map<String, Object?> args) =>
        jsonDecode(s.runTool(name, jsonEncode(args)));
    final classes = run('spec_classes', {}) as List;
    expect(classes.map((c) => (c as Map)['class']), contains('sensor.th'));
    final params = run('spec_classes', {'class': 'sensor.th'}) as List;
    expect(params.map((x) => (x as Map)['code']), contains('prot.ip'));
    final m =
        run('match_item', {
              'class': 'sensor.th',
              'requirement': '防护等级不低于IP65\n与采集器适配',
            })
            as Map;
    expect(m['conditions'], ['防护等级 不低于 IP65']);
    expect(m['text_clauses'], ['与采集器适配']);
    final top = (m['candidates'] as List).single as Map;
    expect(top['group'], '基本满足', reason: '与采集器适配尚无可计算证据');
    expect(top['qualification'], 'pending');
    expect(top['pending_clauses'], isTrue);
    expect(((top['results'] as List).single as Map)['outcome'], '正偏离');
    expect(((top['results'] as List).single as Map)['unconfirmed'], isFalse);

    // A separate, fully structured requirement can be supported once its
    // reading is reviewed; this does not certify the compatibility clause.
    s.createSpecRequest('已审核防护要求', [
      draftItem('变送器', '防护等级不低于IP65', specClass: 'sensor.th'),
    ]);
    final itemId =
        s.db.select('SELECT id FROM spec_item').single['id'] as String;
    s.saveClauses(itemId, [
      for (final clause in clausesOf(s.get('spec_item', itemId)!))
        clause.copyWith(reviewed: true),
    ]);
    final reviewed = run('match_item', {'item_id': itemId}) as Map;
    final supported = (reviewed['candidates'] as List).single as Map;
    expect(supported['group'], '完全满足');
    expect(supported['qualification'], 'supported');
    expect(supported['pending_clauses'], isFalse);
    expect((run('match_item', {'class': 'nope'}) as Map)['error'], isNotNull);
  });
}
