// Real-API accuracy check of the data assistant: seeds a small realistic
// database, asks fixed questions and checks each answer for the facts the
// core computes itself. Only Store.save/ask and core queries are used, so
// the same file also runs against older versions for a before/after score.
// The key is read from the environment and never written anywhere.
//   DEEPSEEK_API_KEY=sk-... dart run tool/ai_eval.dart [model]
//   dart run tool/ai_eval.dart --dry   (questions and expected facts only)
import 'dart:io';

import 'package:supplier_core/supplier_core.dart';

Future<void> main(List<String> args) async {
  if (args.contains('--dry')) {
    final dir = Directory.systemTemp.createTempSync('ai_eval');
    final s = Store.open('${dir.path}/a.db', device: 'EVAL');
    for (final (i, (q, facts)) in _seed(s).indexed) {
      stdout.writeln('${i + 1}. $q → ${facts.join('、')}');
    }
    s.close();
    dir.deleteSync(recursive: true);
    return;
  }
  final key = Platform.environment['DEEPSEEK_API_KEY'];
  if (key == null || key.isEmpty) {
    stderr.writeln('请先设置环境变量 DEEPSEEK_API_KEY');
    exitCode = 64;
    return;
  }
  final llm = LlmClient(
    LlmConfig(apiKey: key, model: args.isEmpty ? 'deepseek-flash' : args.first),
  );
  final dir = Directory.systemTemp.createTempSync('ai_eval');
  final s = Store.open('${dir.path}/a.db', device: 'EVAL');
  final cases = _seed(s);
  var passed = 0;
  final sw = Stopwatch()..start();
  for (final (i, (question, expected)) in cases.indexed) {
    String answer;
    try {
      answer = await s.ask(llm, question);
    } on LlmException catch (e) {
      answer = '（出错：${e.message}）';
    }
    final flat = answer.replaceAll(RegExp(r'[,，\s]'), '');
    final missing = [
      for (final e in expected)
        if (!flat.contains(e)) e,
    ];
    if (missing.isEmpty) passed++;
    stdout.writeln(
      '${missing.isEmpty ? '✓' : '✗'} ${i + 1}. $question\n'
      '   ${answer.replaceAll('\n', ' ')}'
      '${missing.isEmpty ? '' : '\n   缺少：${missing.join('、')}'}',
    );
  }
  stdout.writeln(
    '\n关键词命中 $passed/${cases.length}（不是语义正确率），用时 ${sw.elapsed.inSeconds} 秒',
  );
  if (passed != cases.length) exitCode = 1;
  s.close();
  dir.deleteSync(recursive: true);
}

Map<String, Object?> _blank(List<String> fields, Map<String, Object?> v) => {
  for (final f in fields) f: null,
  ...v,
};

