import 'package:flutter/material.dart';

import '../../app/motion.dart';
import 'package:supplier_core/supplier_core.dart';

import '../../widgets/app_icon.dart';
import '../../app/app_state.dart';
import '../../app/theme.dart';
import '../../platform/files.dart';
import '../../widgets/ledger.dart';
import '../records/open_record.dart';

Future<void> showParamView(BuildContext context, AppState state) =>
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => ParamViewPage(state: state)),
    );

const _maxRows = 200;

/// 参数视图 (design §9.3, §10.2): the materials of one class against its key
/// parameters. Filters are written like requirements ("IP65" keeps IP65 and
/// better); unconfirmed values can be fixed cell by cell and confirmed per
/// row or column.
class ParamViewPage extends StatefulWidget {
  const ParamViewPage({super.key, required this.state});
  final AppState state;

  @override
  State<ParamViewPage> createState() => _ParamViewPageState();
}

class _ParamViewPageState extends State<ParamViewPage> {
  String classCode = specClasses.first.code;
  final filters = <String, TextEditingController>{};
  var onlyUnconfirmed = false;
  AppState get state => widget.state;

  @override
  void dispose() {
    for (final c in filters.values) {
      c.dispose();
    }
    super.dispose();
  }

  /// Key parameters, plus any other the class's materials actually have.
  List<SpecProperty> _columns(Set<String> present) => [
    for (final cp in classParams(classCode))
      if (cp.key || present.contains(cp.property)) ?specProperty(cp.property),
  ];

  /// The column's filter as a condition, null when empty or unreadable.
  SpecConstraint? _filter(SpecProperty p) {
    final t = filters[p.code]?.text.trim() ?? '';
    if (t.isEmpty || opsFor(p).isEmpty) return null;
    final parsed = parseParamText(p, t);
    if (parsed == null) return null;
    try {
      return SpecConstraint(
        p.code,
        opsFor(p).first,
        normalizeParamValue(p, parsed),
      );
    } on FormatException {
      return null;
    }
  }

