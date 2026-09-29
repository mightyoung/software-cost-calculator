import 'package:test/test.dart';

import '../tool/assistant_eval.dart';

void main() {
  const task = EvalCase(
    id: 'grading_control',
    question: '精确报价',
    replies: [],
    observations: [
      ExpectedObservation(
        'query',
        {'type': 'quotation'},
        {'rows.0.price': '999999999999.999999'},
      ),
    ],
    answerContains: ['999999999999.999999'],
  );
  Map<String, Object?> observation({
    String tool = 'query',
    String type = 'quotation',
    Object amount = '999999999999.999999',
    bool failed = false,
  }) => {
    'tool': tool,
    'arguments': {'type': type},
    'result': {
      'rows': [
        {'price': amount},
      ],
    },
    'failed': failed,
  };
  Map<String, Object?> grade({
    List<Map<String, Object?>>? observations,
    String text = '999999999999.999999',
    int unverified = 0,
    bool readOnly = true,
    bool wireMatches = true,
  }) => gradeAssistantCase(
    task,
    text: text,
    observations: observations ?? [observation()],
    unverifiedReferences: unverified,
    readOnly: readOnly,
    wireMatchesEvidence: wireMatches,
  );

  test('positive grading control matches exact tool, arguments and amount', () {
    expect(grade()['pass'], isTrue);
  });

  test(
    'wrong tool, arguments and final precision digit fail independently',
    () {
      for (final (trace, failedCheck) in [
        (observation(tool: 'get'), 'tool_selection'),
        (observation(type: 'supplier'), 'key_arguments'),
        (observation(amount: '999999999999.999998'), 'result_fields'),
        (observation(amount: 1000000000000), 'result_fields'),
        (observation(failed: true), 'result_fields'),
      ]) {
        final result = grade(observations: [trace]);
        expect(result['pass'], isFalse, reason: failedCheck);
        expect((result['checks'] as Map)[failedCheck], isFalse);
      }
    },
  );

  test('final numeric tokens cannot match a different amount prefix', () {
    const budget = EvalCase(
      id: 'budget_text',
      question: '成本',
      replies: [],
      observations: [],
      answerContains: ['总成本 6'],
    );
    for (final text in ['总成本 60', '总成本 6.5', '总成本 6e3', '总成本 6E-3']) {
      final result = gradeAssistantCase(
        budget,
        text: text,
        observations: [],
        unverifiedReferences: 0,
        readOnly: true,
        wireMatchesEvidence: true,
      );
      expect(result['pass'], isFalse);
      expect((result['checks'] as Map)['completion'], isFalse);
    }
    expect(grade(text: '999999999999.9999991')['pass'], isFalse);
    expect(grade(text: '1999999999999.999999')['pass'], isFalse);
  });

  test('signed or exponent final amounts fail despite a correct trace', () {
    for (final text in [
      '-999999999999.999999',
      '+999999999999.999999',
      '−999999999999.999999',
      '999999999999.999999e3',
      '999999999999.999999E3',
      '999999999999.999999e-3',
      '999999999999.999999E+3',
    ]) {
      final result = grade(text: text);
      expect(result['pass'], isFalse, reason: text);
      expect((result['checks'] as Map)['result_fields'], isTrue);
      expect((result['checks'] as Map)['completion'], isFalse);
    }
  });

  test('missing and extra observations fail, not vacuously pass', () {
    expect(grade(observations: [])['pass'], isFalse);
    expect(
      grade(observations: [observation(), observation()])['pass'],
      isFalse,
    );
  });

  test(
    'unsupported links, incomplete answer, writes and wire mismatch fail',
    () {
      for (final result in [
        grade(
          text:
              '999999999999.999999 '
              '[[supplier:00000000-0000-4000-8000-000000000000|假引用]]',
        ),
        grade(unverified: 1),
        grade(text: ''),
        grade(text: '999999999999.999998'),
        grade(readOnly: false),
        grade(wireMatches: false),
      ]) {
        expect(result['pass'], isFalse);
      }
    },
  );

  test('failed flag alone cannot substitute for a model-visible error', () {
    const failureTask = EvalCase(
      id: 'failure',
      question: '失败',
      replies: [],
      observations: [ExpectedObservation('query', {}, {}, failed: true)],
      answerContains: ['失败'],
    );
    for (final result in [
      null,
      {},
      {'error': ''},
    ]) {
      expect(
        gradeAssistantCase(
          failureTask,
          text: '失败',
          observations: [
            {
              'tool': 'query',
              'arguments': {},
              'result': result,
              'failed': true,
            },
          ],
          unverifiedReferences: 0,
          readOnly: true,
          wireMatchesEvidence: true,
        )['pass'],
        isFalse,
      );
    }
  });

  test(
    'all eight synthetic scenarios exercise the complete assistant loop',
    () async {
      final report = await runAssistantEvaluation();
      expect(report['mode'], 'scripted_contract');
      expect(report['replay_only'], isTrue);
      expect(report['live_model_evaluated'], isFalse);
      expect(report['total'], 8);
      expect(report['passed'], 8, reason: '${report['cases']}');
      expect(report['pass'], isTrue);
    },
  );
}
