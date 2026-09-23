import 'package:flutter/material.dart';
import 'package:supplier_core/supplier_core.dart';

import '../../app/workspace.dart';

const fieldLabels = {
  'name': '名称',
  'aliases': '别名',
  'address': '地址',
  'categories': '类别',
  'notes': '备注',
  'supplier_id': '供应商',
  'product_id': '产品',
  'contact_id': '联系人',
  'phone': '电话',
  'wechat': '微信',
  'email': '邮箱',
  'brand': '品牌',
  'model': '型号',
  'specification': '规格',
  'category': '类别',
  'unit': '单位',
  'price': '价格',
  'currency': '币种',
  'tax_mode': '税制',
  'unit_snapshot': '报价单位',
  'min_qty': '起订量',
  'quoted_on': '报价日期',
  'contact_snapshot': '报价时联系人',
  'tax_rate': '税率（%）',
  'lead_time_days': '交期（天）',
  'valid_until': '有效期至',
  'project': '项目名称或编号',
  'project_name': '项目名称',
  'project_number': '项目编号',
  'inquiry_location': '询价地点',
  'inquirer_name': '询价人',
  'inquiry_precision': '询价时间精度',
  'inquiry_date': '询价日期',
  'inquired_at': '询价时刻',
  'inquiry_utc_offset_minutes': '原始时区',
  'capture_mode': '资料模式',
};

class RecordEditor extends StatefulWidget {
  const RecordEditor({
    super.key,
    required this.workspace,
    required this.type,
    this.record,
    this.copy = false,
    this.resolving = false,
  });
  final SupplierWorkspace workspace;
  final String type;
  final WorkspaceRecord? record;
  final bool copy;
  final bool resolving;
  @override
  State<RecordEditor> createState() => _RecordEditorState();
}

class _RecordEditorState extends State<RecordEditor> {
  final _form = GlobalKey<FormState>();
  final _controllers = <String, TextEditingController>{};
  final _fieldKeys = <String, GlobalKey>{};
  final _selection = <String, WorkspaceRecord>{};
  var _step = 0;
  var _busy = false;
  var _dirty = false;
  bool _explicitClear = false;
  String? _error;
  String? _invalidField;
  String _precision = 'date';
  String _tax = 'unknown';
  String? _offset;
  bool get _quotation => widget.type == 'quotation';
  bool get _historical =>
      !widget.copy && widget.record?.payload['capture_mode'] == 'historical';
  Map<String, Object?> get _original => widget.record?.payload ?? const {};

  @override
  void initState() {
    super.initState();
    for (final entry in _original.entries) {
      if (entry.value is String || entry.value is int || entry.value is List) {
        _controller(entry.key).text = entry.value is List
            ? (entry.value as List).join('\n')
            : entry.value.toString();
      }
    }
    _precision = _original['inquiry_precision'] as String? ?? 'date';
    if (widget.copy && _precision == 'unknown') _precision = 'date';
    _tax = _original['tax_mode'] as String? ?? 'unknown';
    if (_quotation) {
      if (_original.isEmpty) {
        _controller('currency').text = 'CNY';
        _controller('min_qty').text = '1';
      }
      final offset = _original['inquiry_utc_offset_minutes'];
      if (offset is int) {
        final absolute = offset.abs();
        _offset =
            '${offset < 0 ? '-' : '+'}${(absolute ~/ 60).toString().padLeft(2, '0')}:${(absolute % 60).toString().padLeft(2, '0')}';
        final instant = DateTime.tryParse(
          _original['inquired_at']?.toString() ?? '',
        );
        if (instant != null) {
          _controller('time').text = instant
              .toUtc()
              .add(Duration(minutes: offset))
              .toIso8601String()
              .substring(11, 23);
        }
      }
      final snapshot = _original['contact_snapshot'];
      if (snapshot is Map) {
        for (final key in ['name', 'phone', 'wechat', 'email']) {
          _controller('snapshot_$key').text = snapshot[key]?.toString() ?? '';
        }
      }
    }
  }

