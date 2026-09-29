import 'package:flutter/material.dart';
import 'package:supplier_core/supplier_core.dart';

import '../../app/app_state.dart';
import '../../app/format.dart';
import '../../app/theme.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/data_grid.dart';
import '../../widgets/ledger.dart';

/// 公司资料: suppliers and quotations colleagues published to the company
/// hub. Read-only here; publishing starts from a supplier or quotation.
class HubPage extends StatefulWidget {
  const HubPage({super.key, required this.state, this.onOpenSettings});
  final AppState state;
  final VoidCallback? onOpenSettings;

  @override
  State<HubPage> createState() => _HubPageState();
}

class _HubPageState extends State<HubPage> {
  final search = TextEditingController();
  var kind = 'quotation';
  List<HubSummary>? rows;
  HubSummary? selected;
  String? error;
  bool loading = false;
  int _request = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final request = ++_request;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final client = await widget.state.hub();
      if (client == null) {
        if (mounted) setState(() => rows = null);
        return;
      }
      final found = await client.search(q: search.text, kind: kind);
      if (!mounted || request != _request) return;
      setState(() {
        rows = found;
        if (!found.any((r) => r.publicationId == selected?.publicationId)) {
          selected = null;
        }
      });
    } on HubException catch (e) {
      if (mounted && request == _request) setState(() => error = e.message);
    } finally {
      if (mounted && request == _request) setState(() => loading = false);
    }
  }

  void _open(HubSummary row, bool wide) {
    if (wide) return setState(() => selected = row);
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          appBar: AppBar(
            backgroundColor: Tokens.canvas,
            title: Text(row.title),
          ),
          body: HubDetail(state: widget.state, row: row),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final configured = widget.state.hubAddress != null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 18, 24, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('公司资料', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 4),
          Text(
            '同事发布到公司资料中心的供应商和历史报价。在供应商或报价的详情里可以发布本机的资料。',
            style: TextStyle(color: Tokens.ink2),
          ),
          const SizedBox(height: 12),
          if (!configured)
            Expanded(
              child: EmptyState(
                title: '还没有连接公司资料中心',
                body: '公司部署了资料中心后，在设置里填写地址和访问令牌即可查询。不连接时本机照常独立工作。',
                actions: [
                  if (widget.onOpenSettings != null)
                    FilledButton(
                      onPressed: widget.onOpenSettings,
                      child: const Text('去设置'),
                    ),
                ],
              ),
            )
          else ...[
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SizedBox(
                  width: 360,
                  child: TextField(
                    controller: search,
                    decoration: const InputDecoration(
                      prefixIcon: AppIcon(Icons.search, size: 18),
                      hintText: '搜索名称、型号或供应商',
                    ),
                    onSubmitted: (_) => _load(),
                  ),
                ),
                for (final (value, label) in [
                  ('quotation', '历史报价'),
                  ('supplier', '供应商'),
                ])
                  ChoiceChip(
                    label: Text(label),
                    selected: kind == value,
                    onSelected: (_) {
                      setState(() {
                        kind = value;
                        selected = null;
                      });
                      _load();
                    },
                  ),
                IconButton(
                  tooltip: '刷新',
                  onPressed: loading ? null : _load,
                  icon: const AppIcon(Icons.refresh, size: 18),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Expanded(child: _body()),
          ],
        ],
      ),
    );
  }

  Widget _body() {
    if (error != null) {
      return EmptyState(
        title: '暂时无法读取公司资料',
        body: error!,
        actions: [OutlinedButton(onPressed: _load, child: const Text('重试'))],
      );
    }
    final list = rows;
    if (list == null) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (list.isEmpty) {
      return EmptyState(
        title: search.text.trim().isEmpty ? '中心还没有共享资料' : '没有找到匹配的资料',
        body: search.text.trim().isEmpty
            ? '在供应商或报价的详情里选择"发布到公司资料"，同事就能在这里查到。'
            : '换个关键词，或切换到${kind == 'quotation' ? '供应商' : '历史报价'}看看。',
      );
    }
    return LayoutBuilder(
      builder: (context, size) {
        final wide = size.maxWidth >= 1000;
        final grid = DataGrid<HubSummary>(
          rows: list,
          id: (r) => '${r.origin}/${r.publicationId}',
          selectedId: selected == null
              ? null
              : '${selected!.origin}/${selected!.publicationId}',
          onOpen: (r) => _open(r, wide),
          columns: kind == 'quotation' ? _quoteColumns : _supplierColumns,
        );
        if (!wide || selected == null) return grid;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: grid),
            const SizedBox(width: 16),
            SizedBox(
              width: 380,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Tokens.surface,
                  border: Border.all(color: Tokens.rule),
                  borderRadius: BorderRadius.circular(Tokens.radius),
                ),
                child: HubDetail(
                  key: ValueKey(selected!.publicationId),
                  state: widget.state,
                  row: selected!,
                  onClose: () => setState(() => selected = null),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  static String? _text(HubSummary r, String key) => r.context[key] as String?;

  static final _quoteColumns = <GridColumn<HubSummary>>[
    GridColumn(
      '物料 / 型号',
      flex: 3,
      value: (r) => r.title,
      cell: (r) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(r.title, overflow: TextOverflow.ellipsis),
          if (_text(r, 'product_model') case final m?) MonoText(m),
        ],
      ),
    ),
    GridColumn('供应商', flex: 2, value: (r) => _text(r, 'supplier_name')),
    GridColumn(
      '单价',
      width: 140,
      numeric: true,
      value: (r) => _text(r, 'price') == null ? null : Num(_text(r, 'price')!),
      cell: (r) => Text(
        '${money(_text(r, 'price'))} ${_text(r, 'currency') ?? ''}',
        textAlign: TextAlign.end,
      ),
    ),
    GridColumn(
      '含税口径',
      width: 96,
      value: (r) => _enum('quotation', 'tax_mode', r.context['tax_mode']),
    ),
    GridColumn('报价日期', width: 110, value: (r) => _text(r, 'quoted_on')),
    GridColumn('来源项目', flex: 2, value: (r) => _text(r, 'project_name')),
    GridColumn(
      '状态',
      width: 96,
      value: (r) => r.withdrawn ? '已撤回' : '第 ${r.revision} 版',
    ),
  ];

  static final _supplierColumns = <GridColumn<HubSummary>>[
    GridColumn('供应商', flex: 3, value: (r) => r.title),
    GridColumn(
      '评价',
      width: 120,
      value: (r) => _enum('supplier', 'rating', r.context['rating']),
    ),
    GridColumn('评价说明', flex: 3, value: (r) => _text(r, 'rating_note')),
    GridColumn(
      '状态',
      width: 96,
      value: (r) => r.withdrawn ? '已撤回' : '第 ${r.revision} 版',
    ),
  ];
}

