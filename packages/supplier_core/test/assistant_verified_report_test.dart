import 'dart:convert';

import 'package:supplier_core/supplier_core.dart';
import 'package:test/test.dart';

AssistantObservation observation(
  String tool,
  Object result, {
  String arguments = '{}',
  bool provided = true,
}) => AssistantObservation(
  callId: tool,
  tool: tool,
  arguments: arguments,
  result: jsonEncode(result),
  round: 0,
  providedToModel: provided,
);

AssistantAnswer answer(String prose, List<AssistantObservation> observations) =>
    AssistantAnswer.fromRun(
      prose,
      observations,
      modelCalls: 1,
      elapsed: Duration.zero,
    );

void main() {
  test('unqueried fabricated procurement prose is not displayed', () {
    final raw = answer('绝对国产的自造型号FAKE-123，价格999元，完全满足', []);
    final report = raw.verifiedReport();
    expect(report.text, contains('没有取得可核验'));
    expect(report.text, isNot(contains('FAKE-123')));
    expect(report.text, isNot(contains('999')));
    expect(report.text, isNot(contains('完全满足')));
  });

  test('real local facts replace false model prices and unsupported links', () {
    const id = '546aff01-c05c-4e08-ac41-09ffc126235a';
    final raw = answer('[[product:$id|全部已认证]]，价格999元', [
      observation('get', {
        'id': id,
        'name': '真实型号',
        'price': '1200',
      }, arguments: jsonEncode({'type': 'product', 'id': id})),
    ]);
    final report = raw.verifiedReport();
    expect(report.text, contains('真实型号'));
    expect(report.text, contains('1200'));
    expect(report.text, isNot(contains('999')));
    expect(report.text, isNot(contains('全部已认证')));
  });

  test('search snippets do not become certified product or price fields', () {
    final raw = answer('型号FAKE-123可采购', [
      observation('web_search', {
        'sources': [
          {
            'url': 'https://example.com/product',
            'title': '线索',
            'fetched_at': '2026-10-01T00:00:00Z',
            'excerpt': '自造型号FAKE-123价格999',
          },
        ],
      }),
    ]);
    final report = raw.verifiedReport();
    expect(report.text, contains('仅是发现线索'));
    expect(report.text, isNot(contains('FAKE-123')));
    expect(report.sources.single.url, 'https://example.com/product');
  });

  test('failed or undelivered facts cannot enter the fixed report', () {
    final raw = answer('价格999', [
      observation('query', {
        'rows': [
          {'name': '隐藏造假', 'price': '999'},
        ],
      }, provided: false),
      observation('get', {'error': '来源不可用', 'price': '999'}),
    ]);
    expect(raw.verifiedReport().text, isNot(contains('999')));
    expect(raw.verifiedReport().text, isNot(contains('隐藏造假')));
  });

  test(
    'host procurement report is the only procurement narrative consumed',
    () {
      final raw = answer('已经证实全部满足999元', []);
      final report = raw.verifiedReport(
        procurementReport: '来源明确：型号A；价格面议，不能判断。',
      );
      expect(report.text, '来源明确：型号A；价格面议，不能判断。');
      expect(report.text, isNot(contains('已经证实')));
    },
  );

  test('network refusal is reported only from the host tool status', () {
    final raw = answer('实际上已查到FAKE-123价格999', [
      observation('web_search', {'error': '用户拒绝此联网请求，尚未发送'}),
    ]);
    expect(raw.verifiedReport().text, contains('用户拒绝联网请求，未查询网络'));
    expect(raw.verifiedReport().text, isNot(contains('FAKE-123')));
    expect(
      answer('用户拒绝联网请求', []).verifiedReport().text,
      isNot(contains('用户拒绝联网请求')),
    );
  });

  test('plain local queries show the model answer, not tool output', () {
    const id = '546aff01-c05c-4e08-ac41-09ffc126235a';
    final raw = answer('最低价是 1200 元 [[product:$id|真实型号]]', [
      observation('get', {
        'id': id,
        'name': '真实型号',
      }, arguments: jsonEncode({'type': 'product', 'id': id})),
    ]);
    final shown = raw.finalAnswer();
    expect(shown.text, contains('最低价是 1200 元'));
    expect(shown.text, isNot(contains('本机查询结果')));
  });

  test('web runs keep the answer and add the evidence caveat', () {
    final raw = answer('参考资料显示该型号常见', [
      observation('web_search', {'sources': []}),
    ]);
    expect(raw.finalAnswer().text, contains('参考资料显示该型号常见'));
    expect(raw.finalAnswer().text, contains('未经逐字段核验'));
  });

  test('procurement runs still use the application-owned report', () {
    final raw = answer('型号FAKE-123可采购', [
      observation('procurement_check', {'ok': true}),
    ]);
    expect(raw.finalAnswer().text, isNot(contains('FAKE-123')));
  });
}