  TextEditingController _controller(String key) =>
      _controllers.putIfAbsent(key, TextEditingController.new);
  String? _text(String key) {
    final text = _controller(key).text.trim();
    return text.isEmpty ? null : text;
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Widget _field(
    String key, {
    bool required = false,
    String? label,
    String? hint,
    int lines = 1,
  }) => Padding(
    key: _fieldKeys.putIfAbsent(key, GlobalKey.new),
    padding: const EdgeInsets.only(bottom: 16),
    child: TextFormField(
      key: ValueKey('field-$key'),
      controller: _controller(key),
      enabled: !_busy,
      minLines: lines,
      maxLines: lines,
      textInputAction: lines > 1
          ? TextInputAction.newline
          : TextInputAction.next,
      keyboardType: lines > 1
          ? TextInputType.multiline
          : ['price', 'min_qty', 'tax_rate'].contains(key)
          ? const TextInputType.numberWithOptions(decimal: true)
          : key == 'lead_time_days'
          ? TextInputType.number
          : TextInputType.text,
      decoration: InputDecoration(
        labelText: '${label ?? fieldLabels[key] ?? key}${required ? ' *' : ''}',
        hintText: hint,
        errorText: _invalidField == key ? _error : null,
      ),
      onChanged: (_) {
        _dirty = true;
      },
      validator: required
          ? (value) => value == null || value.trim().isEmpty
                ? '请填写${label ?? fieldLabels[key] ?? key}'
                : null
          : null,
    ),
  );

  Future<void> _pick(String type, String key) async {
    final picked = await showDialog<WorkspaceRecord>(
      context: context,
      builder: (_) => _EntityPicker(
        workspace: widget.workspace,
        type: type,
        supplierId: type == 'contact' ? _text('supplier_id') : null,
      ),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _dirty = true;
      _selection[key] = picked;
      _controller(key).text = picked.id;
      if (key == 'product_id') {
        _controller('unit_snapshot').text =
            picked.payload['unit']?.toString() ?? '';
      }
      if (key == 'supplier_id') {
        _selection.remove('contact_id');
        _controller('contact_id').clear();
      }
      if (key == 'contact_id') {
        for (final name in ['name', 'phone', 'wechat', 'email']) {
          _controller('snapshot_$name').text =
              picked.payload[name]?.toString() ?? '';
        }
      }
    });
  }

