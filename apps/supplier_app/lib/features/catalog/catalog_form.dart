import 'package:flutter/material.dart';

import '../../app/motion.dart';
import 'package:supplier_core/supplier_core.dart';

import '../../widgets/app_icon.dart';
import '../../app/app_state.dart';
import '../../app/theme.dart';
import '../../platform/files.dart';
import 'attributes_editor.dart';
import 'params_editor.dart';
import 'contacts.dart';
import 'duplicate_hints.dart';
import '../../widgets/deletion.dart';
import '../../widgets/save_keys.dart';

typedef _Field = (String key, String label, String? hint);

const _fields = <String, List<_Field>>{
  'supplier': [
    ('name', '供应商名称', null),
    ('aliases', '别名', '多个用逗号分隔，例如 甲泵业, 甲公司'),
    ('categories', '主营类别', '多个用逗号分隔'),
    ('address', '地址', null),
    ('notes', '备注', null),
    ('rating_note', '评价说明', '例如 交货准时、售后响应慢'),
  ],
  'product': [
    ('name', '物料名称', '例如 离心水泵'),
    ('unit', '单位', '台 / 个 / 米 / 项'),
    ('brand', '品牌', null),
    ('model', '型号', '例如 IS80-65-160'),
    ('specification', '规格说明', '例如 流量 100m³/h 扬程 32m 304 不锈钢'),
    ('category', '类别', null),
    ('notes', '备注', null),
  ],
};

const _lists = {'aliases', 'categories'};

/// Form rows: related short fields side by side.
const _layout = {
  'supplier': [
    ['name'],
    ['aliases', 'categories'],
    ['address'],
    ['notes'],
  ],
  'product': [
    ['name', 'unit'],
    ['brand', 'model'],
    ['specification'],
    ['category', 'notes'],
  ],
};

/// Fields whose edits re-run the duplicate check.
const _identity = {
  'supplier': {'name'},
  'product': {'name', 'unit', 'brand', 'model', 'specification', 'category'},
};

/// Suppliers and materials: searchable list plus a create/edit dialog.

Future<String?> showCatalogForm(
  BuildContext context,
  AppState state,
  String type, {
  String? id,
}) => showAppDialog<String>(
  context: context,
  builder: (_) => _CatalogForm(state: state, type: type, id: id),
);

class _CatalogForm extends StatefulWidget {
  const _CatalogForm({required this.state, required this.type, this.id});
  final AppState state;
  final String type;
  final String? id;

  @override
  State<_CatalogForm> createState() => _CatalogFormState();
}

class _CatalogFormState extends State<_CatalogForm> {
  final c = <String, TextEditingController>{};
  final attrs = <AttributeRow>[];

  /// Supplier rating: null (not rated), preferred, caution or disabled.
  String? rating;

  /// Typed parameters of a material, written with it on save.
  late final ParamsDraft params;
  final unitConversions = <AttributeRow>[];
  String? error;
  List<Duplicate> dups = const [];

  Map<String, String> _attrMap() => {
    for (final (k, v) in attrs)
      if (k.text.trim().isNotEmpty) k.text.trim(): v.text.trim(),
  };

  void _addAttr(String? name) => setState(
    () => attrs.add((
      TextEditingController(text: name ?? ''),
      TextEditingController(),
    )),
  );

  String get noun => widget.type == 'product' ? '物料' : '供应商';

  List<Duplicate> _similar() {
    final store = widget.state.store;
    final v = <String, Object?>{
      for (final e in c.entries)
        e.key: e.value.text.trim().isEmpty ? null : e.value.text.trim(),
    };
    if (widget.type == 'product') {
      return store.similarProducts({
        ...v,
        'attributes': _attrMap(),
      }, excludeId: widget.id);
    }
    return v['name'] == null
        ? const []
        : store.similarSuppliers(v['name']! as String, excludeId: widget.id);
  }

  void _open(Duplicate d) {
    final nav = Navigator.of(context);
    nav.pop();
    showCatalogForm(nav.context, widget.state, widget.type, id: d.hit.id);
  }

  Future<void> _merge(Duplicate d) async {
    final ok = await showAppDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('合并到「${duplicateLabel(d.hit.data)}」？'),
        content: Text(
          '当前$noun的报价、联系人和预算行会改为指向它，当前$noun不再单独出现在列表中。'
          '其他设备交换数据后也会同样合并。合并后不能在软件内撤销。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('合并'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final err = widget.state.write(
      (s) => s.mergeInto(widget.type, widget.id!, d.hit.id),
    );
    if (err != null) return setState(() => error = err);
    toast(context, '已合并');
    Navigator.pop(context, d.hit.id);
  }

