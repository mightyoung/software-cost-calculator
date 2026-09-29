import 'package:flutter/material.dart';

import '../../app/motion.dart';
import 'package:supplier_core/supplier_core.dart';

import '../../widgets/app_icon.dart';
import '../../app/app_state.dart';
import '../../app/format.dart';
import '../../app/theme.dart';
import '../../widgets/ledger.dart';
import '../../widgets/deletion.dart';
import '../trash/trash_page.dart';
import '../../widgets/save_keys.dart';

/// Search the catalogue and pick a material; each hit shows its lowest valid
/// quote in the project's currency and tax mode.
Future<void> showAddItems(
  BuildContext context,
  AppState state,
  String projectId,
) {
  final wide = MediaQuery.sizeOf(context).width >= 720;
  final panel = _AddItems(state: state, projectId: projectId);
  if (!wide) {
    return Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          appBar: AppBar(
            title: const Text('添加物料'),
            backgroundColor: Tokens.canvas,
          ),
          body: panel,
        ),
      ),
    );
  }
  return showGeneralDialog(
    context: context,
    transitionDuration: AppMotion.duration(context, milliseconds: 220),
    transitionBuilder: (_, animation, _, child) => SlideTransition(
      position: Tween(
        begin: const Offset(.04, 0),
        end: Offset.zero,
      ).animate(animation.drive(CurveTween(curve: Curves.easeOutCubic))),
      child: child,
    ),
    barrierDismissible: true,
    barrierLabel: '关闭',
    pageBuilder: (_, _, _) => Align(
      alignment: Alignment.centerRight,
      child: Material(
        color: Tokens.surface,
        child: SizedBox(
          width: 480,
          height: double.infinity,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 8, 8),
                child: Row(
                  children: [
                    Text(
                      '添加物料',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const Spacer(),
                    IconButton(
                      tooltip: '关闭',
                      onPressed: () => Navigator.pop(context),
                      icon: const AppIcon(Icons.close),
                    ),
                  ],
                ),
              ),
              Expanded(child: panel),
            ],
          ),
        ),
      ),
    ),
  );
}

class _AddItems extends StatefulWidget {
  const _AddItems({required this.state, required this.projectId});
  final AppState state;
  final String projectId;

  @override
  State<_AddItems> createState() => _AddItemsState();
}

class _AddItemsState extends State<_AddItems> {
  String query = '';

  @override
  Widget build(BuildContext context) {
    final store = widget.state.store;
    final words = query
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
    final hits = words.isEmpty
        ? store.searchByName('product', '', limit: 50)
        : store.searchProducts(words, limit: 50);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
          child: TextField(
            autofocus: true,
            decoration: const InputDecoration(
              prefixIcon: AppIcon(Icons.search, size: 18),
              hintText: '型号、名称、品牌或规格',
            ),
            onChanged: (v) => setState(() => query = v.trim()),
          ),
        ),
        const Divider(),
        Expanded(
          child: hits.isEmpty
              ? EmptyState(
                  title: words.isEmpty ? '物料库还是空的' : '没有找到"$query"',
                  body: '可以先作为待询价添加，之后再补充物料和报价。',
                )
              : ListView.separated(
                  itemCount: hits.length,
                  separatorBuilder: (_, _) => const Divider(),
                  itemBuilder: (context, i) => _hitTile(hits[i]),
                ),
        ),
        const Divider(),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton(
                onPressed: () => showItemEditor(
                  context,
                  widget.state,
                  widget.projectId,
                  category: 'material',
                  name: query,
                ),
                child: const Text('作为待询价添加'),
              ),
              OutlinedButton(
                onPressed: () => showItemEditor(
                  context,
                  widget.state,
                  widget.projectId,
                  category: 'labor',
                ),
                child: const Text('添加人工、外协等费用'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _hitTile(Hit hit) {
    final options = widget.state.store.quoteOptions(
      widget.projectId,
      hit.id,
      qty: '1',
    );
    final best = options.isNotEmpty && options.first.valid
        ? options.first
        : null;
    final supplier = best == null
        ? null
        : widget.state.store
              .get('supplier', best.data['supplier_id']! as String)
              ?.data['name'];
    final detail = [
      hit.data['brand'],
      hit.data['model'],
      hit.data['specification'],
    ].whereType<String>().join(' · ');
    return ListTile(
      minTileHeight: 56,
      title: Text(hit.data['name']! as String),
      subtitle: detail.isEmpty ? null : MonoText(detail),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            best == null
                ? '无有效报价'
                : '${money(best.price, prefix: '¥')} / ${hit.data['unit']}',
            style: TextStyle(
              fontFeatures: tabular,
              color: best == null ? Tokens.ink3 : Tokens.ink,
            ),
          ),
          if (supplier != null)
            Text(
              '$supplier${best!.validityPending ? ' · 有效期待确认' : ''}',
              style: TextStyle(fontSize: 12, color: Tokens.ink3),
            ),
        ],
      ),
      onTap: () => showItemEditor(
        context,
        widget.state,
        widget.projectId,
        productId: hit.id,
      ),
    );
  }
}

