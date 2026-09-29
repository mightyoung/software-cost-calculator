import 'package:flutter/material.dart';

import '../../app/motion.dart';
import 'package:supplier_core/supplier_core.dart';

import '../../app/theme.dart';

// Compare complete numeric tokens without losing the original highlight span.
// String canonicalization avoids rounding long amounts through a double.
String? _canonicalNumber(String value) {
  if (!RegExp(r'^[+-]?(?:\d+|\d{1,3}(?:,\d{3})+)(?:\.\d+)?$').hasMatch(value)) {
    return null;
  }
  var number = value.replaceAll(',', '');
  final negative = number.startsWith('-');
  number = number.replaceFirst(RegExp(r'^[+-]'), '');
  final parts = number.split('.');
  final whole = parts.first.replaceFirst(RegExp(r'^0+(?=\d)'), '');
  final fraction = parts.length == 1
      ? ''
      : parts.last.replaceFirst(RegExp(r'0+$'), '');
  final zero = whole == '0' && fraction.isEmpty;
  return '${negative && !zero ? '-' : ''}$whole${fraction.isEmpty ? '' : '.$fraction'}';
}

({int start, int end})? _sourceMatch(
  String source,
  String field,
  String value,
) {
  if (!const {'price', 'qty', 'tax_rate', 'lead_time_days'}.contains(field)) {
    final at = source.indexOf(value);
    return at < 0 ? null : (start: at, end: at + value.length);
  }
  final wanted = _canonicalNumber(value.replaceFirst(RegExp(r'%$'), ''));
  if (wanted == null) return null;
  for (final token in RegExp(
    r'[+-]?\d+(?:[,.]\d+)*(?:[eE][+-]?\d+)?(?:万|千|亿)?',
  ).allMatches(source)) {
    // Do not treat model/identifier digits as a standalone numeric amount.
    if (token.start > 0 &&
        RegExp(r'[A-Za-z0-9_.]').hasMatch(source[token.start - 1])) {
      continue;
    }
    if (token.end < source.length &&
        RegExp(r'[A-Za-z0-9_]').hasMatch(source[token.end])) {
      continue;
    }
    if (_canonicalNumber(token.group(0)!) == wanted) {
      return (start: token.start, end: token.end);
    }
  }
  return null;
}

/// Shows where a recognised value appears in the original text, so the
/// person can check the reading before anything is written.
void showSourceEvidence(
  BuildContext context, {
  required String? original,
  required String sourceName,
  required String field,
  required String value,
}) {
  if (field == 'tax_mode') value = taxModeLabels[value] ?? value;
  final match = original == null ? null : _sourceMatch(original, field, value);
  final at = match?.start ?? -1;
  final matchEnd = match?.end ?? 0;
  // Keep the match visible even in a long workbook or pasted conversation.
  final start = at < 0 || at < 160 ? 0 : at - 160;
  final end = at < 0
      ? (original?.length ?? 0)
      : (matchEnd + 160).clamp(0, original!.length);
  showAppDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('${offerFields[field]!.$1} · 核对原文'),
      content: SizedBox(
        width: 600,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('识别结果：$value'),
              const SizedBox(height: 8),
              Text(sourceName, style: TextStyle(color: Tokens.ink3)),
              const SizedBox(height: 12),
              if (original == null)
                const Text('无法显示这份附件的原文，请返回查看原始文件后核对。')
              else if (at < 0) ...[
                Text(
                  '未找到完全相同的原文，可能经过格式整理或人工修改。请核对以下原文，必要时修改识别结果。',
                  style: TextStyle(color: Tokens.amber),
                ),
                const SizedBox(height: 12),
                SelectableText(original),
              ] else ...[
                Text(
                  '高亮为原文中的匹配内容；仍需核对它是否属于当前报价。',
                  style: TextStyle(color: Tokens.ink2),
                ),
                const SizedBox(height: 12),
                SelectableText.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text:
                            '${start > 0 ? '…' : ''}${original.substring(start, at)}',
                      ),
                      TextSpan(
                        text: original.substring(at, matchEnd),
                        style: TextStyle(
                          backgroundColor: Tokens.amberBg,
                          color: Tokens.ink,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      TextSpan(
                        text:
                            '${original.substring(matchEnd, end)}${end < original.length ? '…' : ''}',
                      ),
                    ],
                  ),
                ),
                if (start > 0 || end < original.length)
                  ExpansionTile(
                    title: const Text('查看完整原文'),
                    children: [SelectableText(original)],
                  ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    ),
  );
}
