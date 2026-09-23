import 'dart:convert';

import 'package:flutter/material.dart';

import '../../app/workspace.dart';

/// Explicit merge or bounded group repair. Every affected head set is compared
/// at commit; refreshing a preview always requires a new confirmation.
class AliasRepairPage extends StatefulWidget {
  const AliasRepairPage({
    super.key,
    required this.workspace,
    required this.type,
    this.initialSource,
    this.initialKeeper,
  });

  final SupplierWorkspace workspace;
  final String type;
  final WorkspaceRecord? initialSource, initialKeeper;

  @override
  State<AliasRepairPage> createState() => _AliasRepairPageState();
}

class _AliasRepairPageState extends State<AliasRepairPage> {
  WorkspaceRecord? _source, _keeper;
  int? _impact;
  bool _busy = false, _confirmed = false, _ready = false;
  String? _error;
  bool _group = false;
  final _additional = <WorkspaceRecord>[];
  Map<String, Object?> _keeperPayload = {};

  @override
  void initState() {
    super.initState();
    _source = widget.initialSource;
    _keeper = widget.initialKeeper;
    _group = _source != null;
    _resetPayload();
  }

  void _resetPayload() {
    _keeperPayload = widget.type == 'supplier'
        ? {
            'name': '',
            'aliases': <String>[],
            'categories': <String>[],
            'address': null,
            'notes': null,
          }
        : {
            'name': '',
            'brand': null,
            'model': null,
            'unit': '',
            'specification': null,
            'category': null,
            'notes': null,
          };
    if (_keeper?.payload['name'] != null) {
      _keeperPayload.addAll(_keeper!.payload);
    }
  }

  Future<void> _add() async {
    final record = await Navigator.of(context).push<WorkspaceRecord>(
      MaterialPageRoute(
        builder: (_) => _RecordPicker(
          workspace: widget.workspace,
          type: widget.type,
          title: '选择异常记录',
          includeInactive: true,
        ),
      ),
    );
    if (!mounted || record == null) return;
    setState(() {
      if (record.id != _source?.id &&
          record.id != _keeper?.id &&
          !_additional.any((r) => r.id == record.id)) {
        _additional.add(record);
      }
      _ready = false;
      _confirmed = false;
    });
  }

  Future<void> _choose(bool source) async {
    final record = await Navigator.of(context).push<WorkspaceRecord>(
      MaterialPageRoute(
        builder: (_) => _RecordPicker(
          workspace: widget.workspace,
          type: widget.type,
          excludedId: source ? _keeper?.id : _source?.id,
          title: source ? '选择来源记录' : '选择保留记录',
          includeInactive: _group,
        ),
      ),
    );
    if (!mounted || record == null) return;
    setState(() {
      if (source) {
        _source = record;
      } else {
        _keeper = record;
        _resetPayload();
      }
      _ready = false;
      _confirmed = false;
      _impact = null;
      _error = null;
    });
  }

