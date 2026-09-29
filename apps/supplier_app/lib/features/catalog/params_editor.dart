import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:supplier_core/supplier_core.dart';

import '../../app/theme.dart';
import '../../widgets/ledger.dart';

const _sourceLabels = {
  'manual': '手填',
  'rule': '规则抽取',
  'ai': 'AI 抽取',
  'import': '由关键属性转换',
  'decoder': '型号解码',
};

/// Typed parameter edits of one material, kept until the form is saved.
/// Free-text fields are parsed on the fly; choices are picked directly.
class ParamsDraft {
  ParamsDraft(Store store, String? productId, {this.classCode})
    : original = productId == null ? const {} : store.paramsOf(productId);

  String? classCode;
  final Map<String, Record> original;
  final _texts = <String, TextEditingController>{};

  /// Text each field started with: an untouched field keeps its stored
  /// value (display text does not always read back losslessly).
  final _initial = <String, String>{};
  final _picks = <String, Object?>{};

  /// Set by "全部确认": unchanged unconfirmed values get confirmed on save.
  bool confirmAll = false;

  /// Multi-select fields showing every choice instead of the short list.
  final expanded = <String>{};

  bool get hasUnconfirmed =>
      original.values.any((r) => r.data['confirmed'] != true);

  List<SpecProperty> get properties {
    final codes = [
      if (classCode != null)
        for (final cp in classParams(classCode!)) cp.property,
      // Values outside the template stay visible so they can be cleared.
      for (final code in original.keys) code,
    ];
    return [
      for (final code in {...codes}) ?specProperty(code),
    ];
  }

  Map<String, Object?>? _originalValue(String code) =>
      (original[code]?.data['value'] as Map?)?.cast<String, Object?>();

  TextEditingController text(SpecProperty p) => _texts.putIfAbsent(p.code, () {
    final v = _originalValue(p.code);
    final t = v == null ? '' : formatParamValue(p, v);
    _initial[p.code] = t;
    return TextEditingController(text: t);
  });

  Object? pick(SpecProperty p) => _picks.containsKey(p.code)
      ? _picks[p.code]
      : switch (p.type) {
          ParamType.enumOne => _originalValue(p.code)?['v'],
          ParamType.enumMany => {
            ...((_originalValue(p.code)?['vs'] as List?) ?? const [])
                .cast<String>(),
          },
          ParamType.bool => _originalValue(p.code)?['v'],
          _ => null,
        };

  void setPick(SpecProperty p, Object? value) => _picks[p.code] = value;

  static bool isChoice(SpecProperty p) =>
      p.type == ParamType.enumOne ||
      p.type == ParamType.enumMany ||
      p.type == ParamType.bool;

  /// The value the field now holds: null means empty; throws a Chinese
  /// message when the text cannot be read.
  Map<String, Object?>? valueOf(SpecProperty p) {
    if (isChoice(p)) {
      final v = pick(p);
      return switch (p.type) {
        ParamType.enumOne => v == null ? null : {'v': v},
        ParamType.enumMany =>
          (v as Set<String>).isEmpty ? null : {'vs': v.toList()},
        _ => v == null ? null : {'v': v},
      };
    }
    final t = text(p).text.trim();
    if (t.isEmpty) return null;
    if (t == _initial[p.code]?.trim()) return _originalValue(p.code);
    final parsed = parseParamText(p, t);
    if (parsed == null) throw FormatException('「${p.label}」无法识别：$t');
    try {
      return normalizeParamValue(p, parsed);
    } on FormatException {
      throw FormatException('「${p.label}」无法识别：$t');
    }
  }

  /// First unreadable field, or null.
  String? check() {
    for (final p in properties) {
      try {
        valueOf(p);
      } on FormatException catch (e) {
        return e.message;
      }
    }
    return null;
  }

