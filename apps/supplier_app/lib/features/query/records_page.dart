import 'package:flutter/material.dart';

import '../../app/workspace.dart';
import '../exchange/conflict_resolution.dart';
import '../records/record_editor.dart';

const recordNames = {
  'quotation': '报价',
  'supplier': '供应商',
  'contact': '联系人',
  'product': '产品',
};

class RecordsPage extends StatefulWidget {
  const RecordsPage({super.key, required this.workspace, required this.type});
  final SupplierWorkspace workspace;
  final String type;
  @override
  State<RecordsPage> createState() => _RecordsPageState();
}

class _RecordsPageState extends State<RecordsPage> {
  late String _type = widget.type;
  late Future<WorkspacePage> _page = _load();
  final _search = TextEditingController();
  final _filters = <String, Object?>{};
  final _cursors = <String?>[null];
  String _view = 'history';

  Future<WorkspacePage> _load() => widget.workspace.list(
    _type,
    search: _search.text.trim(),
    filters: {..._filters, if (_type == 'quotation') 'view': _view},
    cursor: _cursors.last,
  );
  void _refresh({bool reset = true}) => setState(() {
    if (reset) {
      _cursors.clear();
      _cursors.add(null);
    }
    _page = _load();
  });
  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _edit([WorkspaceRecord? record]) async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => RecordEditor(
          workspace: widget.workspace,
          type: _type,
          record: record,
        ),
      ),
    );
    if (saved == true && mounted) _refresh();
  }

  Future<void> _detail(WorkspaceRecord record) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) =>
            RecordDetailPage(workspace: widget.workspace, record: record),
      ),
    );
    if (mounted) _refresh();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.all(MediaQuery.sizeOf(context).width < 600 ? 16 : 24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 12,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              _type == 'quotation' ? '查询与比价' : recordNames[_type]!,
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            if (_type != 'quotation')
              OutlinedButton.icon(
                onPressed: widget.workspace.readOnlyReason == null
                    ? () => _edit()
                    : null,
                icon: const Icon(Icons.add),
                label: Text('新增${recordNames[_type]}'),
              ),
            if (widget.type == 'supplier')
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'supplier', label: Text('供应商')),
                  ButtonSegment(value: 'contact', label: Text('联系人')),
                ],
                selected: {_type},
                onSelectionChanged: (values) {
                  _type = values.first;
                  _refresh();
                },
              ),
          ],
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _search,
                decoration: InputDecoration(
                  labelText: '搜索${recordNames[_type]}',
                  prefixIcon: const Icon(Icons.search),
                ),
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => _refresh(),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filledTonal(
              tooltip: '搜索',
              onPressed: () => _refresh(),
              icon: const Icon(Icons.search),
            ),
          ],
        ),
        if (_type == 'quotation') ...[
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final entry in const {
                'history': '全部记录',
                'latest': '每家最新',
                'confirmed_lowest': '有效最低价',
              }.entries)
                ChoiceChip(
                  label: Text(entry.value),
                  selected: _view == entry.key,
                  onSelected: (_) {
                    _view = entry.key;
                    _refresh();
                  },
                ),
              FilterChip(
                label: const Text('历史缺失'),
                selected: _filters['missing_context'] == true,
                onSelected: (value) {
                  if (value) {
                    _filters['missing_context'] = true;
                  } else {
                    _filters.remove('missing_context');
                  }
                  _refresh();
                },
              ),
              ActionChip(
                avatar: const Icon(Icons.tune, size: 18),
                label: const Text('组合筛选'),
                onPressed: _showFilters,
              ),
            ],
          ),
          if (_view != 'history')
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text('按产品、单位、币种、税制、起订量分组；异常或有效期待确认的记录不参与最低价。'),
            ),
        ],
        const SizedBox(height: 16),
        Expanded(
          child: FutureBuilder<WorkspacePage>(
            future: _page,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Center(
                  child: CircularProgressIndicator(semanticsLabel: '正在读取记录'),
                );
              }
              if (snapshot.hasError) {
                return _StateMessage(
                  icon: Icons.error_outline,
                  title: '读取失败',
                  message: '${snapshot.error}',
                  action: '重试',
                  onAction: () => _refresh(reset: false),
                );
              }
              final page = snapshot.requireData;
              if (page.records.isEmpty) {
                return _StateMessage(
                  icon: Icons.search_off,
                  title: '没有符合条件的记录',
                  message: _search.text.isEmpty && _filters.isEmpty
                      ? '新建记录或导入业务 Excel 后即可查询。'
                      : '请调整搜索文字或筛选条件。',
                  action: '清除筛选',
                  onAction: () {
                    _search.clear();
                    _filters.clear();
                    _view = 'history';
                    _refresh();
                  },
                );
              }
              return Column(
                children: [
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, constraints) =>
                          constraints.maxWidth >= 760
                          ? SingleChildScrollView(
                              child: SingleChildScrollView(
                                scrollDirection: Axis.horizontal,
                                child: DataTable(
                                  showCheckboxColumn: false,
                                  columns: [
                                    DataColumn(
                                      label: Text(recordNames[_type]!),
                                    ),
                                    const DataColumn(label: Text('相关信息')),
                                    if (_type == 'quotation')
                                      const DataColumn(
                                        label: Text('金额'),
                                        numeric: true,
                                      ),
                                    const DataColumn(label: Text('状态')),
                                  ],
                                  rows: [
                                    for (final record in page.records)
                                      DataRow(
                                        onSelectChanged: (_) => _detail(record),
                                        cells: [
                                          DataCell(Text(record.title)),
                                          DataCell(
                                            SizedBox(
                                              width: 240,
                                              child: Text(
                                                record.subtitle,
                                                maxLines: 2,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ),
                                          ),
                                          if (_type == 'quotation')
                                            DataCell(
                                              Text(
                                                '${record.payload['currency'] ?? ''} ${record.payload['price'] ?? ''}',
                                              ),
                                            ),
                                          DataCell(Text(_status(record))),
                                        ],
                                      ),
                                  ],
                                ),
                              ),
                            )
                          : ListView.separated(
                              itemCount: page.records.length,
                              separatorBuilder: (_, _) =>
                                  const Divider(height: 1),
                              itemBuilder: (context, index) {
                                final record = page.records[index];
                                return ListTile(
                                  contentPadding: EdgeInsets.zero,
                                  title: Text(record.title),
                                  subtitle: Text(
                                    [
                                      record.subtitle,
                                      if (_type == 'quotation')
                                        '${record.payload['currency'] ?? ''} ${record.payload['price'] ?? ''}',
                                      _status(record),
                                    ].where((s) => s.isNotEmpty).join('\n'),
                                  ),
                                  isThreeLine: _type == 'quotation',
                                  trailing: const Icon(Icons.chevron_right),
                                  onTap: () => _detail(record),
                                );
                              },
                            ),
                    ),
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      IconButton(
                        tooltip: '上一页',
                        onPressed: _cursors.length > 1
                            ? () {
                                _cursors.removeLast();
                                _refresh(reset: false);
                              }
                            : null,
                        icon: const Icon(Icons.chevron_left),
                      ),
                      Text(
                        '第 ${_cursors.length} 页 · 本页 ${page.records.length} 条',
                      ),
                      IconButton(
                        tooltip: '下一页',
                        onPressed: page.nextCursor == null
                            ? null
                            : () {
                                _cursors.add(page.nextCursor);
                                _refresh(reset: false);
                              },
                        icon: const Icon(Icons.chevron_right),
                      ),
                    ],
                  ),
                ],
              );
            },
          ),
        ),
      ],
    ),
  );

  Future<void> _showFilters() async {
    final next = await showDialog<Map<String, Object?>>(
      context: context,
      builder: (_) => _FilterDialog(filters: _filters),
    );
    if (next != null && mounted) {
      _filters.clear();
      _filters.addAll(next);
      _refresh();
    }
  }
}

