// Real-API check for the list-to-project flow. The key is read from the
// environment and never written anywhere.
//   DEEPSEEK_API_KEY=sk-... dart run tool/ai_smoke.dart [model]
import 'dart:io';

import 'package:supplier_core/supplier_core.dart';

Future<void> main(List<String> args) async {
  final key = Platform.environment['DEEPSEEK_API_KEY'];
  if (key == null || key.isEmpty) {
    stderr.writeln('请先设置环境变量 DEEPSEEK_API_KEY');
    exitCode = 64;
    return;
  }
  final llm = LlmClient(
    LlmConfig(apiKey: key, model: args.isEmpty ? 'deepseek-flash' : args.first),
  );
  final dir = Directory.systemTemp.createTempSync('ai_smoke');
  final s = Store.open('${dir.path}/a.db', device: 'SMOKE');
  final products = {
    for (final (name, model, spec, unit) in [
      ('离心水泵', 'IS65-50-160', '流量50m³/h 扬程32m 铸铁', '台'),
      ('离心水泵', 'IS80-65-160', '流量100m³/h 扬程32m 不锈钢304', '台'),
      ('闸阀', 'Z41H-16C DN100', 'PN16 碳钢', '个'),
      ('电缆', 'YJV-4x25', '0.6/1kV 铜芯', '米'),
    ])
      model: s.save('product', {
        'name': name,
        'unit': unit,
        'brand': null,
        'model': model,
        'specification': spec,
        'category': null,
        'notes': null,
      }),
  };
  const list = '''
泵房改造询价清单
1. 不锈钢离心泵，Q=100m3/h，H=32m，2台（一用一备）
2. 闸阀 DN100 PN16 ×4
3. 动力电缆 YJV 4*25，约 300m
4. 变频控制柜 1面
合计：略''';
  final sw = Stopwatch()..start();
  final lines = await s.proposeFromList(llm, list);
  stdout.writeln('proposal in ${sw.elapsedMilliseconds} ms');
  final names = {for (final e in products.entries) e.value: e.key};
  for (final l in lines) {
    stdout.writeln(
      '${l.item.name} | ${l.item.qty ?? '-'} ${l.item.unit ?? ''} -> '
      '${names[l.productId] ?? '待询价'} (${l.confidence}) ${l.reason ?? ''}',
    );
  }
  sw.reset();
  final answer = await s.ask(llm, '库里有哪些不锈钢水泵？');
  stdout.writeln('ask in ${sw.elapsedMilliseconds} ms: $answer');
  s.close();
  dir.deleteSync(recursive: true);
}
