import 'dart:io';

import 'package:supplier_core/supplier_core.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

Map<String, Object?> text(String content) => {
  'role': 'assistant',
  'content': content,
};

void main() {
  late Store store;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('assistant_reply');
    store = device('reply');
  });
  tearDown(() {
    store.close();
    tmp.deleteSync(recursive: true);
  });

  test('inline reasoning blocks never reach the answer', () async {
    final model = FakeModel([text('<think>先查表</think>\n共有 0 家供应商。')]);
    final answer = await store.ask(model.client, '有几家供应商？');
    expect(answer, '共有 0 家供应商。');
  });

  test('an empty reply gets one tool-free retry', () async {
    final model = FakeModel([text(''), text('没有找到记录。')]);
    final answer = await store.ask(model.client, '查一下');
    expect(answer, '没有找到记录。');
    expect(model.requests.last.containsKey('tools'), isFalse);
  });

  test('two empty replies fail clearly', () async {
    final model = FakeModel([text(''), text('')]);
    await expectLater(
      store.ask(model.client, '查一下'),
      throwsA(isA<LlmException>()),
    );
  });
}
