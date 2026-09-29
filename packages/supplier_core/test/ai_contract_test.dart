import 'dart:io';

import 'package:supplier_core/supplier_core.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

void main() {
  setUp(() => tmp = Directory.systemTemp.createTempSync('ai_contract'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('AI cannot reverse a deterministic minimum requirement', () {
    const clause = SpecClause(1, '显存不小于2GB');
    expect(
      verifyAiConstraint('computer.ipc', clause, {
        'property': 'gpu.mem',
        'op': 'le',
        'value': '2GB',
        'evidence': clause.text,
      }),
      isNull,
    );
  });

  test(
    'malformed offers are an AI protocol failure, not an empty import',
    () async {
      final s = device('A');
      addTearDown(s.close);
      final model = FakeModel([
        jsonReply({'offers': 'wrong'}),
        jsonReply({'offers': 'wrong'}),
      ]);
      await expectLater(
        s.extractOffers(model.client, '报价信息'),
        throwsA(isA<LlmException>()),
      );
    },
  );

  test('malformed items are not silently dropped', () async {
    final s = device('A');
    addTearDown(s.close);
    final model = FakeModel([
      jsonReply({
        'items': [42],
      }),
      jsonReply({
        'items': [42],
      }),
    ]);
    await expectLater(
      s.proposeFromList(model.client, '水泵2台'),
      throwsA(isA<LlmException>()),
    );
  });

  test('a single long line is bounded without changing source text', () {
    final source = '泵' * 16000;
    final chunks = chunkText(source).toList();
    expect(chunks.every((c) => c.length <= 6000), isTrue);
    expect(chunks.join(), source);
  });
}
