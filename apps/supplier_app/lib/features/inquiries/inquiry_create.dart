import 'package:flutter/material.dart';
import 'package:supplier_core/supplier_core.dart';

import '../../app/app_state.dart';
import '../../app/format.dart';
import '../../app/theme.dart';

/// Starts an inquiry for some material lines of a project. Returns its id.
Future<String?> showCreateInquiry(
  BuildContext context,
  AppState state,
  String projectId,
) => showDialog<String>(
  context: context,
  builder: (_) => _CreateInquiry(state: state, projectId: projectId),
);

class _CreateInquiry extends StatefulWidget {
  const _CreateInquiry({required this.state, required this.projectId});
  final AppState state;
  final String projectId;

  @override
  State<_CreateInquiry> createState() => _CreateInquiryState();
}

class _CreateInquiryState extends State<_CreateInquiry> {
  Store get store => widget.state.store;
  late final lines = [
    for (final l in store.budget(widget.projectId, withWarnings: false).lines)
      if (l.data['category'] == 'material') l,
  ];
  // Lines without a quotation yet are the usual reason to ask.
  late final picked = {
    for (final l in lines)
      if (l.data['quotation_id'] == null) l.id,
  };
  final suppliers = <String>[];
  late final title = TextEditingController(
    text:
        '${store.get('project', widget.projectId)!.data['name']} 询价 ${localDay(DateTime.now())}',
  );
  String? due, error;

  @override
  void dispose() {
    title.dispose();
    super.dispose();
  }

  String _lineName(Map<String, Object?> d) {
    final p = d['product_id'] == null
        ? null
        : store.get('product', d['product_id']! as String)?.data;
    return [p?['name'] ?? d['name'], p?['model']].whereType<String>().join(' ');
  }

  /// Suppliers that quoted any chosen material before, most quotes first.
  List<Hit> _suggested() {
    final counts = <String, int>{};
    for (final l in lines) {
      final pid = l.data['product_id'] as String?;
      if (!picked.contains(l.id) || pid == null) continue;
      for (final q in store.listQuotations(productId: pid, limit: 200)) {
        final s = q.data['supplier_id']! as String;
        counts[s] = (counts[s] ?? 0) + 1;
      }
    }
    final ids = counts.keys.where((s) => !suppliers.contains(s)).toList()
      ..sort((a, b) => counts[b]!.compareTo(counts[a]!));
    return [
      for (final id in ids.take(8))
        if (store.get('supplier', id) case final r?
            when !r.deleted && r.data['merged_into'] == null)
          Hit(id, r.data, 1),
    ];
  }

  void _create() {
    if (picked.isEmpty) return setState(() => error = '至少选择一行');
    if (suppliers.isEmpty) return setState(() => error = '至少邀请一家供应商');
    late String id;
    final err = widget.state.write(
      (s) => id = s.createInquiry(
        widget.projectId,
        title.text.trim(),
        itemIds: [
          for (final l in lines)
            if (picked.contains(l.id)) l.id,
        ],
        supplierIds: suppliers,
        dueDate: due,
      ),
    );
    if (err != null) return setState(() => error = err);
    Navigator.pop(context, id);
  }

  @override
  Widget build(BuildContext context) {
    final suggested = _suggested();
    return AlertDialog(
      title: const Text('发起询价'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: title,
                decoration: const InputDecoration(labelText: '询价单名称'),
              ),
              const SizedBox(height: 12),
              InkWell(
                onTap: () async {
                  final d = await showDatePicker(
                    context: context,
                    initialDate: DateTime.now().add(const Duration(days: 7)),
                    firstDate: DateTime(2000),
                    lastDate: DateTime(2100),
                  );
                  if (d != null) setState(() => due = localDay(d));
                },
                child: InputDecorator(
                  decoration: const InputDecoration(labelText: '报价截止'),
                  child: Text(due ?? '不限'),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                '询价的行（已选 ${picked.length}/${lines.length}）',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              if (lines.isEmpty)
                const Text('这个项目还没有材料行', style: TextStyle(color: Tokens.ink3)),
              for (final l in lines)
                CheckboxListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: picked.contains(l.id),
                  onChanged: (on) => setState(
                    () => on! ? picked.add(l.id) : picked.remove(l.id),
                  ),
                  title: Text(_lineName(l.data)),
                  subtitle: Text(
                    '${qty(l.data['qty']! as String)} ${l.data['unit']}'
                    '${l.data['quotation_id'] == null ? ' · 还没有报价' : ''}',
                  ),
                ),
              const SizedBox(height: 16),
              const Text(
                '邀请的供应商',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final id in suppliers)
                    InputChip(
                      label: Text(
                        store.get('supplier', id)?.data['name'] as String? ??
                            '',
                      ),
                      onDeleted: () => setState(() => suppliers.remove(id)),
                    ),
                ],
              ),
              Autocomplete<Hit>(
                displayStringForOption: (h) => h.data['name']! as String,
                optionsBuilder: (v) => store
                    .searchByName('supplier', v.text.trim(), limit: 20)
                    .where((h) => !suppliers.contains(h.id)),
                onSelected: (h) => setState(() => suppliers.add(h.id)),
                fieldViewBuilder: (context, controller, focus, submit) =>
                    TextField(
                      controller: controller,
                      focusNode: focus,
                      decoration: const InputDecoration(
                        hintText: '输入名称添加供应商',
                        prefixIcon: Icon(Icons.search, size: 18),
                      ),
                    ),
              ),
              if (suggested.isNotEmpty) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    const Text(
                      '报过这些物料：',
                      style: TextStyle(fontSize: 12, color: Tokens.ink3),
                    ),
                    for (final h in suggested)
                      ActionChip(
                        avatar: const Icon(Icons.add, size: 14),
                        label: Text(h.data['name']! as String),
                        onPressed: () => setState(() => suppliers.add(h.id)),
                      ),
                  ],
                ),
              ],
              if (error != null) ...[
                const SizedBox(height: 10),
                Text(error!, style: const TextStyle(color: Tokens.red)),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _create, child: const Text('创建询价单')),
      ],
    );
  }
}
