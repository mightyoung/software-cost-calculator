import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:supplier_app/app/errors.dart';

/// Sample values for interpolated reasons (`exceeds $limit codepoints`).
const _samples = {
  'limit': '200',
  'min': '0',
  'max': '600',
  'target': 'supplier',
  'op': 'eq',
  'field': 'price',
};

/// English words allowed in Chinese messages.
const _allowed = {'Excel', 'xlsx', 'YYYY', 'CNY', 'UTC'};

void main() {
  test('every core validation reason reads as Chinese', () {
    final reasons = <String>{};
    final call = RegExp(
      r"""invalid\(\s*(?:[^,()]|\([^()]*\))+?,\s*'((?:[^'\\]|\\.)*)'""",
    );
    for (final file in Directory(
      '../../packages/supplier_core/lib/src',
    ).listSync().whereType<File>()) {
      for (final m in call.allMatches(file.readAsStringSync())) {
        reasons.add(m[1]!);
      }
    }
    expect(reasons.length, greaterThan(100), reason: 'scan found the calls');
    final untranslated = <String>[];
    for (final raw in reasons) {
      final reason = raw
          .replaceAll(RegExp(r'\$\{[^}]*\}'), 'eq')
          .replaceAllMapped(RegExp(r'\$(\w+)'), (m) => _samples[m[1]] ?? 'x');
      final text = friendlyError('price: $reason');
      final english = RegExp(
        r'[A-Za-z]{3,}',
      ).allMatches(text).map((m) => m[0]!).where((w) => !_allowed.contains(w));
      if (english.isNotEmpty) untranslated.add('$raw → $text');
    }
    expect(untranslated, isEmpty);
  });

  test('field names come from the ontology when not listed', () {
    expect(
      friendlyError('unit_conversions: expected at most 50 conversions'),
      '单位换算：最多设置 50 条单位换算',
    );
    expect(
      friendlyError(
        'valid_until: requires quoted_on no later than valid_until',
      ),
      '有效期至：不能早于报价日期',
    );
    expect(
      friendlyError('name: exceeds 200 codepoints'),
      startsWith('名称：不能超过 200 个字'),
    );
    expect(friendlyError('没有冒号的消息'), '没有冒号的消息');
  });
}