  /// Writes what changed. Call inside the transaction that saves the
  /// material.
  void apply(Store s, String productId) {
    for (final p in properties) {
      final now = valueOf(p);
      final before = _originalValue(p.code);
      final rec = original[p.code];
      if (now == null) {
        if (before != null) s.clearParam(productId, p.code);
        continue;
      }
      final same = before != null && jsonEncode(before) == jsonEncode(now);
      if (same) {
        if (confirmAll && rec!.data['confirmed'] != true) {
          s.confirmParams(productId, [p.code]);
        }
        continue;
      }
      s.setParam(productId, p.code, now);
    }
  }

  void dispose() {
    for (final c in _texts.values) {
      c.dispose();
    }
  }
}

/// Template picker and the template's parameters, grouped by block.
class ParamsEditor extends StatelessWidget {
  const ParamsEditor({
    super.key,
    required this.draft,
    required this.suggestion,
    required this.onChanged,
  });
  final ParamsDraft draft;

  /// Class guessed from the name and category, offered when not chosen.
  final String? suggestion;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final code = draft.classCode;
    final keys = code == null
        ? const <String>{}
        : {
            for (final cp in classParams(code))
              if (cp.key) cp.property,
          };
    final props = {for (final p in draft.properties) p.code: p};
    final blocks = [
      if (code != null)
        for (final b in classBlocks(code))
          (b.label, [for (final cp in b.params) ?props[cp.property]]),
    ];
    final inBlocks = {for (final b in blocks) ...b.$2.map((p) => p.code)};
    final others = [
      for (final p in props.values)
        if (!inBlocks.contains(p.code)) p,
    ];
    final filled = keys.where((k) {
      try {
        return props[k] != null && draft.valueOf(props[k]!) != null;
      } on FormatException {
        return false;
      }
    }).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text('结构化参数', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(width: 8),
            if (keys.isNotEmpty)
              Text(
                '关键参数 $filled/${keys.length}',
                style: TextStyle(fontSize: 12, color: Tokens.ink3),
              ),
            const Spacer(),
            if (draft.hasUnconfirmed && !draft.confirmAll)
              TextButton(
                onPressed: () {
                  draft.confirmAll = true;
                  onChanged();
                },
                child: const Text('全部确认'),
              ),
          ],
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: DropdownButtonFormField<String?>(
                initialValue: code,
                isExpanded: true,
                decoration: const InputDecoration(labelText: '参数模板'),
                items: [
                  const DropdownMenuItem(value: null, child: Text('不使用模板')),
                  for (final c in specClasses)
                    DropdownMenuItem(
                      value: c.code,
                      child: Text(
                        c.parent == null ? c.label : '　${c.label}',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (v) {
                  draft.classCode = v;
                  onChanged();
                },
              ),
            ),
            if (suggestion != null && suggestion != code) ...[
              const SizedBox(width: 8),
              TextButton(
                onPressed: () {
                  draft.classCode = suggestion;
                  onChanged();
                },
                child: Text('用「${specClass(suggestion!)!.label}」'),
              ),
            ],
          ],
        ),
        if ((code == null ? null : specClass(code)?.help) case final help?)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              help,
              style: TextStyle(fontSize: 12, color: Tokens.ink3),
            ),
          ),
        for (final (label, params) in [
          ...blocks,
          if (others.isNotEmpty) ('其他参数', others),
        ])
          if (params.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.only(top: 14, bottom: 6),
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Tokens.ink2,
                ),
              ),
            ),
            Wrap(
              spacing: 12,
              runSpacing: 10,
              children: [
                for (final p in params)
                  SizedBox(
                    width:
                        p.type == ParamType.enumMany ||
                            p.type == ParamType.ex ||
                            p.type == ParamType.catalog
                        ? double.infinity
                        : 200,
                    child: _field(p, keys.contains(p.code)),
                  ),
              ],
            ),
          ],
      ],
    );
  }

  String? _status(SpecProperty p) {
    final rec = draft.original[p.code];
    if (rec == null || rec.data['confirmed'] == true || draft.confirmAll) {
      return null;
    }
    return '未确认 · ${_sourceLabels[rec.data['source']] ?? rec.data['source']}';
  }

  Widget _field(SpecProperty p, bool key) {
    final label = key ? '${p.label} ·关键' : p.label;
    final status = _status(p);
    switch (p.type) {
      case ParamType.enumOne:
        final current = draft.pick(p) as String?;
        return DropdownButtonFormField<String?>(
          initialValue: current,
          isExpanded: true,
          decoration: InputDecoration(labelText: label, helperText: status),
          items: [
            const DropdownMenuItem(value: null, child: Text('—')),
            for (final v in p.values)
              DropdownMenuItem(value: v.code, child: Text(v.label)),
            if (current != null && p.value(current) == null)
              DropdownMenuItem(value: current, child: Text(current)),
          ],
          onChanged: (v) {
            draft.setPick(p, v);
            onChanged();
          },
        );
      case ParamType.bool:
        return DropdownButtonFormField<bool?>(
          initialValue: draft.pick(p) as bool?,
          decoration: InputDecoration(labelText: label, helperText: status),
          items: const [
            DropdownMenuItem(value: null, child: Text('—')),
            DropdownMenuItem(value: true, child: Text('是')),
            DropdownMenuItem(value: false, child: Text('否')),
          ],
          onChanged: (v) {
            draft.setPick(p, v);
            onChanged();
          },
        );
      case ParamType.enumMany:
        final chosen = draft.pick(p)! as Set<String>;
        // Long lists show the chosen values and the first few others.
        const shortList = 6;
        final all = [
          ...p.values.map((v) => (v.code, v.label)),
          for (final c in chosen)
            if (p.value(c) == null) (c, c),
        ];
        final open =
            draft.expanded.contains(p.code) || all.length <= shortList + 2;
        final shown = open
            ? all
            : [
                ...all.where((v) => chosen.contains(v.$1)),
                ...all.where((v) => !chosen.contains(v.$1)).take(shortList),
              ];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: TextStyle(fontSize: 12, color: Tokens.ink2)),
            const SizedBox(height: 4),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final v in shown)
                  FilterChip(
                    label: Text(v.$2),
                    selected: chosen.contains(v.$1),
                    onSelected: (on) {
                      draft.setPick(p, {
                        ...chosen.where((c) => c != v.$1),
                        if (on) v.$1,
                      });
                      onChanged();
                    },
                  ),
                if (!open)
                  TextButton(
                    onPressed: () {
                      draft.expanded.add(p.code);
                      onChanged();
                    },
                    child: Text('更多 ${all.length - shown.length} 项'),
                  ),
              ],
            ),
            if (status != null) HintTag(status, icon: Icons.help_outline),
          ],
        );
      default:
        final controller = draft.text(p);
        String? preview, problem;
        try {
          final v = draft.valueOf(p);
          if (v != null && formatParamValue(p, v) != controller.text.trim()) {
            preview = '→ ${formatParamValue(p, v)}';
          }
        } on FormatException {
          problem = '无法识别，例如：${paramHint(p)}';
        }
        return TextField(
          controller: controller,
          decoration: InputDecoration(
            labelText: label,
            hintText: paramHint(p),
            helperText: problem == null ? (preview ?? status) : null,
            errorText: problem,
            helperMaxLines: 2,
            errorMaxLines: 2,
          ),
          onChanged: (_) => onChanged(),
        );
    }
  }
}

/// A material's parameters as label → value lines, for detail views.
List<({String label, String value, bool confirmed})> paramLines(
  Store store,
  String productId,
) {
  final params = store.paramsOf(productId);
  final cls = store.get('product', productId)?.data['spec_class'] as String?;
  final order = [
    if (cls != null)
      for (final cp in classParams(cls)) cp.property,
    ...params.keys,
  ];
  return [
    for (final code in {...order})
      if (params[code] case final r?)
        (
          label: specProperty(code)?.label ?? code,
          value: specProperty(code) == null
              ? jsonEncode(r.data['value'])
              : formatParamValue(
                  specProperty(code)!,
                  (r.data['value']! as Map).cast<String, Object?>(),
                ),
          confirmed: r.data['confirmed'] == true,
        ),
  ];
}