/// Adds (itemId == null) or edits one budget line.
Future<void> showItemEditor(
  BuildContext context,
  AppState state,
  String projectId, {
  String? itemId,
  String? productId,
  String category = 'material',
  String? name,
}) => showAppDialog(
  context: context,
  builder: (_) => _ItemEditor(
    state: state,
    projectId: projectId,
    itemId: itemId,
    productId: productId,
    category: category,
    name: name,
  ),
);

class _ItemEditor extends StatefulWidget {
  const _ItemEditor({
    required this.state,
    required this.projectId,
    this.itemId,
    this.productId,
    required this.category,
    this.name,
  });
  final AppState state;
  final String projectId;
  final String? itemId, productId, name;
  final String category;

  @override
  State<_ItemEditor> createState() => _ItemEditorState();
}

class _ItemEditorState extends State<_ItemEditor> {
  late Map<String, Object?> data;
  late List<QuoteOption> options;
  final c = <String, TextEditingController>{};
  String? error;

  Store get store => widget.state.store;

  @override
  void initState() {
    super.initState();
    final existing = widget.itemId == null
        ? null
        : store.get('project_item', widget.itemId!)?.data;
    final product = widget.productId == null
        ? null
        : store.get('product', widget.productId!)?.data;
    data = existing != null
        ? Map.of(existing)
        : {
            for (final f in ProjectItem.fields) f: null,
            'project_id': widget.projectId,
            'category': widget.category,
            'product_id': widget.productId,
            'name': product == null && (widget.name ?? '').isNotEmpty
                ? widget.name
                : null,
            'qty': '1',
            'unit':
                product?['unit'] ?? (widget.category == 'material' ? '台' : '项'),
            'unit_cost': '0',
          };
    options = _options(data['qty'] as String?);
    if (existing == null && options.isNotEmpty && options.first.valid) {
      data['quotation_id'] = options.first.id;
      data['unit_cost'] = options.first.price;
    }
    for (final k in [
      'name',
      'qty',
      'unit',
      'unit_cost',
      'unit_price',
      'notes',
    ]) {
      c[k] = TextEditingController(text: data[k] as String? ?? '');
    }
  }

  @override
  void dispose() {
    for (final x in c.values) {
      x.dispose();
    }
    super.dispose();
  }

  /// Quotes for this line's product; the minimum order is judged against
  /// [qty] when it is a valid number.
  List<QuoteOption> _options(String? qty) {
    final pid = data['product_id'] as String?;
    return pid == null
        ? const []
        : store.quoteOptions(
            widget.projectId,
            pid,
            unit: data['unit'] as String?,
            qty: tryDecimal(qty?.replaceAll(',', ''), positive: true),
          );
  }

  String _optionState(QuoteOption o) => !o.formal
      ? '口头或参考价，不用于预算'
      : !o.dateValid
      ? '已失效'
      : !o.meetsMinQty
      ? '起订 ${o.data['min_qty']}，数量不足'
      : o.validityPending
      ? '有效期待确认'
      : '有效至 ${o.data['valid_until']}';

