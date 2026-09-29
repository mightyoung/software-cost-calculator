import 'package:flutter/material.dart';

import 'package:supplier_core/supplier_core.dart';

import '../../widgets/app_icon.dart';
import '../../widgets/material_icon.dart';
import '../../app/app_state.dart';
import '../../app/theme.dart';
import '../../widgets/ledger.dart';
import '../../platform/files.dart';
import 'catalog_import.dart';
import '../spec/param_view.dart';
import '../spec/spec_match_page.dart';
import 'detail_panel.dart';
import '../../widgets/data_grid.dart';
import '../../widgets/deletion.dart';
import '../../app/format.dart';
import 'catalog_form.dart';

export 'catalog_form.dart' show showCatalogForm;

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
