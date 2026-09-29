import 'package:flutter/material.dart';

import '../../app/motion.dart';
import 'package:supplier_core/supplier_core.dart';

import '../../widgets/app_icon.dart';
import '../../widgets/material_icon.dart';
import '../../app/app_state.dart';
import '../../app/theme.dart';
import '../../widgets/ledger.dart';
import '../../platform/files.dart';
import 'attributes_editor.dart';
import 'catalog_import.dart';
import 'params_editor.dart';
import '../spec/param_view.dart';
import '../spec/spec_match_page.dart';
import 'contacts.dart';
import 'detail_panel.dart';
import 'duplicate_hints.dart';
import '../../widgets/data_grid.dart';
import '../../widgets/deletion.dart';
import '../../app/format.dart';
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
class CatalogPage extends StatefulWidget {
  const CatalogPage({super.key, required this.state, required this.type});
  final AppState state;
  final String type;

  @override
  State<CatalogPage> createState() => _CatalogPageState();
}

class _CatalogPageState extends State<CatalogPage> {
  String query = '';
  String? category;

  /// Record shown in the side panel.
  String? selected;

  void _open(String id) {
    if (MediaQuery.sizeOf(context).width >= 1100) {
      setState(() => selected = id);
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          appBar: AppBar(backgroundColor: Tokens.surface, title: Text(noun)),
          body: CatalogDetail(state: widget.state, type: widget.type, id: id),
        ),
      ),
    );
  }

  bool get isProduct => widget.type == 'product';
  String get noun => isProduct ? '物料' : '供应商';

  /// Ids matching the search box, or null when it is empty.
  Set<String>? _hits(Store store) {
    final words = query
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
    if (words.isEmpty) return null;
    return {
      for (final h
          in isProduct
              ? store.searchProducts(words, limit: 1 << 20)
              : store.searchByName(widget.type, query, limit: 1 << 20))
        h.id,
    };
  }

  Future<void> _export<T>(List<GridColumn<T>> columns, List<T> rows) async {
    final saved = await saveBytes(
      '$noun-${today()}.xlsx',
      gridToXlsx(noun, columns, rows),
      extensions: ['xlsx'],
    );
    if (saved && mounted) toast(context, '已导出 ${rows.length} 个$noun');
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.state,
    builder: (context, _) {
      final store = widget.state.store;
      final hits = _hits(store);
      return Padding(
        padding: const EdgeInsets.fromLTRB(24, 18, 24, 16),
        child: isProduct ? _products(store, hits) : _suppliers(store, hits),
      );
    },
  );

  /// Columns hidden while the side panel narrows the table.
  static const _secondary = {'类别', '规格', '中标', '项目', '供应商'};

  Widget _page<T>({
    required List<T> rows,
    required List<GridColumn<T>> columns,
    required String Function(T) id,
    required String Function(T) name,
    Widget? filters,
  }) {
    final total = widget.state.store.recordCounts()[widget.type]!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(noun, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(width: 10),
            Text(
              query.isEmpty && category == null
                  ? '共 $total 个'
                  : '找到 ${rows.length} 个',
              style: TextStyle(color: Tokens.ink3),
            ),
            if (isProduct) ...[
              OutlinedButton.icon(
                onPressed: () => showParamView(context, widget.state),
                icon: const AppIcon(Icons.table_rows_outlined, size: 18),
                label: const Text('物料参数表'),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: () => showSpecMatch(context, widget.state),
                icon: const AppIcon(Icons.rule, size: 18),
                label: const Text('按要求找物料'),
              ),
              const SizedBox(width: 8),
            ],
            OutlinedButton.icon(
              onPressed: () =>
                  importCatalogList(context, widget.state, widget.type),
              icon: const AppIcon(Icons.file_upload_outlined, size: 18),
              label: const Text('导入'),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: rows.isEmpty ? null : () => _export(columns, rows),
              icon: const AppIcon(Icons.file_download_outlined, size: 18),
              label: const Text('导出'),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              onPressed: () =>
                  showCatalogForm(context, widget.state, widget.type),
              icon: const AppIcon(Icons.add, size: 18),
              label: Text('新建$noun'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        LayoutBuilder(
          builder: (context, size) => Wrap(
            spacing: 10,
            runSpacing: 8,
            children: [
              SizedBox(
                width: filters != null && size.maxWidth >= 600
                    ? size.maxWidth - 250
                    : size.maxWidth,
                child: TextField(
                  decoration: InputDecoration(
                    prefixIcon: const AppIcon(Icons.search, size: 18),
                    hintText: isProduct ? '型号、名称、品牌、规格或拼音首字母' : '名称、别名或拼音首字母',
                  ),
                  onChanged: (v) => setState(() => query = v.trim()),
                ),
              ),
              if (filters != null)
                SizedBox(
                  width: size.maxWidth < 600 ? size.maxWidth : 240,
                  child: filters,
                ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: _table(
                  rows,
                  selected == null
                      ? columns
                      : [
                          for (final c in columns)
                            if (!_secondary.contains(c.label)) c,
                        ],
                  id,
                ),
              ),
              if (selected != null &&
                  MediaQuery.sizeOf(context).width >= 1100) ...[
                const SizedBox(width: 12),
                Container(
                  width: 420,
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    border: Border.all(color: Tokens.rule),
                    borderRadius: BorderRadius.circular(Tokens.radius),
                  ),
                  child: CatalogDetail(
                    key: ValueKey(selected),
                    state: widget.state,
                    type: widget.type,
                    id: selected!,
                    onClose: () => setState(() => selected = null),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _table<T>(
    List<T> rows,
    List<GridColumn<T>> columns,
    String Function(T) id,
  ) {
    return SizedBox(
      child: rows.isEmpty
          ? EmptyState(
              title: query.isEmpty && category == null
                  ? '还没有$noun'
                  : '没有找到符合条件的$noun',
              body: isProduct
                  ? '物料是报价和预算的基础，建立后可在项目中直接选用。'
                  : '记录供应商后，报价和预算会显示对应的供应商。',
            )
          : DataGrid<T>(
              rows: rows,
              columns: columns,
              id: id,
              onOpen: (r) => _open(id(r)),
              selectedId: selected,
              bulkActions: (picked, clear) => [
                TextButton.icon(
                  onPressed: () => _export(columns, picked),
                  icon: const AppIcon(Icons.file_download_outlined, size: 18),
                  label: const Text('导出选中'),
                ),
                TextButton.icon(
                  style: TextButton.styleFrom(foregroundColor: Tokens.red),
                  onPressed: () async {
                    await deleteManyWithUndo(
                      context,
                      widget.state,
                      type: widget.type,
                      ids: picked.map(id).toList(),
                    );
                    clear();
                  },
                  icon: const AppIcon(Icons.delete_outline, size: 18),
                  label: const Text('删除'),
                ),
              ],
            ),
    );
  }

  Widget _suppliers(Store store, Set<String>? hits) => _page<SupplierRow>(
    rows: store.supplierRows(only: hits),
    id: (r) => r.id,
    name: (r) => r.data['name']! as String,
    columns: [
      GridColumn(
        '名称',
        flex: 3,
        value: (r) => r.data['name'] as String?,
        cell: (r) => Row(
          children: [
            Flexible(
              child: _twoLines(
                r.data['name']! as String,
                (r.data['aliases']! as List).join('、'),
              ),
            ),
            if (ratingTag(r.data['rating']) case final tag?) ...[
              const SizedBox(width: 8),
              tag,
            ],
          ],
        ),
      ),
      GridColumn(
        '类别',
        flex: 2,
        value: (r) => (r.data['categories']! as List).join('、'),
      ),
      GridColumn(
        '联系人',
        flex: 2,
        value: (r) => r.contactName,
        cell: (r) => _twoLines(
          r.contactName ?? '—',
          [
            r.contactPhone,
            if (r.contacts > 1) '共 ${r.contacts} 人',
          ].whereType<String>().join(' · '),
        ),
      ),
      GridColumn('报价', width: 72, numeric: true, value: (r) => r.quotes),
      GridColumn('中标', width: 72, numeric: true, value: (r) => r.awards),
      GridColumn('项目', width: 72, numeric: true, value: (r) => r.projects),
      GridColumn('最近报价', width: 110, value: (r) => r.lastQuotedOn),
    ],
  );

  Widget _products(Store store, Set<String>? hits) {
    final categories = store.productCategories();
    final rows = [
      for (final r in store.productRows(only: hits))
        if (category == null || r.data['category'] == category) r,
    ];
    return _page<ProductRow>(
      rows: rows,
      id: (r) => r.id,
      name: (r) => r.data['name']! as String,
      filters: categories.isEmpty
          ? null
          : DropdownButton<String?>(
              isExpanded: true,
              value: category,
              hint: const Text('全部类别'),
              items: [
                const DropdownMenuItem(value: null, child: Text('全部类别')),
                for (final c in categories)
                  DropdownMenuItem(value: c, child: Text(c)),
              ],
              onChanged: (c) => setState(() => category = c),
            ),
      columns: [
        GridColumn(
          '名称 / 型号',
          flex: 3,
          value: (r) => r.data['name'] as String?,
          cell: (r) => Row(
            children: [
              MaterialIcon(
                category: r.data['category'] as String?,
                name: r.data['name'] as String?,
                color: Tokens.ink2,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _twoLines(
                  r.data['name']! as String,
                  [
                    r.data['brand'],
                    r.data['model'],
                  ].whereType<String>().join(' · '),
                  mono: true,
                ),
              ),
            ],
          ),
        ),
        GridColumn(
          '规格',
          flex: 3,
          value: (r) => r.data['specification'] as String?,
        ),
        GridColumn('类别', flex: 1, value: (r) => r.data['category'] as String?),
        GridColumn('单位', width: 56, value: (r) => r.data['unit'] as String?),
        GridColumn(
          '最近报价',
          width: 150,
          numeric: true,
          value: (r) => switch (r.lastQuote?['price']) {
            final String p => Num(p),
            _ => null,
          },
          cell: (r) {
            final q = r.lastQuote;
            if (q == null) {
              return Text('—', style: TextStyle(color: Tokens.ink3));
            }
            return _twoLines(
              '${money(q['price'] as String?, prefix: q['currency'] == 'CNY' ? '¥' : '${q['currency']} ')} / ${q['unit_snapshot']}',
              q['quoted_on'] as String? ?? '',
              end: true,
            );
          },
        ),
        GridColumn('报价', width: 64, numeric: true, value: (r) => r.quotes),
        GridColumn('供应商', width: 72, numeric: true, value: (r) => r.suppliers),
        GridColumn('项目', width: 64, numeric: true, value: (r) => r.projects),
      ],
    );
  }
}

/// A main line with a quieter second line (skipped when empty).
Widget _twoLines(
  String main,
  String sub, {
  bool mono = false,
  bool end = false,
}) => Column(
  mainAxisSize: MainAxisSize.min,
  crossAxisAlignment: end ? CrossAxisAlignment.end : CrossAxisAlignment.start,
  children: [
    Text(
      main,
      overflow: TextOverflow.ellipsis,
      style: end ? const TextStyle(fontFeatures: tabular) : null,
    ),
    if (sub.isNotEmpty)
      mono
          ? MonoText(sub)
          : Text(
              sub,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: Tokens.ink3),
            ),
  ],
);

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