  void _save() {
    final payload = {
      ...data,
      for (final e in c.entries)
        e.key: e.value.text.trim().isEmpty
            ? null
            : e.value.text.trim().replaceAll(',', ''),
    };
    if (payload['product_id'] != null) payload['name'] = null;
    payload['unit_cost'] ??= '0';
    final err = widget.state.write(
      (s) => s.save('project_item', payload, id: widget.itemId),
    );
    if (err != null) return setState(() => error = err);
    Navigator.pop(context);
  }

  void _delete() {
    final id = widget.itemId!;
    final name = recordTitle(
      store,
      'project_item',
      store.get('project_item', id)!.data,
    );
    if (deleteWithUndo(
      context,
      widget.state,
      type: 'project_item',
      id: id,
      name: name,
    )) {
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final product = data['product_id'] == null
        ? null
        : store.get('product', data['product_id']! as String)?.data;
    Widget field(
      String key,
      String label, {
      String? hint,
      bool number = false,
      ValueChanged<String>? onChanged,
    }) => TextField(
      controller: c[key],
      decoration: InputDecoration(labelText: label, hintText: hint),
      keyboardType: number
          ? const TextInputType.numberWithOptions(decimal: true)
          : null,
      onChanged: onChanged,
      onSubmitted: (_) => _save(),
    );
    return SaveKeys(
      onSave: _save,
      child: AlertDialog(
        title: Text(widget.itemId == null ? '添加到预算' : '编辑预算行'),
        content: SizedBox(
          width: 460,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (product != null) ...[
                  Text(
                    product['name']! as String,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  MonoText(
                    [
                      product['brand'],
                      product['model'],
                      product['specification'],
                    ].whereType<String>().join(' · '),
                  ),
                  const SizedBox(height: 12),
                ] else ...[
                  DropdownButtonFormField<String>(
                    initialValue: data['category'] as String,
                    decoration: const InputDecoration(labelText: '费用类别'),
                    items: [
                      for (final e in categoryLabels.entries)
                        DropdownMenuItem(
                          value: e.key,
                          child: Text(
                            e.key == 'material' ? '材料费（待询价）' : e.value,
                          ),
                        ),
                    ],
                    onChanged: (v) => setState(() => data['category'] = v),
                  ),
                  const SizedBox(height: 12),
                  field('name', '名称', hint: '例如 电磁流量计 DN100 / 设备安装调试'),
                  const SizedBox(height: 12),
                ],
                Row(
                  children: [
                    Expanded(
                      child: field(
                        'qty',
                        '数量',
                        number: true,
                        onChanged: (v) => setState(() => options = _options(v)),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: field(
                        'unit',
                        '单位',
                        onChanged: (v) => setState(() {
                          data['unit'] = v.trim();
                          data['quotation_id'] = null;
                          options = _options(c['qty']?.text);
                        }),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                if (options.isNotEmpty) ...[
                  DropdownButtonFormField<String?>(
                    key: ValueKey(data['unit']),
                    initialValue: data['quotation_id'] as String?,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: '采用报价'),
                    items: [
                      const DropdownMenuItem(
                        value: null,
                        child: Text('不采用报价，手填估价'),
                      ),
                      for (final o in options)
                        DropdownMenuItem(
                          value: o.id,
                          child: Text(
                            '${money(o.price, prefix: '¥')}${o.converted ? '（按项目口径折算）' : ''} · ${store.get('supplier', o.data['supplier_id']! as String)?.data['name']} · ${_optionState(o)}',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: (v) => setState(() {
                      data['quotation_id'] = v;
                      final o = options.where((o) => o.id == v).firstOrNull;
                      if (o != null) c['unit_cost']!.text = o.price;
                    }),
                  ),
                  const SizedBox(height: 12),
                ],
                Row(
                  children: [
                    Expanded(child: field('unit_cost', '成本单价', number: true)),
                    const SizedBox(width: 12),
                    Expanded(
                      child: field(
                        'unit_price',
                        '对外单价',
                        hint: '留空按加价率计算',
                        number: true,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                field('notes', '备注'),
                if (error != null) ...[
                  const SizedBox(height: 12),
                  Text(error!, style: TextStyle(color: Tokens.red)),
                ],
              ],
            ),
          ),
        ),
        actionsAlignment: MainAxisAlignment.spaceBetween,
        actions: dialogActions(
          onDelete: widget.itemId == null ? null : _delete,
          deleteLabel: '删除这一行',
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
