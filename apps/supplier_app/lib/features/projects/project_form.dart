import 'package:flutter/material.dart';

import '../../app/motion.dart';
import 'package:supplier_core/supplier_core.dart';

import '../../app/app_state.dart';
import '../../app/format.dart';
import '../../app/theme.dart';
import '../../widgets/deletion.dart';
import '../../widgets/save_keys.dart';

/// Suggests "2026-PC01-007": year, device code, next sequence. Codes are only
/// a label; identity is the record id, so collisions across devices are fine.
String suggestProjectCode(AppState state) {
  final year = DateTime.now().year;
  final device = state.deviceName.toUpperCase().replaceAll(
    RegExp('[^A-Z0-9]'),
    '',
  );
  final prefix =
      '$year-${device.isEmpty ? 'PC' : device.substring(0, device.length.clamp(0, 4))}-';
  var max = 0;
  for (final h in state.store.searchByName('project', prefix, limit: 1000)) {
    final n = int.tryParse(
      (h.data['code']! as String).replaceFirst(prefix, ''),
    );
    if (n != null && n > max) max = n;
  }
  return '$prefix${'${max + 1}'.padLeft(3, '0')}';
}

/// Creates (id == null) or edits a project. Returns the project id.
Future<String?> showProjectForm(
  BuildContext context,
  AppState state, {
  String? id,
}) => showAppDialog<String>(
  context: context,
  builder: (_) => _ProjectForm(state: state, id: id),
);

class _ProjectForm extends StatefulWidget {
  const _ProjectForm({required this.state, this.id});
  final AppState state;
  final String? id;

  @override
  State<_ProjectForm> createState() => _ProjectFormState();
}

class _ProjectFormState extends State<_ProjectForm> {
  late final Map<String, Object?> data;
  final text = <String, TextEditingController>{};
  String? copyFrom;
  String? error;

  static const _textFields = [
    ('code', '项目编号'),
    ('name', '项目名称'),
    ('customer', '客户'),
    ('contract_amount', '合同金额'),
    ('markup_rate', '加价率 %'),
    ('contract_no', '合同号'),
    ('leader', '负责人'),
    ('department', '部门'),
  ];

  @override
  void initState() {
    super.initState();
    final existing = widget.id == null
        ? null
        : widget.state.store.get('project', widget.id!);
    data = {
      for (final f in Project.fields) f: null,
      'status': 'active',
      'currency': 'CNY',
      'tax_mode': 'included',
      'markup_rate': '0',
      'code': suggestProjectCode(widget.state),
      ...?existing?.data,
    };
    for (final (key, _) in _textFields) {
      text[key] = TextEditingController(text: data[key] as String? ?? '');
    }
  }

  @override
  void dispose() {
    for (final c in text.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _save() {
    final payload = {
      ...data,
      for (final e in text.entries)
        e.key: e.value.text.trim().isEmpty ? null : e.value.text.trim(),
    };
    payload['markup_rate'] ??= '0';
    late String id;
    final err = widget.state.write((store) {
      id = widget.id != null
          ? store.save('project', payload, id: widget.id)
          : copyFrom != null
          ? store.copyProject(copyFrom!, payload)
          : store.save('project', payload);
    });
    if (err != null) return setState(() => error = err);
    Navigator.pop(context, id);
  }

  Future<void> _delete() async {
    final sure = await showAppDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除这个项目？'),
        content: const Text(
          '项目和它的成本预算行会从列表中移除，报价记录保留。'
          '删除后可以立即撤销，也可以在 设置 › 已删除的记录 中恢复；'
          '交换文件导入到其他设备后，那里也会删除。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Tokens.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除项目'),
          ),
        ],
      ),
    );
    if (sure != true || !mounted) return;
    final id = widget.id!;
    final name =
        widget.state.store.get('project', id)?.data['name'] as String? ?? '';
    if (deleteWithUndo(
      context,
      widget.state,
      type: 'project',
      id: id,
      name: name,
    )) {
      Navigator.pop(context);
    }
  }

  Widget _dropdown(String key, String label, Map<String?, String> options) =>
      DropdownButtonFormField<String?>(
        isExpanded: true,
        initialValue: data[key] as String?,
        decoration: InputDecoration(labelText: label),
        items: [
          for (final e in options.entries)
            DropdownMenuItem(value: e.key, child: Text(e.value)),
        ],
        onChanged: (v) => setState(() => data[key] = v),
      );

  @override
  Widget build(BuildContext context) {
    final creating = widget.id == null;
    final others = creating
        ? widget.state.store.searchByName('project', '', limit: 200)
        : <Hit>[];
    Widget field(String key, String label) => TextField(
      controller: text[key],
      decoration: InputDecoration(labelText: label),
      autofocus: key == 'name',
      onSubmitted: (_) => _save(),
    );
    Widget fields(List<Widget> children) => LayoutBuilder(
      builder: (context, size) =>
          size.maxWidth < 440 * MediaQuery.textScalerOf(context).scale(1)
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final (i, child) in children.indexed) ...[
                  if (i > 0) const SizedBox(height: 12),
                  child,
                ],
              ],
            )
          : Row(
              children: [
                for (final (i, child) in children.indexed) ...[
                  if (i > 0) const SizedBox(width: 12),
                  Expanded(child: child),
                ],
              ],
            ),
    );
    return SaveKeys(
      onSave: _save,
      child: AlertDialog(
        title: Text(creating ? '新建项目' : '编辑项目'),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final pair in [
                  [('code', '项目编号'), ('name', '项目名称')],
                  [('customer', '客户'), ('contract_no', '合同号')],
                  [('contract_amount', '合同金额'), ('markup_rate', '加价率 %')],
                  [('leader', '负责人'), ('department', '部门')],
                ]) ...[
                  fields([
                    field(pair[0].$1, pair[0].$2),
                    field(pair[1].$1, pair[1].$2),
                  ]),
                  const SizedBox(height: 12),
                ],
                fields([
                  _dropdown('status', '状态', statusLabels),
                  _dropdown('type', '类型', {
                    null: '未指定',
                    'market': '市场订单',
                    'internal': '内部研发',
                  }),
                  _dropdown('level', '级别', {
                    null: '未指定',
                    'A': 'A',
                    'B': 'B',
                    'C': 'C',
                  }),
                ]),
                const SizedBox(height: 12),
                fields([
                  _dropdown('tax_mode', '价格口径', {
                    'included': '含税',
                    'excluded': '不含税',
                  }),
                  _dropdown('currency', '币种', {
                    'CNY': 'CNY 人民币',
                    'USD': 'USD 美元',
                    'EUR': 'EUR 欧元',
                  }),
                ]),
                if (creating && others.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String?>(
                    initialValue: copyFrom,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: '复制已有项目的成本清单（可选）',
                    ),
                    items: [
                      const DropdownMenuItem(
                        value: null,
                        child: Text('不复制，从空白开始'),
                      ),
                      for (final h in others)
                        DropdownMenuItem(
                          value: h.id,
                          child: Text(
                            '${h.data['name']}（${h.data['code']}）',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: (v) => setState(() => copyFrom = v),
                  ),
                ],
                if (error != null) ...[
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(error!, style: TextStyle(color: Tokens.red)),
                  ),
                ],
              ],
            ),
          ),
        ),
        actionsAlignment: MainAxisAlignment.spaceBetween,
        actions: dialogActions(
          onDelete: creating ? null : _delete,
          deleteLabel: '删除项目',
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: _save,
              child: Text(creating ? '创建项目' : '保存'),
            ),
          ],
        ),
      ),
    );
  }
}
