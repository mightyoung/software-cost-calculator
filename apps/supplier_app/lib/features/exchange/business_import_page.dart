import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:supplier_core/supplier_core.dart';

import '../../platform/business_import_workflow_adapter.dart';
import '../../platform/import_cancellation.dart';

const businessFieldLabels = <String, String>{
  'record_id': '原报价编号',
  'export_revision_id': '导出修订编号',
  'supplier_id': '供应商编号',
  'supplier_name': '供应商名称',
  'product_id': '产品编号',
  'product_name': '产品名称',
  'product_brand': '品牌',
  'product_model': '型号',
  'product_specification': '规格',
  'price': '单价',
  'unit_snapshot': '报价单位',
  'currency': '币种',
  'min_qty': '起订量',
  'tax_mode': '税制',
  'tax_rate': '税率',
  'quoted_on': '报价日期',
  'valid_until': '有效期',
  'lead_time_days': '交期天数',
  'project_name': '项目名称',
  'project_number': '项目编号',
  'inquirer_name': '询价人',
  'inquiry_location': '询价地点',
  'inquiry_time': '询价日期或时刻',
  'inquiry_precision': '询价精度',
  'inquiry_date': '询价日期',
  'inquired_at': '询价时刻（含时区）',
  'inquiry_utc_offset_minutes': '询价时区偏移分钟',
  'contact_id': '联系人编号',
  'contact_snapshot': '联系人快照',
  'notes': '备注',
  'capture_mode': '资料模式',
};

class BusinessImportPage extends StatefulWidget {
  const BusinessImportPage({super.key, required this.adapter});
  final BusinessImportWorkflowAdapter adapter;
  @override
  State<BusinessImportPage> createState() => _BusinessImportPageState();
}

class _BusinessImportPageState extends State<BusinessImportPage> {
  final _path = TextEditingController(),
      _resume = TextEditingController(),
      _header = TextEditingController(text: '1'),
      _offset = TextEditingController();
  final _defaults = <String, TextEditingController>{
    for (final key in [
      'unit_snapshot',
      'currency',
      'tax_mode',
      'min_qty',
      'project_name',
      'project_number',
      'inquirer_name',
      'quoted_on',
      'inquiry_date',
    ])
      key: TextEditingController(),
  };
  BusinessImportSelection? _selection;
  String? _sheet, _message;
  bool _busy = false, _failed = false, _done = false;
  ImportCancellation? _parsing;
  CaptureMode _mode = CaptureMode.standard;
  BusinessImportSession? _session;
  List<StagedXlsxCell> _headers = [];
  final _columns = <String, int?>{};
  List<BusinessRowPreview> _rows = [];
  final _decisions = <int, Map<String, Object?>?>{},
      _raw = <int, List<StagedXlsxCell>>{};
  final _previous = <int, ImportReceiptPage>{};
  final _cursors = <int>[];
  int _after = 1;
  BusinessImportSummary? _summary;
  CommitReceipt? _receipt;