String _status(WorkspaceRecord record) => record.missingContext.isNotEmpty
    ? '历史资料：存在缺失信息'
    : switch (record.status) {
        'active' => '正常',
        'deleted' => '已删除',
        'conflicted' => '待处理冲突',
        'redirected' => '已合并',
        _ => '关联异常',
      };

class _StateMessage extends StatelessWidget {
  const _StateMessage({
    required this.icon,
    required this.title,
    required this.message,
    required this.action,
    required this.onAction,
  });
  final IconData icon;
  final String title, message, action;
  final VoidCallback onAction;
  @override
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 32),
          const SizedBox(height: 12),
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: 16),
          OutlinedButton(onPressed: onAction, child: Text(action)),
        ],
      ),
    ),
  );
}

class _FilterDialog extends StatefulWidget {
  const _FilterDialog({required this.filters});
  final Map<String, Object?> filters;
  @override
  State<_FilterDialog> createState() => _FilterDialogState();
}

class _FilterDialogState extends State<_FilterDialog> {
  static const labels = {
    'supplier_name': '供应商',
    'contact_name': '联系人',
    'product_name': '产品名称',
    'brand': '品牌',
    'model': '型号',
    'project_name': '项目名称',
    'project_number': '项目编号',
    'inquirer_name': '询价人',
    'inquiry_from': '询价日期起',
    'inquiry_to': '询价日期止',
    'quoted_from': '报价日期起',
    'quoted_to': '报价日期止',
    'price_min': '最低价格',
    'price_max': '最高价格',
  };
  late final _controllers = {
    for (final key in labels.keys)
      key: TextEditingController(text: widget.filters[key]?.toString() ?? ''),
  };
  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('组合筛选'),
    content: SizedBox(
      width: 480,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final entry in labels.entries)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: TextField(
                  controller: _controllers[entry.key],
                  decoration: InputDecoration(
                    labelText: entry.value,
                    hintText:
                        entry.key.contains('_from') || entry.key.contains('_to')
                        ? 'YYYY-MM-DD'
                        : null,
                  ),
                ),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, <String, Object?>{
          if (widget.filters['missing_context'] == true)
            'missing_context': true,
          for (final entry in _controllers.entries)
            if (entry.value.text.trim().isNotEmpty)
              entry.key: entry.value.text.trim(),
        }),
        child: const Text('应用筛选'),
      ),
    ],
  );
}