  /// Creating a record that matches an existing one exactly needs a second
  /// thought: returns false when the user opened the existing one instead.
  Future<bool> _confirmNew() async {
    final same = [
      for (final d in dups)
        if (d.level == Similarity.same) d,
    ];
    if (widget.id != null || same.isEmpty) return true;
    final create = await showAppDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('已有相同的$noun'),
        content: Text(
          '「${duplicateLabel(same.first.hit.data)}」与正在新建的$noun相同。'
          '重复建档会让比价和最低价失真。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('仍然新建'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('打开已有的'),
          ),
        ],
      ),
    );
    if (create == false && mounted) _open(same.first);
    return create == true;
  }

  @override
  void initState() {
    super.initState();
    final data = widget.id == null
        ? null
        : widget.state.store.get(widget.type, widget.id!)?.data;
    for (final (key, _, _) in _fields[widget.type]!) {
      final v = data?[key];
      c[key] = TextEditingController(
        text: v is List ? v.join(', ') : v as String? ?? '',
      );
    }
    rating = data?['rating'] as String?;
    params = ParamsDraft(
      widget.state.store,
      widget.type == 'product' ? widget.id : null,
      classCode: widget.type == 'product'
          ? (data?['spec_class'] as String?)
          : null,
    );
    final a = data?['attributes'];
    if (a is Map) {
      for (final e in a.entries) {
        attrs.add((
          TextEditingController(text: e.key as String),
          TextEditingController(text: e.value as String),
        ));
      }
    }
    final conversions = data?['unit_conversions'];
    if (conversions is Map) {
      for (final e in conversions.entries) {
        unitConversions.add((
          TextEditingController(text: e.key as String),
          TextEditingController(text: e.value as String),
        ));
      }
    }
    dups = _similar();
  }

  @override
  void dispose() {
    params.dispose();
    for (final x in [
      ...c.values,
      for (final (k, v) in attrs) ...[k, v],
      for (final (k, v) in unitConversions) ...[k, v],
    ]) {
      x.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!await _confirmNew() || !mounted) return;
    final existing = widget.id == null
        ? null
        : widget.state.store.get(widget.type, widget.id!)?.data;
    final payload = <String, Object?>{
      // Fields the form does not show (e.g. merged_into) keep their value.
      for (final f in payloadFields(widget.type)) f: existing?[f],
      for (final e in c.entries)
        e.key: _lists.contains(e.key)
            ? e.value.text
                  .split(RegExp('[,，、]'))
                  .map((s) => s.trim())
                  .where((s) => s.isNotEmpty)
                  .toList()
            : (e.value.text.trim().isEmpty ? null : e.value.text.trim()),
    };
    if (widget.type == 'supplier') payload['rating'] = rating;
    if (widget.type == 'product') {
      final missing = [
        for (final (k, v) in attrs)
          if (k.text.trim().isNotEmpty && v.text.trim().isEmpty) k.text.trim(),
      ];
      if (missing.isNotEmpty) {
        return setState(() => error = '关键属性「${missing.first}」还没有填写值');
      }
      payload['attributes'] = _attrMap().isEmpty ? null : _attrMap();
      final units = <String, String>{};
      for (final (source, factor) in unitConversions) {
        final name = source.text.trim();
        final value = factor.text.trim();
        if (name.isEmpty || value.isEmpty) {
          return setState(() => error = '单位换算的来源单位和数量都要填写');
        }
        if (units.containsKey(name)) {
          return setState(() => error = '来源单位「$name」重复');
        }
        units[name] = value;
      }
      payload['unit_conversions'] = units.isEmpty ? null : units;
      final problem = params.check();
      if (problem != null) return setState(() => error = problem);
      payload['spec_class'] = params.classCode;
    }
    late String id;
    final err = widget.state.write(
      (s) => s.transaction(() {
        id = s.save(widget.type, payload, id: widget.id);
        if (widget.type == 'product') params.apply(s, id);
      }),
    );
    if (err != null) return setState(() => error = err);
    Navigator.pop(context, id);
  }

  /// Existing categories to pick from, so one category is not spelled
  /// three ways.
  Widget _categoryChips() {
    final current = c['category']!.text.trim();
    final options = [
      for (final k in widget.state.store.productCategories())
        if (k != current && (current.isEmpty || k.contains(current))) k,
    ];
    if (options.isEmpty) return const SizedBox();
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text('已有类别：', style: TextStyle(fontSize: 12, color: Tokens.ink3)),
          for (final k in options.take(8))
            ActionChip(
              label: Text(k),
              onPressed: () => setState(() {
                c['category']!.text = k;
                dups = _similar();
              }),
            ),
        ],
      ),
    );
  }

  Widget _input(String key) {
    final (_, label, hint) = _fields[widget.type]!.firstWhere(
      (f) => f.$1 == key,
    );
    return TextField(
      controller: c[key],
      autofocus: key == 'name',
      decoration: InputDecoration(labelText: label, hintText: hint),
      onChanged: _identity[widget.type]!.contains(key)
          ? (_) => setState(() => dups = _similar())
          : null,
      onSubmitted: (_) => _save(),
    );
  }

  Future<void> _delete() async {
    final state = widget.state, id = widget.id!;
    final name =
        state.store.get(widget.type, id)?.data['name'] as String? ?? '';
    final ok = await confirmDelete(
      context,
      state,
      type: widget.type,
      id: id,
      name: name,
    );
    if (!ok || !mounted) return;
    if (deleteWithUndo(context, state, type: widget.type, id: id, name: name)) {
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SaveKeys(
      onSave: _save,
      child: AlertDialog(
        title: Text(widget.id == null ? '新建$noun' : '编辑$noun'),
        content: SizedBox(
          width: 460,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final row in _layout[widget.type]!) ...[
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final (i, key) in row.indexed) ...[
                        if (i > 0) const SizedBox(width: 12),
                        Expanded(
                          // The unit is short; the name beside it gets room.
                          flex: key == 'unit' ? 1 : 2,
                          child: _input(key),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 12),
                ],
                if (widget.type == 'product') ...[
                  _categoryChips(),
                  ParamsEditor(
                    draft: params,
                    suggestion: guessSpecClass([
                      c['name']!.text,
                      c['category']!.text,
                    ]),
                    onChanged: () => setState(() {}),
                  ),
                  const SizedBox(height: 16),
                  AttributesEditor(
                    rows: attrs,
                    suggestions: widget.state.store.categoryAttributes(
                      c['category']!.text.trim(),
                    ),
                    onAdd: _addAttr,
                    onRemove: (i) => setState(() {
                      final (k, v) = attrs.removeAt(i);
                      k.dispose();
                      v.dispose();
                      dups = _similar();
                    }),
                    onChanged: () => setState(() => dups = _similar()),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          '报价单位换算',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                      TextButton.icon(
                        onPressed: () => setState(
                          () => unitConversions.add((
                            TextEditingController(),
                            TextEditingController(),
                          )),
                        ),
                        icon: const AppIcon(Icons.add, size: 16),
                        label: const Text('添加单位'),
                      ),
                    ],
                  ),
                  Text(
                    '填写 1 个报价单位等于多少「${c['unit']!.text.trim().isEmpty ? '基准单位' : c['unit']!.text.trim()}」，例如 1 千米 = 1000 米。修改基准单位前请先清空旧换算。',
                    style: TextStyle(fontSize: 12, color: Tokens.ink3),
                  ),
                  for (var i = 0; i < unitConversions.length; i++)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: unitConversions[i].$1,
                              decoration: const InputDecoration(
                                labelText: '报价单位',
                                hintText: '千米',
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: TextField(
                              controller: unitConversions[i].$2,
                              decoration: InputDecoration(
                                labelText:
                                    '等于多少${c['unit']!.text.trim().isEmpty ? '基准单位' : c['unit']!.text.trim()}',
                                hintText: '1000',
                              ),
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                    decimal: true,
                                  ),
                            ),
                          ),
                          IconButton(
                            tooltip: '删除单位换算',
                            icon: const AppIcon(Icons.close, size: 16),
                            onPressed: () => setState(() {
                              final (source, factor) = unitConversions.removeAt(
                                i,
                              );
                              source.dispose();
                              factor.dispose();
                            }),
                          ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 12),
                ],
                if (dups.isNotEmpty) ...[
                  DuplicateHints(
                    duplicates: dups,
                    onMerge: widget.id == null ? null : _merge,
                    onOpen: widget.id == null ? _open : null,
                  ),
                  const SizedBox(height: 12),
                ],
                if (widget.type == 'supplier') ...[
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text('评价', style: TextStyle(color: Tokens.ink2)),
                      for (final e in {'': '未评价', ...supplierRatings}.entries)
                        ChoiceChip(
                          label: Text(e.value),
                          selected: (rating ?? '') == e.key,
                          showCheckmark: false,
                          onSelected: (_) => setState(
                            () => rating = e.key.isEmpty ? null : e.key,
                          ),
                        ),
                    ],
                  ),
                  if (rating == 'disabled')
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        '停用后，这家的报价不再算有效报价，不参与最低价，也不会被自动带入预算。',
                        style: TextStyle(fontSize: 12, color: Tokens.ink3),
                      ),
                    ),
                  const SizedBox(height: 12),
                  _input('rating_note'),
                  const SizedBox(height: 12),
                ],
                if (error != null)
                  Text(error!, style: TextStyle(color: Tokens.red)),
                if (widget.type == 'supplier') ...[
                  const Divider(height: 24),
                  if (widget.id == null)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        '保存后可以添加联系人',
                        style: TextStyle(color: Tokens.ink3),
                      ),
                    )
                  else
                    SupplierContacts(
                      state: widget.state,
                      supplierId: widget.id!,
                    ),
                ],
              ],
            ),
          ),
        ),
        actionsAlignment: MainAxisAlignment.spaceBetween,
        actions: dialogActions(
          onDelete: widget.id == null ? null : _delete,
          deleteLabel: '删除$noun',
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(onPressed: _save, child: const Text('保存')),
          ],
        ),
      ),
    );
  }
}