  @override
  void dispose() {
    _path.dispose();
    _resume.dispose();
    _header.dispose();
    _offset.dispose();
    for (final control in _defaults.values) {
      control.dispose();
    }
    _session?.close();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _message = null;
      _failed = false;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) {
        setState(() {
          _failed = true;
          _message = '操作未完成：$error';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _select() => _run(() async {
    _parsing = ImportCancellation();
    try {
      _selection = await widget.adapter.select(
        _path.text,
        cancellation: _parsing,
      );
      _sheet = _selection!.sheets.first;
    } finally {
      _parsing = null;
    }
  });
  Future<void> _prepare() => _run(() async {
    _parsing = ImportCancellation();
    try {
      _session = await widget.adapter.prepare(
        _selection!,
        _sheet!,
        cancellation: _parsing,
      );
      _parsing!.check();
      await _readHeaders();
    } finally {
      _parsing = null;
    }
  });
  Future<void> _readHeaders() async {
    final row = int.tryParse(_header.text);
    if (row == null || row < 1) throw ArgumentError('标题行必须是正整数');
    _headers = await _session!.cells(row);
    _columns.clear();
    for (final cell in _headers) {
      final text = cell.cell.lexical.trim();
      for (final field in BusinessMapping.fields) {
        final template = businessQuotationColumns.where((c) => c.key == field);
        if (text == field ||
            text == businessFieldLabels[field] ||
            template.any((c) => c.heading == text)) {
          _columns[field] = cell.column;
        }
      }
    }
    _after = row;
  }

  Future<void> _map() => _run(() async {
    final defaults = <String, Object?>{};
    for (final entry in _defaults.entries) {
      if (entry.value.text.trim().isNotEmpty) {
        defaults[entry.key] = entry.value.text.trim();
      }
    }
    if (defaults.containsKey('inquiry_date')) {
      defaults['inquiry_precision'] = 'date';
    }
    final mapping = BusinessMapping(
      columns: {
        for (final e in _columns.entries)
          if (e.value != null)
            e.key: BusinessColumnMapping(
              e.value!,
              BusinessMapping.conversionFor(e.key),
            ),
      },
      captureMode: _mode,
      headerRow: int.parse(_header.text),
      defaults: defaults,
      utcOffsetMinutes: _offset.text.trim().isEmpty
          ? null
          : int.parse(_offset.text),
    );
    await _session!.setMapping(mapping);
    await _load();
  });
  Future<void> _load() async {
    _rows = await _session!.workflow.previewPage(afterRow: _after, limit: 10);
    _decisions.clear();
    _raw.clear();
    _previous.clear();
    for (final row in _rows) {
      _decisions[row.mapped.row] = await _session!.workflow.decisionForRow(
        row.mapped.row,
      );
      _raw[row.mapped.row] = await _session!.cells(row.mapped.row);
      if (row.previous != null) _previous[row.mapped.row] = row.previous!;
    }
  }

  Future<void> _morePrevious(BusinessRowPreview row) => _run(() async {
    final current = _previous[row.mapped.row] ?? row.previous;
    final cursor = current?.nextCursor;
    if (cursor == null || row.mapped.source == null) return;
    final next = await widget.adapter.exchange.lookupSource(
      _session!.jobId,
      row.mapped.source!,
      after: cursor,
      limit: 50,
    );
    if (!mounted) return;
    setState(() {
      _previous[row.mapped.row] = ImportReceiptPage([
        ...current!.items,
        ...next.items,
      ], next.nextCursor);
    });
  });

  Future<void> _resumeTask() => _run(() async {
    _session = await widget.adapter.resume(_resume.text.trim());
    _mode = _session!.mapping?.captureMode ?? CaptureMode.standard;
    _after = _session!.mapping?.headerRow ?? 1;
    if (_session!.jobState == JobState.committed) {
      final receipt = await _session!.confirm();
      _receipt = receipt;
      _done = true;
      _message = '任务已提交，恢复原回执：${receipt.confirmationEventId}';
    } else if (_session!.jobState == JobState.previewReady) {
      _summary = await _session!.summary();
    } else if (_session!.mapping != null) {
      await _load();
    } else {
      await _readHeaders();
    }
  });
  Future<void> _edit(BusinessRowPreview row) async {
    final changed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _RowDecisionDialog(session: _session!, preview: row),
    );
    if (changed == true && mounted) await _run(_load);
  }

  Future<void> _summarize() => _run(() async {
    _summary = await _session!.summary();
  });
  Future<void> _commit() => _run(() async {
    final receipt = await _session!.confirm();
    _receipt = receipt;
    _done = true;
    _message = '导入已提交。成功回执：${receipt.confirmationEventId}';
  });
  Future<void> _cancel() => _run(() async {
    await _session!.cancel();
    _done = true;
    _message = '任务已取消，业务数据未提交。';
  });

  Future<void> _showResultPage(
    Future<({List<String> ids, Object? next})> Function(Object? cursor) read,
  ) async {
    var page = await read(null);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) {
          return AlertDialog(
            title: const Text('已提交结果修订'),
            content: SizedBox(
              width: 620,
              child: SingleChildScrollView(
                child: SelectableText(page.ids.join('\n')),
              ),
            ),
            actions: [
              if (page.next != null)
                TextButton(
                  onPressed: () async {
                    try {
                      final next = await read(page.next);
                      if (context.mounted) update(() => page = next);
                    } catch (error) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('读取结果失败：$error')),
                        );
                      }
                    }
                  },
                  child: const Text('下一页结果'),
                ),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('关闭'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _currentResults() => _run(
    () => _showResultPage((cursor) async {
      final page = await widget.adapter.exchange.coordinator.receiptResults(
        _receipt!.resultCursor,
        after: cursor as String?,
        limit: 50,
      );
      return (ids: page.items, next: page.nextCursor);
    }),
  );

  Future<void> _previousResults(
    BusinessRowPreview row,
    SuccessfulImportOperation operation,
  ) => _run(
    () => _showResultPage((cursor) async {
      final page = await widget.adapter.exchange.receipts.readReceiptResults(
        eventId: operation.eventId,
        source: row.mapped.source!,
        operationFingerprint: operation.operationFingerprint,
        after: cursor as ReceiptResultCursor?,
        limit: 50,
      );
      return (ids: page.revisionIds, next: page.nextCursor);
    }),
  );

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: Scaffold(
      appBar: AppBar(title: const Text('导入业务 Excel')),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1160),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Text(
                _done
                    ? '导入结果'
                    : _summary != null
                    ? '核对汇总'
                    : _session?.mapping != null
                    ? '逐行核对'
                    : _session != null
                    ? '选择列映射'
                    : '选择资料与工作表',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 12),
              const Text('所有行均需明确决定。确认汇总后才写入；导入前会创建并校验完整备份。'),
              if (_busy)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  child: LinearProgressIndicator(),
                ),
              if (_busy && _parsing != null)
                TextButton(
                  onPressed: _parsing!.requested
                      ? null
                      : () async {
                          final pending = _parsing!;
                          setState(() {
                            pending.requested = true;
                            _message = '已请求取消解析，不会提交业务数据。';
                          });
                          try {
                            await pending.cancel();
                          } catch (error) {
                            if (mounted) {
                              setState(() => _message = '已停止读取，任务清理未完成：$error');
                            }
                          }
                        },
                  child: const Text('取消解析'),
                ),
              if (_message != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Semantics(
                    liveRegion: true,
                    child: Text(
                      _message!,
                      style: TextStyle(
                        color: _failed
                            ? Theme.of(context).colorScheme.error
                            : null,
                      ),
                    ),
                  ),
                ),
              if (_session != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: SelectableText(
                    '任务编号：${_session!.jobId}\n离开后可用此编号恢复；修改已确认的决定需新建任务。',
                  ),
                ),
              if (!_done && _session == null) ..._selectionWidgets(),
              if (!_done && _session != null && _session!.mapping == null)
                ..._mappingWidgets(),
              if (!_done && _session?.mapping != null && _summary == null)
                ..._previewWidgets(),
              if (!_done && _summary != null) ..._summaryWidgets(),
              if (_receipt != null)
                TextButton(
                  onPressed: _busy ? null : _currentResults,
                  child: Text('分页查看提交结果（${_receipt!.resultCount} 个修订）'),
                ),
              if (!_done && _session != null)
                Padding(
                  padding: const EdgeInsets.only(top: 24),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      onPressed: _busy ? null : _cancel,
                      child: const Text('取消本次任务'),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
  );
  List<Widget> _selectionWidgets() => [
    const SizedBox(height: 20),
    if (widget.adapter.usesPath)
      TextField(
        controller: _path,
        decoration: const InputDecoration(
          labelText: 'Excel 文件完整路径',
          hintText: '/完整路径/报价.xlsx',
          border: OutlineInputBorder(),
        ),
      ),
    const SizedBox(height: 12),
    Align(
      alignment: Alignment.centerLeft,
      child: FilledButton.icon(
        onPressed: _busy ? null : _select,
        icon: const Icon(Icons.file_open_outlined),
        label: Text(widget.adapter.usesPath ? '读取文件工作表' : '选择 Excel 文件'),
      ),
    ),
    if (_selection != null) ...[
      const SizedBox(height: 16),
      Text(_selection!.source.displayName),
      DropdownButtonFormField<String>(
        initialValue: _sheet,
        decoration: const InputDecoration(labelText: '工作表'),
        items: [
          for (final sheet in _selection!.sheets)
            DropdownMenuItem(value: sheet, child: Text(sheet)),
        ],
        onChanged: _busy ? null : (value) => setState(() => _sheet = value),
      ),
      const SizedBox(height: 12),
      FilledButton(
        onPressed: _busy ? null : _prepare,
        child: const Text('解析选中工作表'),
      ),
    ],
    const Divider(height: 40),
    TextField(
      controller: _resume,
      decoration: const InputDecoration(
        labelText: '恢复任务编号',
        border: OutlineInputBorder(),
      ),
    ),
    const SizedBox(height: 12),
    Align(
      alignment: Alignment.centerLeft,
      child: OutlinedButton(
        onPressed: _busy ? null : _resumeTask,
        child: const Text('恢复导入任务'),
      ),
    ),
  ];
  List<Widget> _mappingWidgets() => [
    const SizedBox(height: 16),
    DropdownButtonFormField<CaptureMode>(
      initialValue: _mode,
      decoration: const InputDecoration(labelText: '资料模式'),
      items: const [
        DropdownMenuItem(value: CaptureMode.standard, child: Text('标准报价')),
        DropdownMenuItem(
          value: CaptureMode.historical,
          child: Text('历史资料（明确允许上下文缺失）'),
        ),
      ],
      onChanged: _busy ? null : (value) => setState(() => _mode = value!),
    ),
    const SizedBox(height: 12),
    TextField(
      controller: _header,
      keyboardType: TextInputType.number,
      decoration: const InputDecoration(labelText: '标题行号'),
    ),
    Align(
      alignment: Alignment.centerLeft,
      child: TextButton(
        onPressed: _busy ? null : () => _run(_readHeaders),
        child: const Text('重新读取标题行'),
      ),
    ),
    Text(
      '工作表：${_session!.profile['sheet_name']} · ${_session!.profile['date1904'] == true ? '1904' : '1900'} 日期系统',
    ),
    const Text('编号保留文本；金额按精确十进制转换。未映射列与空白单元格分别保留。标题最多展示前100列。'),
    const SizedBox(height: 12),
    for (final field in [
      'record_id',
      'supplier_name',
      'product_name',
      'price',
      'unit_snapshot',
      'quoted_on',
      'inquiry_time',
      'project_name',
      'inquirer_name',
      'notes',
    ])
      _columnWidget(field),
    ExpansionTile(
      title: const Text('其他字段映射'),
      children: [
        for (final field in BusinessMapping.fields.where(
          (f) => ![
            'record_id',
            'supplier_name',
            'product_name',
            'price',
            'unit_snapshot',
            'quoted_on',
            'inquiry_time',
            'project_name',
            'inquirer_name',
            'notes',
          ].contains(f),
        ))
          _columnWidget(field),
      ],
    ),
    ExpansionTile(
      title: const Text('明确的批次默认值（可选）'),
      subtitle: const Text('只填写本批资料真实适用的值，不猜测日期或项目'),
      children: [
        for (final entry in _defaults.entries)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: TextField(
              controller: entry.value,
              decoration: InputDecoration(
                labelText: businessFieldLabels[entry.key],
              ),
            ),
          ),
      ],
    ),
    TextField(
      controller: _offset,
      keyboardType: const TextInputType.numberWithOptions(signed: true),
      decoration: const InputDecoration(
        labelText: '无时区时刻的明确 UTC 偏移分钟（可选，例如480）',
      ),
    ),
    const SizedBox(height: 20),
    FilledButton(
      onPressed: _busy ? null : _map,
      child: const Text('确认映射并查看转换预览'),
    ),
  ];
  Widget _columnWidget(String field) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: DropdownButtonFormField<int>(
      key: ValueKey('map-$field-${_columns[field]}'),
      initialValue: _columns[field] ?? 0,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: businessFieldLabels[field] ?? field,
      ),
      items: [
        const DropdownMenuItem(value: 0, child: Text('不映射')),
        for (final column in _headers)
          DropdownMenuItem(
            value: column.column,
            child: Text(
              '${column.column} · ${column.cell.lexical}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
      onChanged: _busy
          ? null
          : (value) =>
                setState(() => _columns[field] = value == 0 ? null : value),
    ),
  );
  List<Widget> _previewWidgets() => [
    const SizedBox(height: 16),
    if (_rows.isEmpty) const Text('当前页没有数据行。'),
    for (final row in _rows)
      Card(
        margin: const EdgeInsets.only(bottom: 12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 12,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    '第 ${row.mapped.row} 行',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  Text(
                    _decisions[row.mapped.row] != null
                        ? '已确认：${_actionLabel(_decisions[row.mapped.row]!)}'
                        : row.mapped.issues.isNotEmpty
                        ? '存在错误'
                        : row.alreadyImported
                        ? '已导入，建议跳过'
                        : '待确认',
                  ),
                  OutlinedButton(
                    onPressed: _busy || _decisions[row.mapped.row] != null
                        ? null
                        : () => _edit(row),
                    child: const Text('核对并选择操作'),
                  ),
                ],
              ),
              Text(
                '产品：${row.mapped.values['product_name'] ?? '未提供'} · 供应商：${row.mapped.values['supplier_name'] ?? '未提供'} · 价格：${row.mapped.values['price'] ?? '未提供'}',
              ),
              for (final issue in row.mapped.issues)
                Text(
                  '${issue.coordinate} ${businessFieldLabels[issue.field] ?? issue.field}：${issue.message}',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: const Text('原值、转换与匹配依据'),
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: SelectableText(
                      [
                        for (final cell
                            in _raw[row.mapped.row] ?? <StagedXlsxCell>[])
                          '${cell.cell.coordinate} (${cell.cell.kind.name})：${cell.cell.lexical}',
                      ].join('\n'),
                    ),
                  ),
                  for (final conversion in row.mapped.conversions)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        '${businessFieldLabels[conversion.field] ?? conversion.field}：${conversion.original} → ${_value(conversion.converted)}',
                      ),
                    ),
                  Text(
                    '原记录状态：${row.targetState}；${row.exportBaseline == null ? '无可用导出基线，不能自动判断修改先后' : '可用导出基线：${row.exportBaseline!.revisionId}'}',
                  ),
                  if (row.current != null)
                    SelectableText('当前完整值：${_value(row.current!.payload)}'),
                  if (row.exportBaseline != null)
                    SelectableText(
                      '导出基线：${_value(row.exportBaseline!.payload)}',
                    ),
                  for (final previous
                      in (_previous[row.mapped.row] ?? row.previous)?.items ??
                          <SuccessfulImportOperation>[]) ...[
                    SelectableText(
                      '原成功选择：${previous.legacyDetailsUnknown ? '旧回执未记录操作详情' : previous.operationCanonical}\n原目标：${previous.originalTargetId} · 事件：${previous.eventId}',
                    ),
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () => _previousResults(row, previous),
                      child: const Text('分页查看原结果'),
                    ),
                  ],
                  if ((_previous[row.mapped.row] ?? row.previous)?.nextCursor !=
                      null)
                    TextButton(
                      onPressed: _busy ? null : () => _morePrevious(row),
                      child: const Text('加载更多原成功选择'),
                    ),
                  for (final group in row.candidates.entries)
                    Text(
                      '${businessFieldLabels['${group.key}_name']}候选：${group.value.map((c) => '${c.displayName}（${c.state}，${c.reasons.join('、')}）').join('；')}',
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    Wrap(
      spacing: 12,
      runSpacing: 8,
      children: [
        OutlinedButton(
          onPressed: _busy || _cursors.isEmpty
              ? null
              : () => _run(() async {
                  _after = _cursors.removeLast();
                  await _load();
                }),
          child: const Text('上一页'),
        ),
        OutlinedButton(
          onPressed: _busy || _rows.length < 10
              ? null
              : () => _run(() async {
                  _cursors.add(_after);
                  _after = _rows.last.mapped.row;
                  await _load();
                }),
          child: const Text('下一页'),
        ),
        FilledButton(
          onPressed: _busy ? null : _summarize,
          child: const Text('查看最终汇总'),
        ),
      ],
    ),
  ];
  List<Widget> _summaryWidgets() => [
    const SizedBox(height: 24),
    Text(
      '应用 ${_summary!.applied} 行 · 跳过 ${_summary!.skipped} 行 · 排除错误 ${_summary!.excluded} 行',
      style: Theme.of(context).textTheme.titleLarge,
    ),
    const SizedBox(height: 12),
    Text('确认产生 ${_summary!.results} 条报价结果。此前的逐行确认尚未写入业务资料。'),
    Text(
      '其中修改 ${_summary!.modified} 行、新增标准询价 ${_summary!.newInquiries} 行、导入历史资料 ${_summary!.historical} 行。',
    ),
    const SizedBox(height: 20),
    FilledButton(
      onPressed: _busy ? null : _commit,
      child: const Text('确认汇总并提交导入'),
    ),
    if (_session!.jobState == JobState.validating)
      TextButton(
        onPressed: _busy ? null : () => setState(() => _summary = null),
        child: const Text('返回查看逐行决定'),
      ),
  ];
}

