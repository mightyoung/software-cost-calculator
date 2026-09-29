import 'dart:io';

import 'package:supplier_core/supplier_core.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

SpecProperty p(String code) => specProperty(code)!;
Map<String, Object?> parse(String code, String text) =>
    parseParamText(p(code), text)!;
Outcome ge(String code, String have, String want) =>
    atLeastAsGood(p(code), parse(code, have), parse(code, want)).outcome;

void main() {
  setUp(() => tmp = Directory.systemTemp.createTempSync('supplier_spec'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('the dictionary is consistent', () {
    final codes = <String>{};
    for (final prop in specProperties) {
      if (prop.ordered) {
        expect(prop.restrictive, isTrue, reason: '${prop.code} is ordered');
      }
      expect(codes.add(prop.code), isTrue, reason: 'duplicate ${prop.code}');
      if (const [
            ParamType.num,
            ParamType.range,
            ParamType.tol,
          ].contains(prop.type) &&
          prop.kind != null) {
        final kind = quantityKinds[prop.kind];
        expect(kind, isNotNull, reason: prop.code);
        expect(kind!.unit(prop.unit!), isNotNull, reason: prop.code);
      }
    }
    final classes = <String>{};
    for (final c in specClasses) {
      expect(classes.add(c.code), isTrue);
      if (c.parent != null) expect(specClass(c.parent!), isNotNull);
      for (final cp in classParams(c.code)) {
        expect(
          specProperty(cp.property),
          isNotNull,
          reason: '${c.code} ${cp.property}',
        );
      }
    }
    // Inherited parameters come first, each once.
    final ipc = classParams('computer.ipc').map((c) => c.property).toList();
    expect(ipc.first, 'cpu.arch');
    expect(ipc.toSet().length, ipc.length);
  });

  test('how people write values', () {
    expect(parse('cpu.cores', '八核及以上'), {'v': '8'});
    expect(parse('cpu.cores', '十六核'), {'v': '16'});
    expect(parse('cpu.base_freq', '2.3GHz及以上'), {'v': '2.3', 'u': 'GHz'});
    expect(parse('mem.total', '16GB'), {'v': '16', 'u': 'GiB'});
    expect(parse('mem.speed', '2666MHz'), {'v': '2666', 'u': 'MT/s'});
    expect(parse('th.temp_range', '温度-20℃~+80℃'), {
      'min': '-20',
      'max': '80',
      'u': 'Cel',
    });
    expect(parse('th.rh_range', '0%~+100%RH'), {
      'min': '0',
      'max': '100',
      'u': '%RH',
    });
    expect(parse('gas.range', '0～100ppm'), {
      'min': '0',
      'max': '100',
      'u': 'ppm',
    });
    expect(parse('gas.range', '0～100%O2'), {
      'min': '0',
      'max': '100',
      'u': '%VOL',
    });
    expect(parse('th.temp_accuracy', '优于±0.3℃'), {'v': '0.3', 'u': 'Cel'});
    expect(parse('gas.accuracy', '不低于±1%FS'), {'v': '1', 'basis': 'FS'});
    expect(parse('gas.t90', '≤30秒'), {'v': '30', 'u': 's'});
    expect(parse('io.output', '4-20mA或RS485'), {
      'vs': ['4-20mA', 'RS485'],
    });
    expect(
      parse('io.protocol', 'Modbus TCP、OPC DA/UA、Siemens S7、TCP/UDP自定义协议'),
      {
        'vs': ['Modbus TCP', 'OPC DA', 'Siemens S7', 'TCP/UDP'],
      },
      reason: '"Modbus TCP" is not also read as TCP; "DA/UA" needs care',
    );
    expect(parse('prot.ip', 'IP66/67'), {
      'codes': ['IP66', 'IP67'],
    });
    expect(parse('gpu.discrete', '支持'), {'v': true});
    expect(parse('gen.brand_origin', '要求国产品牌'), {'v': 'domestic'});
    final ex = parse('prot.ex', 'EX d IIBT4 Gb')['marks']! as List;
    expect(ex.single, {
      'types': ['d'],
      'group': 'IIB',
      'temp': 'T4',
      'epl': 'Gb',
    });
    expect((parse('prot.ex', 'ExdIIBT4')['marks']! as List).single, {
      'types': ['d'],
      'group': 'IIB',
      'temp': 'T4',
      'epl': null,
    });
    expect((parse('prot.ex', 'Ex ia IIC T4 Ga')['marks']! as List).single, {
      'types': ['ia'],
      'group': 'IIC',
      'temp': 'T4',
      'epl': 'Ga',
    });
    expect(parseParamText(p('disp.res'), '2K'), isNull, reason: 'ambiguous');
    // Round trip through display.
    expect(
      formatParamValue(p('th.temp_range'), parse('th.temp_range', '-40~85℃')),
      '-40～85 ℃',
    );
    expect(
      formatParamValue(p('gas.accuracy'), {'v': '1', 'basis': 'FS'}),
      '±1 %FS',
    );
  });

  test('numbers compare across units and by direction', () {
    expect(ge('cpu.cores', '16', '8'), Outcome.better);
    expect(ge('cpu.cores', '8', '8'), Outcome.exact);
    expect(ge('cpu.cores', '4', '8'), Outcome.worse);
    expect(ge('cpu.base_freq', '2300MHz', '2.3GHz'), Outcome.exact);
    expect(ge('mem.total', '16384MB', '16GB'), Outcome.exact, reason: 'binary');
    // Lower is better: resolution "不低于 0.1℃" means ≤ 0.1℃.
    expect(ge('th.temp_resolution', '0.01℃', '0.1℃'), Outcome.better);
    expect(ge('th.temp_resolution', '1℃', '0.1℃'), Outcome.worse);
    expect(ge('gas.t90', '20s', '30s'), Outcome.better);
    // Temperature differences: 0.54℉ = 0.3℃ (no offset).
    expect(ge('th.temp_resolution', '0.54℉', '0.3℃'), Outcome.exact);
    // %VOL and ppm are both volume fractions; %LEL is not.
    expect(ge('gas.resolution', '0.01%VOL', '100ppm'), Outcome.exact);
    final lel = atLeastAsGood(
      p('gas.resolution'),
      {'v': '1', 'u': '%LEL'},
      {'v': '100', 'u': 'ppm'},
    );
    expect(lel.outcome, Outcome.unknown);
  });

  test('ranges must cover the requirement; tolerances compare by basis', () {
    Verdict cov(String code, String have, String want) =>
        covers(p(code), parse(code, have), parse(code, want));
    expect(cov('th.temp_range', '-40~85℃', '-20~80℃').outcome, Outcome.better);
    expect(cov('th.temp_range', '-20~80℃', '-20~80℃').outcome, Outcome.exact);
    expect(cov('th.temp_range', '-10~85℃', '-20~80℃').outcome, Outcome.worse);
    // -4℉ to 176℉ is exactly -20℃ to 80℃.
    expect(cov('th.temp_range', '-4~176℉', '-20~80℃').outcome, Outcome.exact);
    expect(
      cov('th.temp_range', '233.15~353.15K', '-40~80℃').outcome,
      Outcome.exact,
    );

    Verdict tol(String have, String want, {String? span}) => toleranceWithin(
      p('gas.accuracy'),
      parse('gas.accuracy', have),
      parse('gas.accuracy', want),
      span: span == null ? null : parse('gas.range', span),
    );
    expect(tol('±0.5ppm', '±1ppm').outcome, Outcome.better);
    expect(tol('±2%FS', '±1%FS').outcome, Outcome.worse);
    expect(tol('±1%FS', '±1ppm', span: '0~100ppm').outcome, Outcome.exact);
    expect(tol('±1%FS', '±1ppm').outcome, Outcome.unknown, reason: 'no span');
    expect(
      toleranceWithin(
        p('th.temp_accuracy'),
        parse('th.temp_accuracy', '±0.2℃'),
        parse('th.temp_accuracy', '±0.3℃'),
      ).outcome,
      Outcome.better,
    );
  });

  test('ordered choices, interfaces and catalogs', () {
    expect(rankAtLeast(p('mem.type'), 'DDR4', 'DDR4').outcome, Outcome.exact);
    expect(rankAtLeast(p('mem.type'), 'DDR3', 'DDR4').outcome, Outcome.worse);
    expect(rankAtLeast(p('mem.type'), 'DDR5', 'DDR4').outcome, Outcome.unknown);
    expect(offersAny(['RS485'], ['4-20mA', 'RS485']).outcome, Outcome.exact);
    expect(offersAny(['0-10V'], ['4-20mA', 'RS485']).outcome, Outcome.worse);
    expect(
      offersAll(['Modbus TCP'], ['Modbus TCP', 'OPC UA']).outcome,
      Outcome.worse,
    );

    final entries = [
      {
        'name': '安全可靠测评结果',
        'batch': '2026年第3号',
        'level': 'Ⅲ',
        'valid_until': '2029-09-20',
      },
    ];
    expect(
      listedIn(entries, '《军用关键软硬件自主可控产品目录》', on: '2026-09-29').outcome,
      Outcome.unknown,
      reason: 'another catalog never stands in',
    );
    expect(
      listedIn(entries, '安全可靠测评结果', on: '2026-09-29').outcome,
      Outcome.exact,
    );
    expect(
      listedIn(entries, '安全可靠测评结果', level: 'Ⅱ', on: '2026-09-29').outcome,
      Outcome.better,
    );
    expect(
      listedIn(entries, '安全可靠测评结果', on: '2029-10-01').outcome,
      Outcome.worse,
      reason: 'expired',
    );
  });

  test('IP codes follow IEC 60529: immersion does not prove jets', () {
    Verdict ip(List<String> have) => ipAtLeast(have, 'IP65');
    expect(ip(['IP65']).outcome, Outcome.exact);
    expect(ip(['IP66']).outcome, Outcome.better);
    expect(ip(['IP54']).outcome, Outcome.worse);
    final v = ip(['IP67']);
    expect(v.outcome, Outcome.worse);
    expect(v.note, contains('只证明浸水防护'));
    expect(ip(['IP66', 'IP67']).outcome, Outcome.better, reason: 'dual coded');
    expect(ipAtLeast(['IP68'], 'IP67').outcome, Outcome.better);
    expect(ipAtLeast(['IP66'], 'IP67').outcome, Outcome.worse);
    expect(
      ipAtLeast(['IPX7'], 'IP65').outcome,
      Outcome.worse,
      reason: 'dust untested',
    );
  });

  test('Ex markings follow IEC 60079-0 substitution rules', () {
    final want = parseExMark('Ex d IIB T4 Gb')!;
    Verdict ex(String have) => exAtLeast(parseExMarks(have), want);
    expect(ex('Ex d IIB T4 Gb').outcome, Outcome.exact);
    expect(ex('Ex db IIB T4 Gb').outcome, Outcome.exact, reason: 'd = db');
    final hi = ex('Ex db IIC T6 Gb');
    expect(hi.outcome, Outcome.better);
    expect(hi.note, contains('组别 IIC'));
    expect(ex('Ex d IIA T4 Gb').outcome, Outcome.worse);
    expect(ex('Ex d IIB T3 Gb').outcome, Outcome.worse);
    expect(ex('Ex d IIB T4 Gc').outcome, Outcome.worse);
    expect(
      ex('Ex ia IIC T4 Ga').outcome,
      Outcome.unknown,
      reason: 'type differs',
    );
    expect(
      ex('Ex tb IIIC T85℃ Db').outcome,
      Outcome.worse,
      reason: 'dust ≠ gas',
    );
    // EPL omitted on the material: implied by the type of protection.
    expect(ex('Ex d IIB T4').outcome, Outcome.exact);
    // Requirement without EPL does not check it; several markings: best wins.
    expect(
      exAtLeast(
        parseExMarks('Ex d IIA T4 Gb / Ex d IIC T5 Gb'),
        parseExMark('ExdIIBT4')!,
      ).outcome,
      Outcome.better,
    );
  });

  test('values are validated against the property', () {
    expect(
      () => normalizeParamValue(p('cpu.base_freq'), {'v': '2', 'u': 'ms'}),
      throwsFormatException,
    );
    expect(
      () => normalizeParamValue(p('th.temp_range'), {
        'min': '80',
        'max': '-20',
        'u': 'Cel',
      }),
      throwsFormatException,
    );
    expect(
      () => normalizeParamValue(p('mem.type'), {'v': 'DDR9'}),
      throwsFormatException,
    );
    expect(
      () => normalizeParamValue(p('prot.ip'), {
        'codes': ['IP7X'],
      }),
      throwsFormatException,
    );
    expect(
      normalizeParamValue(p('gas.target'), {
        'vs': ['偏二甲肼', 'O2', 'O2'],
      }),
      {
        'vs': ['偏二甲肼', 'O2'],
      },
      reason: 'open list, duplicates dropped',
    );
  });

  test('parameters are records with derived ids; completeness', () {
    final s = device('A');
    final prod = s.save('product', {
      ...product('温湿度变送器'),
      'spec_class': 'sensor.th',
    });
    final id = s.setParam(
      prod,
      'th.temp_range',
      parse('th.temp_range', '-40~85℃'),
    );
    expect(id, paramRecordId(prod, 'th.temp_range'));
    expect(
      s.setParam(prod, 'th.temp_range', parse('th.temp_range', '-40~85℃')),
      id,
      reason: 'unchanged value writes nothing',
    );
    expect(s.get('product_param', id)!.version, 1);
    s.setParam(
      prod,
      'prot.ip',
      {
        'codes': ['IP66'],
      },
      source: 'ai',
      confirmed: false,
      evidence: '防护等级 IP66',
    );
    expect(
      s.paramsOf(prod).keys,
      unorderedEquals(['th.temp_range', 'prot.ip']),
    );
    expect(s.paramCompleteness(prod), (filled: 1, total: 5));
    expect(s.confirmParams(prod), 1);

    s.clearParam(prod, 'prot.ip');
    expect(s.paramsOf(prod).keys, ['th.temp_range']);
    s.setParam(prod, 'prot.ip', {
      'codes': ['IP65'],
    });
    expect(s.paramsOf(prod)['prot.ip']!.data['value'], {
      'codes': ['IP65'],
    }, reason: 'a cleared parameter comes back under the same id');

    // A code this build does not know is kept as it is.
    s.setParam(prod, 'x.pump.flow', {'v': '50', 'u': 'm3/h'});
    expect(s.paramsOf(prod)['x.pump.flow']!.data['value'], {
      'v': '50',
      'u': 'm3/h',
    });
    expect(
      () => s.setParam(prod, 'Bad Code', {'v': '1'}),
      throwsFormatException,
    );
    expect(
      () => s.save('product', {...product('x'), 'spec_class': 'Not A Code'}),
      throwsFormatException,
    );
  });

  test(
    'two devices editing different parameters of one material both keep theirs',
    () {
      final a = device('A');
      final prod = a.save('product', {
        ...product('工控机'),
        'spec_class': 'computer.ipc',
      });
      a.setParam(prod, 'cpu.cores', {'v': '8'});
      a.exportTo('${tmp.path}/a0.siq');
      final b = device('B');
      b.importFrom('${tmp.path}/a0.siq');

      a.setParam(prod, 'cpu.cores', {'v': '16'});
      b.setParam(prod, 'mem.total', {'v': '32', 'u': 'GiB'});
      // Both create the same new parameter independently: one record.
      a.setParam(prod, 'mem.type', {'v': 'DDR4'});
      b.setParam(prod, 'mem.type', {'v': 'DDR4'});
      a.exportTo('${tmp.path}/a.siq');
      b.exportTo('${tmp.path}/b.siq');
      a.importFrom('${tmp.path}/b.siq');
      b.importFrom('${tmp.path}/a.siq');
      for (final s in [a, b]) {
        final params = s.paramsOf(prod);
        expect(params['cpu.cores']!.data['value'], {'v': '16'});
        expect(params['mem.total']!.data['value'], {'v': '32', 'u': 'GiB'});
        expect(params['mem.type']!.data['value'], {'v': 'DDR4'});
      }
      expect(
        a.db.select('SELECT count(*) AS n FROM product_param').first['n'],
        3,
      );
    },
  );

  test('free attributes become unconfirmed parameters after a preview', () {
    final s = device('A');
    expect(guessSpecClass(['气体浓度检测探头（毒气）']), 'sensor.gas');
    expect(guessSpecClass(['工控机']), 'computer.ipc');
    expect(guessSpecClass(['控制信号链路', null]), isNull);
    final prod = s.save('product', {
      ...product('温湿度变送器'),
      'attributes': {'温度范围': '-40~85℃', '防护等级': 'IP66', '颜色': '白'},
    });
    s.save('product', product('无属性的物料'));
    final plans = s.planAttributeMigration();
    expect(plans, hasLength(1));
    final plan = plans.single;
    expect((plan.classCode, plan.newClass), ('sensor.th', true));
    expect(
      [for (final p in plan.params) p.property.code],
      ['th.temp_range', 'prot.ip'],
    );
    expect(plan.kept, ['颜色']);
    expect(s.paramsOf(prod), isEmpty, reason: 'planning writes nothing');

    expect(s.applyAttributeMigration(plans), 2);
    final d = s.get('product', prod)!.data;
    expect(d['spec_class'], 'sensor.th');
    expect(d['attributes'], {'颜色': '白'});
    final ip = s.paramsOf(prod)['prot.ip']!.data;
    expect(
      (ip['source'], ip['confirmed'], ip['evidence']),
      ('import', false, '关键属性 防护等级：IP66'),
    );
    expect(s.planAttributeMigration(), isEmpty, reason: 'nothing left to do');
  });
}