  Widget _entity(String type, String key, {bool required = true}) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: FormField<String>(
      key: ValueKey('select-$key'),
      validator: (_) =>
          required && _text(key) == null ? '请选择${fieldLabels[key]}' : null,
      builder: (state) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          OutlinedButton.icon(
            onPressed: _busy ? null : () => _pick(type, key),
            icon: const Icon(Icons.search),
            label: Text(
              _selection[key]?.title ??
                  (_text(key) == null
                      ? '选择${fieldLabels[key]}${required ? ' *' : ''}'
                      : '已关联${fieldLabels[key]}（更换）'),
            ),
          ),
          if (state.hasError)
            Text(
              state.errorText!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        ],
      ),
    ),
  );

  List<Widget> _basicFields() => [
    _entity('supplier', 'supplier_id'),
    _entity('product', 'product_id'),
    _field('price', required: true, hint: '最多 6 位小数，0 表示已取得零报价'),
    _field('currency', required: true),
    _field('unit_snapshot', required: true),
    _field('min_qty', required: true),
    Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: DropdownButtonFormField<String>(
        initialValue: _tax,
        decoration: const InputDecoration(labelText: '税制'),
        items: const [
          DropdownMenuItem(value: 'unknown', child: Text('未知')),
          DropdownMenuItem(value: 'included', child: Text('含税')),
          DropdownMenuItem(value: 'excluded', child: Text('不含税')),
        ],
        onChanged: _busy
            ? null
            : (value) => setState(() {
                _tax = value!;
                _dirty = true;
              }),
      ),
    ),
    _field('tax_rate'),
    _field('quoted_on', required: !_historical, hint: 'YYYY-MM-DD'),
    _field('valid_until', hint: 'YYYY-MM-DD'),
    _field('lead_time_days'),
  ];
  List<Widget> _contextFields() => [
    _field('project_name'),
    _field('project_number', hint: '编号按文字保存，保留前导零'),
    const Padding(
      padding: EdgeInsets.only(bottom: 16),
      child: Text('项目名称和编号至少填写一项。'),
    ),
    _field('inquirer_name', required: !_historical),
    Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: DropdownButtonFormField<String>(
        initialValue: _precision,
        decoration: const InputDecoration(labelText: '询价时间精度'),
        items: [
          const DropdownMenuItem(value: 'date', child: Text('仅日期')),
          const DropdownMenuItem(value: 'instant', child: Text('具体时刻')),
          if (_historical)
            const DropdownMenuItem(value: 'unknown', child: Text('历史日期未知')),
        ],
        onChanged: _busy
            ? null
            : (value) => setState(() {
                _precision = value!;
                _dirty = true;
              }),
      ),
    ),
    if (_precision != 'unknown')
      _field('inquiry_date', required: true, hint: 'YYYY-MM-DD'),
    if (_precision == 'instant') ...[
      _field('time', label: '当地时刻', required: true, hint: 'HH:mm，可填写秒和毫秒'),
      Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: TextFormField(
          key: const ValueKey('field-offset'),
          initialValue: _offset,
          decoration: const InputDecoration(
            labelText: '询价地点时区 *',
            hintText: '例如 +08:00，明确选择原始时区',
          ),
          onChanged: (value) {
            _offset = value.trim();
            _dirty = true;
          },
          validator: (value) =>
              value == null || !RegExp(r'^[+-]\d{2}:\d{2}$').hasMatch(value)
              ? '请填写时区，例如 +08:00'
              : null,
        ),
      ),
      const Padding(
        padding: EdgeInsets.only(bottom: 16),
        child: Text('未填写秒时按该分钟起点记录；保存前会显示最终时刻。'),
      ),
    ],
    _field('inquiry_location'),
  ];
  List<Widget> _contactFields() => [
    _entity('contact', 'contact_id', required: false),
    const Text('可选择联系人，也可直接填写报价时的联系方式。'),
    const SizedBox(height: 12),
    for (final key in ['name', 'phone', 'wechat', 'email'])
      _field('snapshot_$key', label: '联系人${fieldLabels[key]}'),
    _field('notes', lines: 3),
  ];
  List<Widget> _entityFields() => switch (widget.type) {
    'supplier' => [
      _field('name', required: true),
      _field('aliases', hint: '每行一个别名', lines: 3),
      _field('address'),
      _field('categories', hint: '每行一个类别', lines: 3),
      _field('notes', lines: 3),
    ],
    'product' => [
      _field('name', required: true),
      _field('unit', required: true),
      _field('brand'),
      _field('model'),
      _field('specification', lines: 3),
      _field('category'),
      _field('notes', lines: 3),
    ],
    'contact' => [
      _entity('supplier', 'supplier_id'),
      _field('name', required: true),
      _field('phone'),
      _field('wechat'),
      _field('email'),
      const Text('电话、微信和邮箱至少填写一项。'),
      const SizedBox(height: 12),
      _field('notes', lines: 3),
    ],
    _ => [],
  };

  Map<String, Object?> _payload() {
    if (!_quotation) {
      final fields = switch (widget.type) {
        'supplier' => Supplier.fields,
        'contact' => Contact.fields,
        'product' => Product.fields,
        _ => <String>[],
      };
      return validatePayload(widget.type, {
        for (final key in fields)
          key: ['aliases', 'categories'].contains(key)
              ? (_text(key)?.split('\n') ?? <String>[])
              : _text(key),
      });
    }
    if (!_historical &&
        _text('project_name') == null &&
        _text('project_number') == null) {
      throw const DomainFailure(
        'required',
        '请填写项目名称或编号',
        field: 'project_name',
      );
    }
    final values = <String, Object?>{
      for (final key in Quotation.fields) key: _text(key),
    };
    values['capture_mode'] = _historical ? 'historical' : 'standard';
    values['tax_mode'] = _tax;
    values['lead_time_days'] = _text('lead_time_days') == null
        ? null
        : int.tryParse(_text('lead_time_days')!);
    if (_text('lead_time_days') != null && values['lead_time_days'] == null) {
      throw const DomainFailure('invalid', '交期必须为整数', field: 'lead_time_days');
    }
    values['contact_snapshot'] =
        [
          'name',
          'phone',
          'wechat',
          'email',
        ].every((key) => _text('snapshot_$key') == null)
        ? null
        : <String, Object?>{
            for (final key in ['name', 'phone', 'wechat', 'email'])
              key: _text('snapshot_$key'),
          };
    if (_precision == 'unknown') {
      values.addAll({
        'inquiry_precision': 'unknown',
        'inquiry_date': null,
        'inquired_at': null,
        'inquiry_utc_offset_minutes': null,
      });
    } else {
      values.addAll(
        InquiryTime.parseInput(
          _precision == 'date'
              ? _text('inquiry_date') ?? ''
              : '${_text('inquiry_date')}T${_text('time')}$_offset',
        ).toJson(),
      );
    }
    return Quotation.fromJson(values).toJson();
  }

  Future<void> _save() async {
    setState(() {
      _error = null;
      _invalidField = null;
    });
    Map<String, Object?> payload;
    try {
      payload = _payload();
    } on DomainFailure catch (error) {
      final field = error.field;
      setState(() {
        _invalidField = field;
        _error = error.code == 'required'
            ? error.message
            : '请检查${fieldLabels[field] ?? (field?.startsWith('contact_snapshot') == true ? '联系人信息' : '填写内容')}，格式或必填项不符合要求。';
        if (_quotation) {
          _step =
              [
                'project_name',
                'project',
                'inquirer_name',
                'inquiry_date',
                'inquired_at',
                'inquiry_precision',
              ].contains(field)
              ? 1
              : field == 'contact_snapshot'
              ? 2
              : 0;
        }
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final target = _fieldKeys[field]?.currentContext;
        if (target != null) {
          Scrollable.ensureVisible(target, duration: Duration.zero);
        }
      });
      return;
    }
    if (!_form.currentState!.validate()) return;
    if (widget.record != null &&
        !widget.copy &&
        !_explicitClear &&
        _original.entries.any(
          (entry) => entry.value != null && payload[entry.key] == null,
        )) {
      final clear = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('确认清空已有信息'),
          content: const Text('本次修改将清空部分已有字段。历史修订仍会保留。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('确认清空'),
            ),
          ],
        ),
      );
      if (clear != true || !mounted) return;
      _explicitClear = true;
    }
    if (_quotation && _precision == 'instant') {
      final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('确认询价时刻'),
          content: Text(
            '当地时间：${payload['inquiry_date']} ${_text('time')}\n原始时区：$_offset\n保存时刻：${payload['inquired_at']}',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('返回修改'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('确认保存'),
            ),
          ],
        ),
      );
      if (accepted != true || !mounted) return;
    }
    setState(() => _busy = true);
    try {
      if (widget.resolving) {
        await widget.workspace.resolveConflict(
          widget.record!,
          payload,
          allowExplicitClear: _explicitClear,
        );
      } else {
        await widget.workspace.save(
          widget.type,
          payload,
          id: widget.copy ? null : widget.record?.id,
          expectedHeads: widget.copy
              ? const {}
              : widget.record?.heads ?? const {},
          copyFrom: widget.copy ? widget.record!.id : null,
          allowExplicitClear: _explicitClear,
        );
      }
      if (mounted) {
        _dirty = false;
        Navigator.pop(context, true);
      }
    } catch (error) {
      if (mounted) setState(() => _error = '保存未完成：$error。输入已保留，请重试或重新读取记录。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _cancel() async {
    if (_busy) return;
    if (_dirty) {
      final discard = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('放弃未保存的修改？'),
          content: const Text('已保存的记录不会改变。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('继续填写'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('放弃修改'),
            ),
          ],
        ),
      );
      if (discard != true || !mounted) return;
    }
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final narrow = MediaQuery.sizeOf(context).width < 700;
    final title = widget.copy
        ? '复制为新询价'
        : '${widget.resolving
              ? '解决冲突：'
              : widget.record == null
              ? '新增'
              : '编辑'}${{'quotation': '报价', 'supplier': '供应商', 'contact': '联系人', 'product': '产品'}[widget.type]}';
    final groups = _quotation
        ? [_basicFields, _contextFields, _contactFields]
        : <List<Widget> Function()>[];
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        leading: IconButton(
          tooltip: '取消编辑',
          onPressed: _busy ? null : _cancel,
          icon: const Icon(Icons.arrow_back),
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            if (_busy) const LinearProgressIndicator(semanticsLabel: '正在保存'),
            if (_quotation && narrow)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      ['报价信息', '项目与询价', '联系人与备注'][_step],
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    Text('第 ${_step + 1} 步，共 3 步'),
                  ],
                ),
              ),
            Expanded(
              child: Form(
                key: _form,
                child: ListView(
                  padding: const EdgeInsets.all(20),
                  children: [
                    if (_historical)
                      const Padding(
                        padding: EdgeInsets.only(bottom: 16),
                        child: Text('历史资料：存在缺失信息。请保留真实未知值，不补造日期。'),
                      ),
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 16),
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
                    if (_quotation && narrow) ...[
                      ...groups[_step](),
                    ] else if (_quotation) ...[
                      for (var i = 0; i < groups.length; i++) ...[
                        Text(
                          ['报价信息', '项目与询价', '联系人与备注'][i],
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const SizedBox(height: 20),
                        ...groups[i](),
                        const SizedBox(height: 12),
                      ],
                    ] else
                      ..._entityFields(),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Wrap(
                spacing: 12,
                runSpacing: 8,
                alignment: WrapAlignment.end,
                children: [
                  TextButton(
                    onPressed: _busy ? null : _cancel,
                    child: const Text('取消'),
                  ),
                  if (_quotation && narrow && _step > 0)
                    OutlinedButton(
                      onPressed: _busy ? null : () => setState(() => _step--),
                      child: const Text('上一步'),
                    ),
                  if (_quotation && narrow && _step < 2)
                    FilledButton(
                      onPressed: _busy
                          ? null
                          : () {
                              if (_form.currentState!.validate()) {
                                setState(() => _step++);
                              }
                            },
                      child: const Text('下一步'),
                    ),
                  FilledButton(
                    onPressed: _busy || widget.workspace.readOnlyReason != null
                        ? null
                        : _save,
                    child: const Text('保存'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EntityPicker extends StatefulWidget {
  const _EntityPicker({
    required this.workspace,
    required this.type,
    this.supplierId,
  });
  final SupplierWorkspace workspace;
  final String type;
  final String? supplierId;
  @override
  State<_EntityPicker> createState() => _EntityPickerState();
}

class _EntityPickerState extends State<_EntityPicker> {
  final _search = TextEditingController();
  String? _cursor;
  late Future<WorkspacePage> _page = _load();
  Future<WorkspacePage> _load() => widget.workspace.list(
    widget.type,
    search: _search.text,
    filters: {if (widget.supplierId != null) 'supplier_id': widget.supplierId!},
    cursor: _cursor,
  );
  void _reload() => setState(() {
    _cursor = null;
    _page = _load();
  });
  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      '选择${{'supplier': '供应商', 'product': '产品', 'contact': '联系人'}[widget.type]}',
    ),
    content: SizedBox(
      width: 480,
      height: 360,
      child: Column(
        children: [
          TextField(
            controller: _search,
            decoration: InputDecoration(
              labelText: '搜索名称',
              suffixIcon: IconButton(
                tooltip: '查找',
                onPressed: _reload,
                icon: const Icon(Icons.search),
              ),
            ),
            onSubmitted: (_) => _reload(),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: FutureBuilder<WorkspacePage>(
              future: _page,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snapshot.hasError) {
                  return Column(
                    children: [
                      Text('读取失败：${snapshot.error}'),
                      TextButton(onPressed: _reload, child: const Text('重试')),
                    ],
                  );
                }
                final page = snapshot.requireData;
                if (page.records.isEmpty) {
                  return const Center(child: Text('暂无候选，请先新建或调整搜索。'));
                }
                return Column(
                  children: [
                    Expanded(
                      child: ListView.builder(
                        itemCount: page.records.length,
                        itemBuilder: (context, i) {
                          final record = page.records[i];
                          return ListTile(
                            title: Text(record.title),
                            subtitle: Text(record.subtitle),
                            enabled: record.status == 'active',
                            onTap: () => Navigator.pop(context, record),
                          );
                        },
                      ),
                    ),
                    if (page.nextCursor != null)
                      TextButton(
                        onPressed: () => setState(() {
                          _cursor = page.nextCursor;
                          _page = _load();
                        }),
                        child: const Text('更多候选'),
                      ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
    ],
  );
}