/// Seeds the data and returns (question, facts the answer must contain).
List<(String, List<String>)> _seed(Store s) {
  final today = localDay(s.clock());
  final old = localDay(s.clock().subtract(const Duration(days: 200)));
  String sup(String name, [List<String> aliases = const []]) => s.save(
    'supplier',
    _blank(Supplier.fields, {
      'name': name,
      'aliases': aliases,
      'categories': <String>[],
    }),
  );
  final jia = sup('上海甲泵业有限公司', ['甲泵']);
  final yi = sup('乙机电设备公司');
  final bing = sup('丙阀门厂');
  s.save('contact', {
    'supplier_id': jia,
    'name': '张经理',
    'phone': '13800001111',
    'wechat': null,
    'email': null,
    'notes': null,
  });
  String prod(String name, String model, String unit) => s.save(
    'product',
    _blank(Product.fields, {'name': name, 'model': model, 'unit': unit}),
  );
  final pump = prod('离心水泵', 'IS80-65-160', '台');
  final valve = prod('闸阀', 'Z41H-16C DN100', '个');
  final cable = prod('电缆', 'YJV-4x25', '米');
  String project(String code, String name, String contract) => s.save(
    'project',
    _blank(Project.fields, {
      'code': code,
      'name': name,
      'status': 'active',
      'currency': 'CNY',
      'tax_mode': 'included',
      'markup_rate': '15',
      'contract_amount': contract,
    }),
  );
  final pro = project('P-001', '泵房改造', '100000');
  project('P-002', '配电柜更换', '50000');
  String item(Map<String, Object?> v) => s.save(
    'project_item',
    _blank(ProjectItem.fields, {'project_id': pro, ...v}),
  );
  final pumpLine = item({
    'category': 'material',
    'product_id': pump,
    'qty': '2',
    'unit': '台',
    'unit_cost': '12500',
  });
  final valveLine = item({
    'category': 'material',
    'product_id': valve,
    'qty': '4',
    'unit': '个',
    'unit_cost': '0',
  });
  final cableLine = item({
    'category': 'material',
    'product_id': cable,
    'qty': '300',
    'unit': '米',
    'unit_cost': '60',
  });
  item({
    'category': 'labor',
    'name': '安装调试',
    'qty': '1',
    'unit': '项',
    'unit_cost': '5000',
  });
  String quote(
    String supplier,
    String product,
    String price,
    String unit, [
    Map<String, Object?> extra = const {},
  ]) => s.save(
    'quotation',
    _blank(Quotation.fields, {
      'supplier_id': supplier,
      'product_id': product,
      'price': price,
      'currency': 'CNY',
      'tax_mode': 'included',
      'unit_snapshot': unit,
      'min_qty': '1',
      'quoted_on': today,
      'project_id': pro,
      'inquirer_name': '王工',
      'inquiry_precision': 'date',
      'inquiry_date': today,
      'capture_mode': 'standard',
      ...extra,
    }),
  );
  final pumpJia = quote(jia, pump, '12500', '台');
  quote(yi, pump, '11800', '台', {'extra_cost': '2000'});
  quote(bing, pump, '9000', '台', {'price_basis': 'verbal'});
  final valveBing = quote(bing, valve, '850', '个', {
    'quoted_on': old,
    'inquiry_date': old,
    'valid_until': localDay(s.clock().subtract(const Duration(days: 100))),
  });
  quote(yi, valve, '920', '个');
  final cableYi = quote(yi, cable, '58.5', '米', {'min_qty': '500'});
  // Budget lines that use an expired quote and one below its minimum order,
  // and a line still to be inquired: each gets a warning.
  for (final (line, q, cost) in [
    (valveLine, valveBing, '850'),
    (cableLine, cableYi, '58.5'),
  ]) {
    s.save('project_item', {
      ...s.get('project_item', line)!.data,
      'quotation_id': q,
      'unit_cost': cost,
    }, id: line);
  }
  item({
    'category': 'material',
    'name': '变频控制柜',
    'qty': '1',
    'unit': '面',
    'unit_cost': '0',
  });
  s.award(pumpJia, itemId: pumpLine, dealPrice: '12000', note: '综合最低');
  final inq = s.save('inquiry', {
    'project_id': pro,
    'title': '泵房设备询价',
    'item_ids': [pumpLine, valveLine],
    'supplier_ids': [jia, yi],
    'due_date': null,
    'status': 'open',
    'notes': null,
  });
  // Mark 乙's pump and valve quotes as answers to the inquiry.
  for (final r in s.listQuotations(supplierId: yi)) {
    if (r.data['product_id'] != cable) {
      s.save('quotation', {...r.data, 'inquiry_id': inq}, id: r.id);
    }
  }

  final b = s.budget(pro);
  final history = s.priceHistory(
    pump,
    currency: 'CNY',
    taxMode: 'included',
    unit: '台',
  )!;
  final over1000 = s
      .listQuotations(limit: 100)
      .where((h) => double.parse(h.data['price']! as String) > 1000)
      .length;
  // Answers may round: keep at most two decimals of the exact value.
  String plain(String decimal) =>
      RegExp(r'^-?\d+(\.\d{1,2})?').firstMatch(decimal)![0]!;
  return [
    ('库里一共有几家供应商（用阿拉伯数字回答）？', ['3']),
    ('甲泵业的联系人电话是多少？', ['13800001111']),
    ('用拼音 lxsb 能找到什么物料？', ['离心水泵']),
    ('离心水泵有没有定标？成交单价多少？', ['12000']),
    ('乙机电给离心水泵的报价为什么实际比看起来贵？', ['2000']),
    ('丙阀门厂那条离心水泵报价 9000 元能用于预算吗？为什么？', ['口头']),
    ('丙阀门厂的闸阀报价现在还能用吗？', ['过期']),
    ('电缆那条报价为什么不能用于泵房改造项目？', ['起订']),
    ('泵房改造项目的闸阀应该选哪家报价？单价多少？', ['乙', '920']),
    ('泵房改造项目的成本合计是多少？', [plain(b.cost)]),
    ('泵房改造项目的毛利是多少？', [plain(b.margin)]),
    ('泵房改造项目的加价率是多少？', ['15']),
    ('哪个项目的合同金额最高？', ['泵房改造']),
    ('泵房设备询价单里，哪家供应商还没有回复任何报价？', ['甲']),
    ('乙机电设备公司一共给了几条报价（用阿拉伯数字回答）？', ['3']),
    ('单价超过 1000 元的报价有几条（用阿拉伯数字回答）？', ['$over1000']),
    ('离心水泵同口径的历史平均价是多少？', [plain(history.average)]),
    (
      '泵房改造项目预算里有哪些行有预警？',
      [
        for (final l in b.lines)
          if (l.warnings.isNotEmpty)
            (l.data['name'] ??
                    s
                        .get('product', l.data['product_id']! as String)!
                        .data['name'])!
                as String,
      ],
    ),
    ('泵房改造项目需要 2 台离心水泵，算上附加费用，哪家的有效单价最低？', ['甲']),
    ('配电柜更换项目有多少预算行（用阿拉伯数字回答）？', ['0']),
  ];
}
