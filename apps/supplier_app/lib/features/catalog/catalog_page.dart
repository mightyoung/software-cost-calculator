import 'package:flutter/material.dart';
import 'package:supplier_core/supplier_core.dart';

import '../../app/app_state.dart';
import '../../app/theme.dart';
import '../../widgets/ledger.dart';

typedef _Field = (String key, String label, String? hint);

const _fields = <String, List<_Field>>{
  'supplier': [
    ('name', '供应商名称', null),
    ('aliases', '别名', '多个用逗号分隔，例如 甲泵业, 甲公司'),
    ('categories', '主营类别', '多个用逗号分隔'),
    ('address', '地址', null),
    ('notes', '备注', null),
  ],
  'product': [
    ('name', '物料名称', '例如 离心水泵'),
    ('unit', '单位', '台 / 个 / 米 / 项'),
    ('brand', '品牌', null),
    ('model', '型号', '例如 IS80-65-160'),
    ('specification', '规格参数', '例如 流量 100m³/h 扬程 32m 304 不锈钢'),
    ('category', '类别', null),
    ('notes', '备注', null),
  ],
};

const _lists = {'aliases', 'categories'};

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

  bool get isProduct => widget.type == 'product';
  String get noun => isProduct ? '物料' : '供应商';

  List<Hit> _hits(Store store) {
    final words = query
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
    if (isProduct && words.isNotEmpty) {
      return store.searchProducts(words, limit: 200);
    }
    return store.searchByName(widget.type, query, limit: 200);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.state,
    builder: (context, _) {
      final hits = _hits(widget.state.store);
      return Padding(
        padding: const EdgeInsets.fromLTRB(24, 18, 24, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text(noun, style: Theme.of(context).textTheme.titleLarge),
                const Spacer(),
                FilledButton.icon(
                  onPressed: () =>
                      showCatalogForm(context, widget.state, widget.type),
                  icon: const Icon(Icons.add, size: 18),
                  label: Text('新建$noun'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search, size: 18),
                hintText: isProduct ? '型号、名称、品牌或规格' : '名称或别名',
              ),
              onChanged: (v) => setState(() => query = v.trim()),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: hits.isEmpty
                  ? EmptyState(
                      title: query.isEmpty ? '还没有$noun' : '没有找到"$query"',
                      body: isProduct
                          ? '物料是报价和预算的基础，建立后可在项目中直接选用。'
                          : '记录供应商后，报价和预算会显示对应的供应商。',
                    )
                  : DecoratedBox(
                      decoration: BoxDecoration(
                        color: Tokens.surface,
                        border: Border.all(color: Tokens.rule),
                        borderRadius: BorderRadius.circular(Tokens.radius),
                      ),
                      child: ListView.separated(
                        itemCount: hits.length,
                        separatorBuilder: (_, _) => const Divider(),
                        itemBuilder: (context, i) {
                          final h = hits[i];
                          final sub = isProduct
                              ? [
                                  h.data['brand'],
                                  h.data['model'],
                                  h.data['specification'],
                                ]
                              : [
                                  (h.data['aliases']! as List).join('、'),
                                  h.data['address'],
                                ];
                          final line = sub
                              .whereType<String>()
                              .where((s) => s.isNotEmpty)
                              .join(' · ');
                          return ListTile(
                            minTileHeight: 52,
                            title: Text(h.data['name']! as String),
                            subtitle: line.isEmpty
                                ? null
                                : (isProduct ? MonoText(line) : Text(line)),
                            trailing: isProduct
                                ? Text(
                                    '单位：${h.data['unit']}',
                                    style: const TextStyle(color: Tokens.ink3),
                                  )
                                : null,
                            onTap: () => showCatalogForm(
                              context,
                              widget.state,
                              widget.type,
                              id: h.id,
                            ),
                          );
                        },
                      ),
                    ),
            ),
          ],
        ),
      );
    },
  );
}

Future<String?> showCatalogForm(
  BuildContext context,
  AppState state,
  String type, {
  String? id,
}) => showDialog<String>(
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
  String? error;

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
  }

  @override
  void dispose() {
    for (final x in c.values) {
      x.dispose();
    }
    super.dispose();
  }

  void _save() {
    final payload = <String, Object?>{
      for (final e in c.entries)
        e.key: _lists.contains(e.key)
            ? e.value.text
                  .split(RegExp('[,，、]'))
                  .map((s) => s.trim())
                  .where((s) => s.isNotEmpty)
                  .toList()
            : (e.value.text.trim().isEmpty ? null : e.value.text.trim()),
    };
    late String id;
    final err = widget.state.write(
      (s) => id = s.save(widget.type, payload, id: widget.id),
    );
    if (err != null) return setState(() => error = err);
    Navigator.pop(context, id);
  }

  void _delete() {
    widget.state.write((s) => s.delete(widget.type, widget.id!));
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final noun = widget.type == 'product' ? '物料' : '供应商';
    return AlertDialog(
      title: Text(widget.id == null ? '新建$noun' : '编辑$noun'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final (key, label, hint) in _fields[widget.type]!) ...[
                TextField(
                  controller: c[key],
                  autofocus: key == 'name',
                  decoration: InputDecoration(labelText: label, hintText: hint),
                  onSubmitted: (_) => _save(),
                ),
                const SizedBox(height: 12),
              ],
              if (error != null)
                Text(error!, style: const TextStyle(color: Tokens.red)),
            ],
          ),
        ),
      ),
      actions: [
        if (widget.id != null)
          TextButton(
            onPressed: _delete,
            style: TextButton.styleFrom(foregroundColor: Tokens.red),
            child: Text('删除$noun'),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _save, child: const Text('保存')),
      ],
    );
  }
}