  Future<void> _preview() async {
    setState(() {
      _busy = true;
      _ready = false;
      _confirmed = false;
      _error = null;
    });
    try {
      final source = await widget.workspace.read(widget.type, _source!.id);
      final keeper = await widget.workspace.read(widget.type, _keeper!.id);
      if (source.type != widget.type ||
          keeper.type != widget.type ||
          source.id == keeper.id ||
          (!_group &&
              (source.status != 'active' ||
                  keeper.status != 'active' ||
                  source.heads.length != 1 ||
                  keeper.heads.length != 1))) {
        throw const WorkspaceUnavailable('请选择两条同类型、无冲突的有效记录。');
      }
      final impact = await widget.workspace.deletionImpact(
        widget.type,
        source.id,
      );
      final refreshed = <WorkspaceRecord>[];
      for (final record in _additional) {
        refreshed.add(await widget.workspace.read(widget.type, record.id));
      }
      if (!mounted) return;
      setState(() {
        _source = source;
        _keeper = keeper;
        _additional
          ..clear()
          ..addAll(refreshed);
        _impact = impact;
        _ready = true;
      });
    } catch (error) {
      if (mounted) setState(() => _error = '核对未完成：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _merge() async {
    if (!_ready ||
        !_confirmed ||
        _busy ||
        widget.workspace.readOnlyReason != null) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_group) {
        await widget.workspace.repairAliases(
          type: widget.type,
          records: [_source!, _keeper!, ..._additional],
          keeperId: _keeper!.id,
          keeperPayload: Map.of(_keeperPayload),
        );
      } else {
        await widget.workspace.mergeEntities(
          type: widget.type,
          source: _source!,
          target: _keeper!,
          targetPayload: Map<String, Object?>.from(_keeper!.payload),
        );
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = '修复未完成：$error。选择已保留，请重新核对最新内容后确认。';
          _ready = false;
          _confirmed = false;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('关联修复')),
    body: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('将来源记录指向保留记录。保留记录使用下方完整内容，历史记录仍然保留。'),
          const SizedBox(height: 16),
          SwitchListTile(
            title: const Text('修复一组异常关联'),
            subtitle: const Text('可选择重定向、冲突或已删除记录，并明确填写保留记录的完整内容。'),
            value: _group,
            onChanged: _busy
                ? null
                : (value) => setState(() {
                    _group = value;
                    _ready = false;
                    _confirmed = false;
                    _additional.clear();
                  }),
          ),
          for (final source in [true, false]) ...[
            Text(
              source ? '来源记录' : '保留记录',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if ((source ? _source : _keeper) case final record?)
              SelectableText('${record.title}\n${record.id}'),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton(
                onPressed: _busy ? null : () => _choose(source),
                child: Text(source ? '选择来源记录' : '选择保留记录'),
              ),
            ),
            const SizedBox(height: 16),
          ],
          if (widget.workspace.readOnlyReason case final reason?) Text(reason),
          if (_group) ...[
            for (final record in _additional)
              ListTile(
                title: Text(record.title),
                subtitle: Text('${record.id} · ${record.status}'),
                trailing: IconButton(
                  tooltip: '移出修复范围',
                  onPressed: _busy
                      ? null
                      : () => setState(() {
                          _additional.remove(record);
                          _ready = false;
                          _confirmed = false;
                        }),
                  icon: const Icon(Icons.close),
                ),
              ),
            OutlinedButton(
              onPressed: _busy ? null : _add,
              child: const Text('添加异常记录'),
            ),
            const Text('保留记录的完整内容（空白表示清空；别名和分类每行一项）'),
            for (final key in _keeperPayload.keys)
              TextFormField(
                key: ValueKey('${_keeper?.id}-$key'),
                initialValue: _keeperPayload[key] is List
                    ? (_keeperPayload[key] as List).join('\n')
                    : _keeperPayload[key]?.toString() ?? '',
                enabled: !_busy,
                decoration: InputDecoration(
                  labelText:
                      const {
                        'name': '名称',
                        'aliases': '别名',
                        'categories': '供应分类',
                        'address': '地址',
                        'notes': '备注',
                        'brand': '品牌',
                        'model': '型号',
                        'unit': '单位',
                        'specification': '规格',
                        'category': '分类',
                      }[key] ??
                      key,
                ),
                onChanged: (value) => setState(() {
                  _keeperPayload[key] = ['aliases', 'categories'].contains(key)
                      ? value
                            .split('\n')
                            .map((v) => v.trim())
                            .where((v) => v.isNotEmpty)
                            .toList()
                      : value.isEmpty
                      ? null
                      : value;
                  _ready = false;
                  _confirmed = false;
                }),
              ),
          ],
          if (_error != null)
            Semantics(
              liveRegion: true,
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          if (_busy) const LinearProgressIndicator(semanticsLabel: '正在处理关联修复'),
          OutlinedButton(
            onPressed: _busy || _source == null || _keeper == null
                ? null
                : _preview,
            child: const Text('核对最新内容与影响'),
          ),
          if (_ready) ...[
            const SizedBox(height: 20),
            Text('来源记录有 $_impact 条当前引用。修复后通过保留记录解释这些关联，历史快照保持原样。'),
            const SizedBox(height: 12),
            Text('保留记录的完整内容', style: Theme.of(context).textTheme.titleMedium),
            SelectableText(
              const JsonEncoder.withIndent('  ')
                  .convert(_group ? _keeperPayload : _keeper!.payload),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: _confirmed,
              onChanged: _busy
                  ? null
                  : (value) => setState(() => _confirmed = value ?? false),
              title: const Text('我已核对来源、保留记录和完整内容，确认建立关联'),
              controlAffinity: ListTileControlAffinity.leading,
            ),
          ],
          const SizedBox(height: 16),
          FilledButton(
            onPressed:
                _ready &&
                    _confirmed &&
                    !_busy &&
                    widget.workspace.readOnlyReason == null
                ? _merge
                : null,
            child: const Text('确认关联修复'),
          ),
        ],
      ),
    ),
  );
}

class _RecordPicker extends StatefulWidget {
  const _RecordPicker({
    required this.workspace,
    required this.type,
    required this.title,
    this.excludedId,
    this.includeInactive = false,
  });
  final SupplierWorkspace workspace;
  final String type, title;
  final String? excludedId;
  final bool includeInactive;
  @override
  State<_RecordPicker> createState() => _RecordPickerState();
}

class _RecordPickerState extends State<_RecordPicker> {
  final _search = TextEditingController();
  final _records = <WorkspaceRecord>[];
  String? _cursor, _error;
  String _query = '';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load({bool more = false}) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      if (!more) {
        _records.clear();
        _cursor = null;
        _query = _search.text.trim();
      }
    });
    try {
      final page = await widget.workspace.list(
        widget.type,
        search: _query,
        cursor: more ? _cursor : null,
      );
      if (mounted) {
        setState(() {
          _records.addAll(
            page.records.where(
              (r) =>
                  r.type == widget.type &&
                  r.id != widget.excludedId &&
                  (widget.includeInactive || r.status == 'active'),
            ),
          );
          _cursor = page.nextCursor;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = '读取失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.title)),
    body: ListView(
      padding: const EdgeInsets.all(24),
      children: [
        TextField(
          controller: _search,
          enabled: !_busy,
          textInputAction: TextInputAction.search,
          decoration: const InputDecoration(labelText: '搜索记录'),
          onSubmitted: (_) => _load(),
        ),
        OutlinedButton(
          onPressed: _busy ? null : () => _load(),
          child: const Text('搜索'),
        ),
        if (_busy) const LinearProgressIndicator(semanticsLabel: '正在读取记录'),
        if (_error != null) Semantics(liveRegion: true, child: Text(_error!)),
        if (!_busy && _error == null && _records.isEmpty)
          const Text('没有可选择的记录。'),
        for (final record in _records)
          ListTile(
            title: Text(record.title),
            subtitle: Text(
              '${record.subtitle}\n${record.id} · ${record.status}',
            ),
            enabled: !_busy,
            onTap: () => Navigator.of(context).pop(record),
          ),
        if (_cursor != null)
          OutlinedButton(
            onPressed: _busy ? null : () => _load(more: true),
            child: const Text('加载更多'),
          ),
      ],
    ),
  );
}