String _value(Object? value) =>
    value is String ? value : const JsonEncoder.withIndent('  ').convert(value);
String _actionLabel(Map<String, Object?> saved) => switch (saved['action']) {
  'skip' => '跳过',
  'excludeError' => '排除：${saved['exclusion_reason']}',
  _ => '应用 · ${(saved['operation'] as Map?)?['intent'] ?? ''}',
};

class _RowDecisionDialog extends StatefulWidget {
  const _RowDecisionDialog({required this.session, required this.preview});
  final BusinessImportSession session;
  final BusinessRowPreview preview;
  @override
  State<_RowDecisionDialog> createState() => _RowDecisionDialogState();
}

class _RowDecisionDialogState extends State<_RowDecisionDialog> {
  late BusinessRowChoice _choice;
  late final TextEditingController _target;
  final _supplier = TextEditingController(),
      _product = TextEditingController(),
      _contact = TextEditingController(),
      _supplierName = TextEditingController(),
      _productName = TextEditingController(),
      _unit = TextEditingController(text: '件'),
      _quantity = TextEditingController(text: '1'),
      _reason = TextEditingController();
  final _edits = <String, TextEditingController>{},
      _operations = <String, String>{};
  bool _newSupplier = false,
      _newProduct = false,
      _ack = false,
      _reprocess = false,
      _saving = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    final row = widget.preview;
    _choice = row.mapped.issues.isNotEmpty
        ? BusinessRowChoice.excludeError
        : row.alreadyImported
        ? BusinessRowChoice.skip
        : row.current?.kind == 'put'
        ? BusinessRowChoice.modify
        : widget.session.mapping!.captureMode == CaptureMode.historical
        ? BusinessRowChoice.importHistorical
        : BusinessRowChoice.newInquiry;
    _target = TextEditingController(
      text: row.mapped.values['record_id'] as String? ?? '',
    );
    _supplier.text = row.mapped.values['supplier_id'] as String? ?? '';
    _product.text = row.mapped.values['product_id'] as String? ?? '';
    _supplierName.text = row.mapped.values['supplier_name'] as String? ?? '';
    _productName.text = row.mapped.values['product_name'] as String? ?? '';
    _unit.text =
        (row.mapped.values['unit_snapshot'] ??
                widget.session.mapping!.defaults['unit_snapshot'] ??
                '件')
            .toString();
    for (final field in Quotation.fields.where(
      (f) => ![
        'supplier_id',
        'product_id',
        'contact_id',
        'capture_mode',
      ].contains(f),
    )) {
      final value =
          row.mapped.values[field] ?? widget.session.mapping!.defaults[field];
      _edits[field] = TextEditingController(
        text: value == null ? '' : _value(value),
      );
      _operations[field] = 'incoming';
    }
  }

  @override
  void dispose() {
    for (final c in [
      _target,
      _supplier,
      _product,
      _contact,
      _supplierName,
      _productName,
      _unit,
      _quantity,
      _reason,
      ..._edits.values,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final sets = <String, Object?>{}, clear = <String>{}, keep = <String>{};
      for (final field in _edits.keys) {
        switch (_operations[field]) {
          case 'clear':
            clear.add(field);
          case 'keep':
            keep.add(field);
          case 'set':
            final map = BusinessMapping(
              columns: {
                field: BusinessColumnMapping(
                  1,
                  BusinessMapping.conversionFor(field),
                ),
              },
            );
            final converted = map.convert(1, {
              1: RawBusinessCell(
                coordinate: field,
                kind: BusinessCellKind.text,
                lexical: _edits[field]!.text,
              ),
            }, date1904: false);
            if (converted.issues.isNotEmpty ||
                converted.values[field] == null) {
              throw FormatException(
                '${businessFieldLabels[field]}：请输入有效设置值；清空请明确选择清空',
              );
            }
            sets[field] = converted.values[field];
        }
      }
      await widget.session.workflow.decide(
        widget.preview.mapped.row,
        BusinessRowDecision(
          choice: _choice,
          targetId: _choice == BusinessRowChoice.modify
              ? _target.text.trim()
              : null,
          bindings: {
            if (!_newSupplier && _supplier.text.trim().isNotEmpty)
              'supplier_id': _supplier.text.trim(),
            if (!_newProduct && _product.text.trim().isNotEmpty)
              'product_id': _product.text.trim(),
            if (_contact.text.trim().isNotEmpty)
              'contact_id': _contact.text.trim(),
          },
          createSupplier: _newSupplier
              ? {
                  'name': _supplierName.text,
                  'aliases': <String>[],
                  'categories': <String>[],
                  'address': null,
                  'notes': null,
                }
              : null,
          createProduct: _newProduct
              ? {
                  'name': _productName.text,
                  'unit': _unit.text,
                  'brand': widget.preview.mapped.values['product_brand'],
                  'model': widget.preview.mapped.values['product_model'],
                  'specification':
                      widget.preview.mapped.values['product_specification'],
                  'category': null,
                  'notes': null,
                }
              : null,
          setFields: sets,
          clearFields: clear,
          keepFields: keep,
          quantity: int.parse(_quantity.text),
          acknowledgeConversions: _ack,
          reprocessSuccessfulSource: _reprocess,
          exclusionReason: _reason.text.trim(),
        ),
      );
      if (mounted) Navigator.pop(context, true);
    } catch (error) {
      if (mounted) setState(() => _error = '此行尚未确认：$error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final applying = ![
      BusinessRowChoice.skip,
      BusinessRowChoice.excludeError,
    ].contains(_choice);
    return AlertDialog(
      title: Text('核对第 ${widget.preview.mapped.row} 行'),
      content: SizedBox(
        width: 800,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_error != null)
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              DropdownButtonFormField<BusinessRowChoice>(
                initialValue: _choice,
                decoration: const InputDecoration(labelText: '本行操作'),
                items: [
                  const DropdownMenuItem(
                    value: BusinessRowChoice.modify,
                    child: Text('修改原报价'),
                  ),
                  const DropdownMenuItem(
                    value: BusinessRowChoice.newInquiry,
                    child: Text('新增标准询价'),
                  ),
                  if (widget.session.mapping!.captureMode ==
                      CaptureMode.historical)
                    const DropdownMenuItem(
                      value: BusinessRowChoice.importHistorical,
                      child: Text('导入历史报价'),
                    ),
                  const DropdownMenuItem(
                    value: BusinessRowChoice.skip,
                    child: Text('跳过'),
                  ),
                  const DropdownMenuItem(
                    value: BusinessRowChoice.excludeError,
                    child: Text('显式排除错误行'),
                  ),
                ],
                onChanged: _saving
                    ? null
                    : (value) => setState(() {
                        _choice = value!;
                        if (_choice != BusinessRowChoice.modify) {
                          for (final field in _operations.keys) {
                            if (_operations[field] == 'keep') {
                              _operations[field] = 'incoming';
                            }
                          }
                        }
                      }),
              ),
              if (_choice == BusinessRowChoice.excludeError)
                TextField(
                  controller: _reason,
                  decoration: const InputDecoration(labelText: '排除原因（必填）'),
                ),
              if (applying) ...[
                if (_choice == BusinessRowChoice.modify)
                  TextField(
                    controller: _target,
                    decoration: const InputDecoration(labelText: '明确选择原报价编号'),
                  ),
                const SizedBox(height: 12),
                const Text('以下身份须明确核对。未知编号不会自动创建实体；名称候选不会自动合并。'),
                _binding(
                  'supplier',
                  _supplier,
                  _supplierName,
                  _newSupplier,
                  (value) => setState(() => _newSupplier = value),
                ),
                _binding(
                  'product',
                  _product,
                  _productName,
                  _newProduct,
                  (value) => setState(() => _newProduct = value),
                ),
                if (_newProduct)
                  TextField(
                    controller: _unit,
                    decoration: const InputDecoration(labelText: '新产品默认单位'),
                  ),
                TextField(
                  controller: _contact,
                  decoration: const InputDecoration(
                    labelText: '明确选择联系人编号（可选，自动复制当前快照）',
                  ),
                ),
                if (_choice != BusinessRowChoice.modify)
                  TextField(
                    controller: _quantity,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: '明确保留的询价数量'),
                  ),
                ExpansionTile(
                  title: const Text('字段操作：使用来件 / 保留 / 清空 / 设置'),
                  subtitle: const Text('空白来件修改时保留原值；清空必须单独选择'),
                  children: [
                    for (final entry in _edits.entries)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 16),
                        child: Column(
                          children: [
                            DropdownButtonFormField<String>(
                              initialValue: _operations[entry.key],
                              decoration: InputDecoration(
                                labelText: businessFieldLabels[entry.key],
                              ),
                              items: [
                                const DropdownMenuItem(
                                  value: 'incoming',
                                  child: Text('使用来件与批次默认值'),
                                ),
                                if (_choice == BusinessRowChoice.modify)
                                  const DropdownMenuItem(
                                    value: 'keep',
                                    child: Text('保留当前值'),
                                  ),
                                const DropdownMenuItem(
                                  value: 'clear',
                                  child: Text('明确清空'),
                                ),
                                const DropdownMenuItem(
                                  value: 'set',
                                  child: Text('设置指定值'),
                                ),
                              ],
                              onChanged: _saving
                                  ? null
                                  : (value) => setState(
                                      () => _operations[entry.key] = value!,
                                    ),
                            ),
                            if (_operations[entry.key] == 'set')
                              TextField(
                                controller: entry.value,
                                decoration: InputDecoration(
                                  labelText:
                                      '设置${businessFieldLabels[entry.key]}',
                                ),
                                maxLines:
                                    entry.key == 'notes' ||
                                        entry.key == 'contact_snapshot'
                                    ? 3
                                    : 1,
                              ),
                          ],
                        ),
                      ),
                  ],
                ),
                if (widget.preview.mapped.conversions.isNotEmpty) ...[
                  for (final conversion in widget.preview.mapped.conversions)
                    Text(
                      '${businessFieldLabels[conversion.field]}：${conversion.original} → ${_value(conversion.converted)}',
                    ),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _ack,
                    onChanged: _saving
                        ? null
                        : (value) => setState(() => _ack = value!),
                    title: const Text('已核对并接受上述格式转换'),
                  ),
                ],
                if (widget.preview.alreadyImported)
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _reprocess,
                    onChanged: _saving
                        ? null
                        : (value) => setState(() => _reprocess = value!),
                    title: const Text('已查看旧回执，明确重新处理此次来件'),
                  ),
              ],
              if (_saving) const LinearProgressIndicator(),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('返回'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: const Text('确认本行决定'),
        ),
      ],
    );
  }

  Widget _binding(
    String type,
    TextEditingController id,
    TextEditingController name,
    bool creating,
    void Function(bool) change,
  ) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      CheckboxListTile(
        contentPadding: EdgeInsets.zero,
        value: creating,
        onChanged: _saving ? null : (value) => change(value!),
        title: Text('明确新建${type == 'supplier' ? '供应商' : '产品'}'),
      ),
      TextField(
        controller: creating ? name : id,
        decoration: InputDecoration(
          labelText: creating
              ? '新${businessFieldLabels['${type}_name']}'
              : '明确选择${type == 'supplier' ? '供应商' : '产品'}编号',
        ),
      ),
      if (!creating)
        Wrap(
          spacing: 8,
          children: [
            for (final candidate
                in widget.preview.candidates[type] ?? <Candidate>[])
              ActionChip(
                label: Text('${candidate.displayName} · ${candidate.state}'),
                onPressed: _saving
                    ? null
                    : () => setState(() => id.text = candidate.id),
              ),
          ],
        ),
    ],
  );
}