  Future<void> _edit(String productId, SpecProperty p, Record? current) async {
    final result = await showAppDialog<Object>(
      context: context,
      builder: (_) => _EditDialog(property: p, current: current),
    );
    if (result == null || !mounted) return;
    final err = state.write((s) {
      if (result == false) {
        s.clearParam(productId, p.code);
      } else {
        s.setParam(
          productId,
          p.code,
          normalizeParamValue(p, result as Map<String, Object?>),
          evidence: current?.data['evidence'] as String?,
        );
      }
    });
    if (err != null && mounted) toast(context, err);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: state,
    builder: (context, _) {
      final store = state.store;
      final all = store.productsOfClass(classCode);
      final paramsOf = {for (final r in all) r.id: store.paramsOf(r.id)};
      final cols = _columns({for (final m in paramsOf.values) ...m.keys});
      final active = {for (final p in cols) p.code: ?_filter(p)};
      final today = localDay(DateTime.now());
      final rows = <(Record, Map<String, Record>)>[];
      for (final r in all) {
        final params = paramsOf[r.id]!;
        if (onlyUnconfirmed &&
            !params.values.any((x) => x.data['confirmed'] != true)) {
          continue;
        }
        final keep = active.entries.every((e) {
          final p = specProperty(e.key)!;
          final have = (params[e.key]?.data['value'] as Map?)
              ?.cast<String, Object?>();
          return evaluateConstraint(p, have, e.value, today: today).satisfied;
        });
        if (keep) rows.add((r, params));
      }
      final shown = rows.take(_maxRows).toList();
      return Scaffold(
        appBar: AppBar(
          backgroundColor: Tokens.canvas,
          title: const Text('参数视图'),
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
          children: [
            Wrap(
              spacing: 12,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SizedBox(
                  width: 260,
                  child: DropdownButtonFormField<String>(
                    initialValue: classCode,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: '类别'),
                    items: [
                      for (final c in specClasses)
                        DropdownMenuItem(
                          value: c.code,
                          child: Text(
                            c.parent == null ? c.label : '　${c.label}',
                          ),
                        ),
                    ],
                    onChanged: (v) => setState(() => classCode = v!),
                  ),
                ),
                FilterChip(
                  label: const Text('只看有未确认参数的'),
                  selected: onlyUnconfirmed,
                  onSelected: (v) => setState(() => onlyUnconfirmed = v),
                ),
                Text(
                  '${rows.length} / ${all.length} 个物料'
                  '${rows.length > _maxRows ? '（显示前 $_maxRows 个）' : ''}',
                  style: TextStyle(color: Tokens.ink2),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              '筛选按技术要求的写法填：防护等级填 IP65 即 IP65 及以上，量程填 -20~80 即覆盖这个范围。缺参数的物料在筛选时不显示。',
              style: TextStyle(fontSize: 12, color: Tokens.ink3),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final p in cols)
                  if (opsFor(p).isNotEmpty)
                    SizedBox(
                      width: 170,
                      child: TextField(
                        controller: filters.putIfAbsent(
                          p.code,
                          TextEditingController.new,
                        ),
                        decoration: InputDecoration(
                          labelText: p.label,
                          hintText:
                              '${opLabels[opsFor(p).first]} ${paramHint(p)}',
                          isDense: true,
                          errorText:
                              (filters[p.code]!.text.trim().isNotEmpty &&
                                  _filter(p) == null)
                              ? '无法识别'
                              : null,
                        ),
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
              ],
            ),
            const SizedBox(height: 16),
            if (all.isEmpty)
              const EmptyState(
                title: '这个类别还没有物料',
                body: '在物料表单里选择参数模板，或在 数据中心 › 数据质量 里从型号和规格文字补全。',
              )
            else
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: _table(shown, cols),
              ),
          ],
        ),
      );
    },
  );

  Widget _table(
    List<(Record, Map<String, Record>)> rows,
    List<SpecProperty> cols,
  ) {
    bool open(Record? r) => r != null && r.data['confirmed'] != true;
    return DataTable(
      headingRowColor: WidgetStatePropertyAll(Tokens.sunken),
      columnSpacing: 20,
      dataRowMaxHeight: 60,
      columns: [
        const DataColumn(label: Text('物料')),
        for (final p in cols)
          DataColumn(
            label: Row(
              children: [
                Text(p.label),
                if (rows.any((r) => open(r.$2[p.code])))
                  IconButton(
                    tooltip: '确认本列未确认的值',
                    icon: const AppIcon(Icons.done_all, size: 16),
                    onPressed: () => state.write((s) {
                      for (final (r, _) in rows) {
                        s.confirmParams(r.id, [p.code]);
                      }
                    }),
                  ),
              ],
            ),
          ),
        const DataColumn(label: Text('')),
      ],
      rows: [
        for (final (r, params) in rows)
          DataRow(
            cells: [
              DataCell(
                Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${r.data['name']}'),
                    if (r.data['model'] case final String m) MonoText(m),
                  ],
                ),
                onTap: () => openRecord(context, state, 'product', r.id),
              ),
              for (final p in cols)
                DataCell(
                  _cell(p, params[p.code]),
                  onTap: () => _edit(r.id, p, params[p.code]),
                ),
              DataCell(
                params.values.any(open)
                    ? TextButton(
                        onPressed: () =>
                            state.write((s) => s.confirmParams(r.id)),
                        child: const Text('确认本行'),
                      )
                    : const SizedBox.shrink(),
              ),
            ],
          ),
      ],
    );
  }

  Widget _cell(SpecProperty p, Record? r) {
    if (r == null) return Text('—', style: TextStyle(color: Tokens.ink3));
    final text = formatParamValue(p, (r.data['value']! as Map).cast());
    if (r.data['confirmed'] == true) return Text(text);
    return Tooltip(
      message: [
        '未确认',
        if (r.data['evidence'] case final String ev) '依据：$ev',
      ].join('\n'),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          border: Border.all(color: Tokens.amber),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(text, style: TextStyle(color: Tokens.amber)),
      ),
    );
  }
}

/// One parameter value: typed as usual, read back live; 清除 returns false.
class _EditDialog extends StatefulWidget {
  const _EditDialog({required this.property, required this.current});
  final SpecProperty property;
  final Record? current;

  @override
  State<_EditDialog> createState() => _EditDialogState();
}

class _EditDialogState extends State<_EditDialog> {
  late final text = TextEditingController(
    text: widget.current == null
        ? ''
        : formatParamValue(
            widget.property,
            (widget.current!.data['value']! as Map).cast(),
          ),
  );

  @override
  void dispose() {
    text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.property;
    final parsed = text.text.trim().isEmpty
        ? null
        : parseParamText(p, text.text);
    return AlertDialog(
      title: Text(p.label),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: text,
              autofocus: true,
              decoration: InputDecoration(
                hintText: paramHint(p),
                helperText: parsed == null
                    ? null
                    : '→ ${formatParamValue(p, parsed)}',
                errorText: text.text.trim().isNotEmpty && parsed == null
                    ? '无法识别，例如：${paramHint(p)}'
                    : null,
              ),
              onChanged: (_) => setState(() {}),
            ),
            if (widget.current?.data['evidence'] case final String ev) ...[
              const SizedBox(height: 8),
              Text(
                '依据：$ev',
                style: TextStyle(fontSize: 12, color: Tokens.ink3),
              ),
            ],
          ],
        ),
      ),
      actions: [
        if (widget.current != null)
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            style: TextButton.styleFrom(foregroundColor: Tokens.red),
            child: const Text('清除'),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: parsed == null
              ? null
              : () => Navigator.pop(context, parsed),
          child: const Text('保存并确认'),
        ),
      ],
    );
  }
}
