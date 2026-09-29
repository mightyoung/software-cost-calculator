import 'dart:io';

import 'package:supplier_core/supplier_core.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

import 'spec_sample.dart';

void main() {
  test('the sample requirement: ≥70% of clauses right, none silently wrong', () {
    var total = 0, right = 0, flagged = 0;
    final silent = <String>[], report = StringBuffer();
    for (final (name, text, want) in sample) {
      final item = draftItem(name, text);
      expect(
        item.clauses,
        hasLength(want.length),
        reason: '$name: ${[for (final c in item.clauses) c.text]}',
      );
      for (final (i, c) in item.clauses.indexed) {
        total++;
        final got = {
          for (final x in c.constraints) sampleKey(x.property, x.op, x.value),
        };
        final exp = {for (final (p, op, v) in want[i]) sampleKey(p, op, v)};
        final ok = got.length == exp.length && got.containsAll(exp);
        if (ok) right++;
        if (c.hint != null) flagged++;
        if (!ok && c.hint == null && got.isNotEmpty)
          silent.add('$name ${c.text}');
        if (!ok) {
          report.writeln(
            '✗ $name「${c.text}」\n  got  $got\n  want $exp\n  hint ${c.hint}',
          );
        }
      }
    }
    final rate = right / total;
    // ignore: avoid_print
    print(
      'clauses $total, right $right (${(rate * 100).round()}%), flagged $flagged',
    );
    expect(silent, isEmpty, reason: '$report');
    expect(rate, greaterThanOrEqualTo(0.7), reason: '$report');
  });

  test('classes come from the name, then the text', () {
    expect(draftItem('工控机', '').specClass, 'computer.ipc');
    expect(draftItem('控制信号链路', '控制电缆采用阻燃型').specClass, 'cable');
    expect(draftItem('辅材', '镀锌钢管').specClass, isNull);
  });

  test('clause splitting: numbering, inline numbers, headings, marks', () {
    expect(splitClauses('主要技术指标：\n（1）量程：0～100ppm；（2）分辨率：0.1ppm；'), [
      '（1）量程：0～100ppm',
      '（2）分辨率：0.1ppm',
    ]);
    expect(splitClauses('A；B。C'), ['A', 'B', 'C']);
    expect(splitClauses('★（4）防护等级不低于IP65。\n（1）a；★（2）b；（3）c'), [
      '★（4）防护等级不低于IP65',
      '（1）a',
      '★（2）b',
      '（3）c',
    ]);
    final star = parseClause('sensor.th', 1, '★（5）防护等级不低于IP65');
    expect(star.mark, ClauseMark.star);
    expect(star.constraints.single.mark, ClauseMark.star);
    expect(
      parseClause('sensor.th', 1, '▲防护等级不低于IP65').mark,
      ClauseMark.triangle,
    );
    expect(
      parseClause('sensor.th', 1, '防护等级IP65（实质性条款）').mark,
      ClauseMark.star,
    );
  });

  test('hard cases never parse silently', () {
    // "不小于" on resolution (smaller is better) keeps the words but asks.
    final res = parseClause('sensor.gas', 1, '分辨率不小于0.1ppm');
    expect(res.constraints.single.op, 'ge');
    expect(res.hint, contains('方向相反'));
    // %LEL is not ppm; an unknown unit stays unread.
    final lel = parseClause('sensor.gas', 1, '量程：0～100%LEL');
    expect(lel.constraints.single.value['u'], '%LEL');
    final odd = parseClause('display.monitor', 1, '分辨率不小于2K');
    expect(odd.constraints, isEmpty);
    expect(odd.hint, isNotNull);
    // Without a work/environment cue a temperature range is the measuring
    // range, with one it is the operating range.
    expect(
      parseClause('sensor.th', 1, '温度-40~80℃').constraints.single.property,
      'th.temp_range',
    );
    expect(
      parseClause('sensor.th', 1, '工作温度-40~80℃').constraints.single.property,
      'env.op_temp',
    );
    // Negated features are not read as "has".
    final no = parseClause('computer.ipc', 1, '无独立显卡');
    expect(no.constraints, isEmpty);
    expect(no.hint, contains('否定'));
  });

  test('pasted tables and paragraphs', () {
    final table = specItemsFromText(
      '序号\t设备名称\t主要指标要求\t数量\t单位\n'
      '1\t工控机\tCPU：八核及以上\t5\t台\n'
      '\t\t内存：DDR4 16GB\t\t\n',
    );
    expect(table.single.name, '工控机');
    expect((table.single.qty, table.single.unit), ('5', '台'));
    expect(table.single.clauses, hasLength(2));
    final paras = specItemsFromText('显示器\n尺寸不小于27英寸\n\n工控机：\nCPU八核');
    expect([for (final p in paras) p.name], ['显示器', '工控机']);
    expect(paras.first.clauses.single.constraints.single.property, 'disp.size');
  });

  group('stored requirements', () {
    setUp(() => tmp = Directory.systemTemp.createTempSync('supplier_req'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('save, review, choose and answer text clauses', () {
      final s = device('A');
      final item = draftItem(
        '温湿度传感器',
        '（1）测量范围，温度-20℃~+80℃\n（2）防护等级不低于IP65\n（3）与采集器适配',
        qty: '25',
        unit: '个',
      );
      final req = s.createSpecRequest('泵房监控', [item], sourceName: '粘贴文本');
      final rec = s.specItemsOf(req).single;
      expect(rec.data['qty'], '25');
      final clauses = clausesOf(rec);
      expect(clauses.map((c) => c.isText), [false, false, true]);

      // Reviewing: mark the IP clause ★.
      s.saveClauses(rec.id, [
        clauses[0].copyWith(reviewed: true),
        clauses[1].copyWith(mark: ClauseMark.star, reviewed: true),
        clauses[2].copyWith(reviewed: true),
      ]);
      final reviewed = clausesOf(s.get('spec_item', rec.id)!);
      expect(reviewed[1].constraints.single.mark, ClauseMark.star);

      final p = s.save('product', {
        ...product('YAWS-200', unit: '个'),
        'spec_class': 'sensor.th',
      });
      s.setParam(p, 'th.temp_range', {'min': '-40', 'max': '85', 'u': 'Cel'});
      s.setParam(p, 'prot.ip', {
        'codes': ['IP66'],
      }, confirmed: false);
      s.chooseProduct(rec.id, p);
      var rows = snapshotRows(s.get('spec_item', rec.id)!)!;
      expect(rows[0]['outcome'], 'better');
      expect(rows[0]['response'], contains('-40～85'));
      expect(rows[1]['note'], contains('参数未确认'));
      expect(rows[2]['manual'], isTrue);
      expect(rows[2]['outcome'], isNull);

      s.setClauseResponse(rec.id, 3, '支持 RS485，与采集器适配', Outcome.exact);
      // Choosing again keeps the person's answer to the text clause.
      s.chooseProduct(rec.id, p);
      rows = snapshotRows(s.get('spec_item', rec.id)!)!;
      expect(rows[2]['response'], '支持 RS485，与采集器适配');
      expect(rows[2]['outcome'], 'exact');

      final table = deviationTable(s, req);
      expect(table.headings, {0});
      expect(table.rows[0][3], '定选：YAWS-200');
      expect(table.rows.skip(1).map((r) => (r[1], r[4])), [
        ('', '正偏离'),
        ('★', '正偏离'),
        ('', '无偏离'),
      ]);
      expect(table.rows[2][3], '防护等级 IP66');
      expect(table.rows[3][5], '人工判断');
      final book = readXlsx(s.deviationXlsx(req));
      expect(book.sheets.single.rows[3].map((c) => c.display), deviationHeader);

      s.deleteSpecRequest(req);
      expect(s.specItemsOf(req), isEmpty);
      expect(s.specRequests(), isEmpty);
    });

    test('budget lines to be inquired become items; choosing fills them', () {
      final s = device('A');
      final pro = s.save('project', project('P1'));
      final line = s.save('project_item', {
        ...item(pro, 'material', name: '工控机', qty: '5'),
        'requirement': 'CPU：八核及以上；内存：DDR4 16GB',
        'notes': '清单单位：套',
      });
      final p = s.save('product', product('IPC-610', unit: '件'));
      s.save('project_item', item(pro, 'material', productId: p));
      final drafts = s.draftsFromProject(pro);
      expect(drafts.single.projectItemId, line);
      expect(drafts.single.specClass, 'computer.ipc');
      expect(drafts.single.clauses, hasLength(2));
      final req = s.createSpecRequest('P1 技术要求', drafts, projectId: pro);
      final rec = s.specItemsOf(req).single;
      expect(rec.data['qty'], '5');
      s.chooseProduct(rec.id, p);
      expect(s.get('project_item', line)!.data['product_id'], p);
      expect(s.specRequests(projectId: pro).single.id, req);
    });

    test('changing the class re-reads unreviewed clauses only', () {
      final s = device('A');
      final req = s.createSpecRequest('x', [
        draftItem('某设备', '防护等级IP65\n防爆等级不低于ExdIIBT4'),
      ]);
      final rec = s.specItemsOf(req).single;
      expect(rec.data['spec_class'], isNull);
      final c = clausesOf(rec);
      expect(c.every((x) => x.isText), isTrue);
      s.saveClauses(rec.id, [
        c[0],
        c[1].copyWith(reviewed: true),
      ], specClass: 'alarm.av');
      final after = clausesOf(s.get('spec_item', rec.id)!);
      expect(after[0].constraints.single.property, 'prot.ip');
      expect(after[1].isText, isTrue);
    });

    test('bad clauses are refused', () {
      final s = device('A');
      final req = s.createSpecRequest('x', []);
      Map<String, Object?> item(Object clause) => {
        'request_id': req,
        'seq': 1,
        'name': 'x',
        'spec_class': null,
        'qty': null,
        'unit': null,
        'text': null,
        'project_item_id': null,
        'clauses': [clause],
        'chosen_product_id': null,
        'notes': null,
      };
      final good = parseClause('sensor.th', 1, '防护等级IP65').toJson();
      s.save('spec_item', item(good));
      expect(
        () => s.save('spec_item', item({...good, 'mark': 'gold'})),
        throwsFormatException,
      );
      final cs = (good['cs']! as List).single as Map;
      expect(
        () => s.save(
          'spec_item',
          item({
            ...good,
            'cs': [
              {...cs, 'op': 'covers'},
            ],
          }),
        ),
        throwsFormatException,
      );
    });
  });
}