class RecordDetailPage extends StatefulWidget {
  const RecordDetailPage({
    super.key,
    required this.workspace,
    required this.record,
  });
  final SupplierWorkspace workspace;
  final WorkspaceRecord record;
  @override
  State<RecordDetailPage> createState() => _RecordDetailPageState();
}

class _RecordDetailPageState extends State<RecordDetailPage> {
  late Future<WorkspaceRecord> _record = widget.workspace.read(
    widget.record.type,
    widget.record.id,
  );
  bool _busy = false;
  String? _error;
  Future<void> _edit(WorkspaceRecord record, {bool copy = false}) async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => RecordEditor(
          workspace: widget.workspace,
          type: record.type,
          record: record,
          copy: copy,
        ),
      ),
    );
    if (saved == true && mounted) {
      setState(() => _record = widget.workspace.read(record.type, record.id));
    }
  }

  Future<void> _delete(WorkspaceRecord record) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final affected = await widget.workspace.deletionImpact(
        record.type,
        record.id,
      );
      if (!mounted) return;
      final approved = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('确认删除'),
          content: Text(
            '“${record.title}”涉及 $affected 条关联记录。删除后保留历史，关联异常记录不参与有效比价。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('确认删除'),
            ),
          ],
        ),
      );
      if (approved == true) {
        await widget.workspace.delete(record);
        if (mounted) Navigator.pop(context);
      }
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _contact(WorkspaceRecord record, String method) async {
    try {
      await widget.workspace.contact(record, method);
    } catch (error) {
      if (mounted) setState(() => _error = '无法打开联系动作：$error');
    }
  }

  Future<void> _resolve(WorkspaceRecord record) async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => ConflictResolutionPage(
          workspace: widget.workspace,
          conflict: record,
        ),
      ),
    );
    if (saved == true && mounted) {
      setState(() => _record = widget.workspace.read(record.type, record.id));
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text('${recordNames[widget.record.type]}详情')),
    body: FutureBuilder<WorkspaceRecord>(
      future: _record,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return _StateMessage(
            icon: Icons.error_outline,
            title: '详情读取失败',
            message: '${snapshot.error}',
            action: '重试',
            onAction: () => setState(
              () => _record = widget.workspace.read(
                widget.record.type,
                widget.record.id,
              ),
            ),
          );
        }
        final record = snapshot.requireData;
        final writable =
            widget.workspace.readOnlyReason == null &&
            !_busy &&
            record.status == 'active';
        return ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text(
              record.title,
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            Text(_status(record)),
            if (record.missingContext.isNotEmpty)
              Text(
                '缺失：${record.missingContext.map((key) => fieldLabels[key] ?? key).join('、')}',
              ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton(
                  onPressed: writable ? () => _edit(record) : null,
                  child: const Text('编辑记录'),
                ),
                if (record.heads.length > 1)
                  FilledButton.icon(
                    onPressed: widget.workspace.readOnlyReason == null && !_busy
                        ? () => _resolve(record)
                        : null,
                    icon: const Icon(Icons.merge_type),
                    label: const Text('处理冲突'),
                  ),
                if (record.type == 'quotation')
                  OutlinedButton(
                    onPressed: writable
                        ? () => _edit(record, copy: true)
                        : null,
                    child: const Text('复制为新询价'),
                  ),
                OutlinedButton(
                  onPressed: writable ? () => _delete(record) : null,
                  child: const Text('删除记录'),
                ),
                if (record.type == 'contact')
                  for (final method in ['phone', 'email', 'wechat'])
                    if (record.payload[method] != null)
                      OutlinedButton(
                        onPressed: () => _contact(record, method),
                        child: Text(
                          {
                            'phone': '拨打电话',
                            'email': '发送邮件',
                            'wechat': '复制微信',
                          }[method]!,
                        ),
                      ),
              ],
            ),
            if (_busy) const LinearProgressIndicator(),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Semantics(
                  liveRegion: true,
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              ),
            const SizedBox(height: 20),
            for (final entry in record.payload.entries.where(
              (entry) => ![
                'supplier_id',
                'product_id',
                'contact_id',
                'inquiry_utc_offset_minutes',
                'capture_mode',
              ].contains(entry.key),
            ))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      fieldLabels[entry.key] ?? entry.key,
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                    const SizedBox(height: 4),
                    SelectableText(
                      entry.value == null ? '未填写' : _display(entry.value),
                    ),
                  ],
                ),
              ),
            if (record.comparisonExclusions.isNotEmpty)
              Text(
                '不参与有效最低价：${record.comparisonExclusions.map((reason) => comparisonLabels[reason] ?? '记录待确认').join('、')}',
              ),
            ExpansionTile(
              title: const Text('高级记录信息'),
              children: [
                ListTile(
                  title: const Text('记录 ID'),
                  subtitle: SelectableText(record.id),
                ),
                ListTile(
                  title: const Text('当前修订'),
                  subtitle: SelectableText(record.heads.join('\n')),
                ),
              ],
            ),
          ],
        );
      },
    ),
  );
}

String _display(Object? value) => value is Map
    ? value.entries
          .map((e) => '${fieldLabels[e.key] ?? e.key}：${e.value ?? '未填写'}')
          .join('\n')
    : value is List
    ? value.join('、')
    : value.toString();
const comparisonLabels = {
  'quotation_not_active': '报价状态异常',
  'supplier_not_active': '供应商状态异常',
  'product_not_active': '产品状态异常',
  'tax_unknown': '税制未知',
  'quoted_on_unknown': '报价日期未知',
  'quoted_on_future': '报价日期在未来',
  'validity_pending': '有效期待确认',
  'expired': '报价已过期',
};