String? _enum(String type, String field, Object? value) => value == null
    ? null
    : ontology[type]?.field(field)?.values?[value] ?? '$value';

/// One publication: its records as a person reads them, and its revisions.
class HubDetail extends StatefulWidget {
  const HubDetail({
    super.key,
    required this.state,
    required this.row,
    this.onClose,
  });
  final AppState state;
  final HubSummary row;
  final VoidCallback? onClose;

  @override
  State<HubDetail> createState() => _HubDetailState();
}

class _HubDetailState extends State<HubDetail> {
  Map<String, Object?>? publication;
  List<Map<String, Object?>> history = const [];
  String? error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final client = await widget.state.hub();
      if (client == null) throw HubException('还没有连接公司资料中心');
      final r = widget.row;
      final p = await client.publication(r.origin, r.publicationId);
      final h = await client.history(r.origin, r.publicationId);
      if (mounted) {
        setState(() {
          publication = p;
          history = h;
        });
      }
    } on HubException catch (e) {
      if (mounted) setState(() => error = e.message);
    }
  }

  static const _order = [
    'quotation',
    'supplier',
    'contact',
    'product',
    'project',
    'inquiry',
    'project_item',
  ];

  @override
  Widget build(BuildContext context) {
    final p = publication;
    final records =
        [
          for (final r in (p?['records'] as List? ?? const []))
            (r as Map).cast<String, Object?>(),
        ]..sort(
          (a, b) => _order
              .indexOf(a['entity_type']! as String)
              .compareTo(_order.indexOf(b['entity_type']! as String)),
        );
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                widget.row.title,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            if (widget.onClose != null)
              IconButton(
                tooltip: '关闭',
                onPressed: widget.onClose,
                icon: const AppIcon(Icons.close, size: 18),
              ),
          ],
        ),
        Text(
          [
            widget.row.kind == 'supplier' ? '供应商' : '历史报价',
            '第 ${widget.row.revision} 版',
            if (widget.row.withdrawn) '已撤回',
          ].join(' · '),
          style: TextStyle(fontSize: 12, color: Tokens.ink3),
        ),
        const SizedBox(height: 16),
        if (error != null)
          Text(error!, style: TextStyle(color: Tokens.red))
        else if (p == null)
          const LinearProgressIndicator(minHeight: 2)
        else ...[
          for (final r in records) ..._record(r),
          if (history.length > 1) ...[
            const SizedBox(height: 8),
            Text('发布历史', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 6),
            for (final h in history)
              Text(
                '第 ${h['revision']} 版 · ${(h['records'] as List?)?.length ?? 0} 条记录'
                '${h['withdrawn'] == true ? ' · 已撤回' : ''}',
                style: TextStyle(fontSize: 13, color: Tokens.ink2),
              ),
          ],
        ],
      ],
    );
  }

  List<Widget> _record(Map<String, Object?> r) {
    final type = r['entity_type']! as String;
    final data = (r['data'] as Map?)?.cast<String, Object?>() ?? const {};
    final spec = ontology[type];
    final rows = <(String, String)>[
      for (final f in spec?.fields ?? const <FieldSpec>[])
        if (_show(f, data[f.name]) case final v?) (f.label, v),
    ];
    if (rows.isEmpty) return const [];
    return [
      Text(
        spec?.label ?? type,
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 6),
      for (final (label, value) in rows)
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 84,
                child: Text(
                  label,
                  style: TextStyle(fontSize: 13, color: Tokens.ink3),
                ),
              ),
              Expanded(
                child: SelectableText(
                  value,
                  style: const TextStyle(fontSize: 13),
                ),
              ),
            ],
          ),
        ),
      Divider(height: 24, color: Tokens.rule),
    ];
  }

  /// A field as text; references, structures and empty values are left out.
  static String? _show(FieldSpec f, Object? v) {
    if (v == null || v == '' || (v is List && v.isEmpty)) return null;
    return switch (f.kind) {
      Kind.ref || Kind.refList || Kind.object || Kind.instant => null,
      Kind.enumeration => f.values?[v] ?? '$v',
      Kind.boolean => v == true ? '是' : '否',
      Kind.textList => (v as List).join('、'),
      Kind.decimal when f.name == 'price' || f.name.contains('amount') => money(
        '$v',
      ),
      _ => '$v',
    };
  }
}
