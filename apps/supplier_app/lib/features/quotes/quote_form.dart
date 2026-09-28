import 'package:flutter/material.dart';
import 'package:supplier_core/supplier_core.dart';

import '../../app/app_state.dart';
import '../../app/theme.dart';
import 'quote_extras.dart';
import '../../widgets/save_keys.dart';

/// Records one standard quotation. Supplier, material and project are picked
/// by typing; dates use the system picker (date only, never a fake 00:00).
/// Edits quotation [id], or starts a new one with [prefill] fields (for
/// example the supplier or material it is being added from).
Future<void> showQuoteForm(
  BuildContext context,
  AppState state, {
  String? id,
  Map<String, Object?> prefill = const {},
}) => showDialog(
  context: context,
  builder: (_) => _QuoteForm(state: state, id: id, prefill: prefill),
);

class _QuoteForm extends StatefulWidget {
  const _QuoteForm({required this.state, this.id, this.prefill = const {}});
  final AppState state;
  final String? id;
  final Map<String, Object?> prefill;

  @override
  State<_QuoteForm> createState() => _QuoteFormState();
}

class _QuoteFormState extends State<_QuoteForm> {
  late Map<String, Object?> data;
  final c = <String, TextEditingController>{};
  String? error;

  Store get store => widget.state.store;

  @override
  void initState() {
    super.initState();
    final today = DateTime.now().toIso8601String().substring(0, 10);
    data = widget.id != null
        ? Map.of(store.get('quotation', widget.id!)!.data)
        : {
            for (final f in Quotation.fields) f: null,
            'currency': 'CNY',
            'tax_mode': 'included',
            'min_qty': '1',
            'quoted_on': today,
            'inquiry_precision': 'date',
            'inquiry_date': today,
            'capture_mode': 'standard',
            ...widget.prefill,
          };
    for (final k in [
      'price',
      'unit_snapshot',
      'min_qty',
      'tax_rate',
      'lead_time_days',
      'inquirer_name',
      'inquiry_location',
      'notes',
      'extra_cost',
      'warranty_months',
    ]) {
      final v = data[k];
      c[k] = TextEditingController(text: v == null ? '' : '$v');
    }
  }

  @override
  void dispose() {
    for (final x in c.values) {
      x.dispose();
    }
    super.dispose();
  }

  String? _label(String type, Object? id) {
    if (id == null) return null;
    final d = store.get(type, id as String)?.data;
    if (d == null) return null;
    return type == 'project'
        ? '${d['name']}（${d['code']}）'
        : [d['name'], d['model']].whereType<String>().join(' ');
  }

  Widget _picker(String type, String key, String label) => Autocomplete<Hit>(
    initialValue: TextEditingValue(text: _label(type, data[key]) ?? ''),
    displayStringForOption: (h) => _label(type, h.id)!,
    optionsBuilder: (v) {
      final q = v.text.trim();
      if (type == 'product' && q.isNotEmpty) {
        return store.searchProducts(q.split(RegExp(r'\s+')), limit: 20);
      }
      return store.searchByName(type, q, limit: 20);
    },
    onSelected: (h) => setState(() {
      if (key == 'supplier_id' && data[key] != h.id) {
        data['contact_id'] = null;
        data['contact_snapshot'] = null;
      }
      data[key] = h.id;
      if (type == 'product' && c['unit_snapshot']!.text.isEmpty) {
        c['unit_snapshot']!.text = h.data['unit']! as String;
      }
    }),
    fieldViewBuilder: (context, controller, focus, submit) => TextField(
      controller: controller,
      focusNode: focus,
      decoration: InputDecoration(labelText: label, hintText: '输入名称搜索'),
      onChanged: (_) => data[key] = null,
    ),
  );

  Future<void> _date(String key) async {
    final current =
        DateTime.tryParse(data[key] as String? ?? '') ?? DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: current,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null) {
      setState(() {
        data[key] = picked.toIso8601String().substring(0, 10);
        // Picking a calendar date means "date only": drop any stored instant.
        if (key == 'inquiry_date') {
          data['inquiry_precision'] = 'date';
          data['inquired_at'] = null;
          data['inquiry_utc_offset_minutes'] = null;
        }
      });
    }
  }

  Widget _dateField(String key, String label, {bool clearable = false}) =>
      InkWell(
        onTap: () => _date(key),
        child: InputDecorator(
          decoration: InputDecoration(
            labelText: label,
            suffixIcon: clearable && data[key] != null
                ? IconButton(
                    tooltip: '清除',
                    icon: const Icon(Icons.close, size: 16),
                    onPressed: () => setState(() => data[key] = null),
                  )
                : const Icon(Icons.calendar_today_outlined, size: 16),
          ),
          child: Text(
            data[key] as String? ?? '未填',
            style: TextStyle(
              color: data[key] == null ? Tokens.ink3 : Tokens.ink,
            ),
          ),
        ),
      );

  void _save() {
    final payload = {...data};
    for (final e in c.entries) {
      final v = e.value.text.trim().replaceAll(',', '');
      payload[e.key] = v.isEmpty
          ? null
          : (const {'lead_time_days', 'warranty_months'}.contains(e.key)
                ? int.tryParse(v) ?? v
                : v);
    }
    payload['min_qty'] ??= '1';
    final missing = [
      if (payload['supplier_id'] == null) '供应商',
      if (payload['product_id'] == null) '物料',
      if (payload['project_id'] == null) '项目',
      if (payload['price'] == null) '单价',
      if (payload['inquirer_name'] == null) '询价人',
    ];
    if (missing.isNotEmpty) {
      return setState(() => error = '还需要填写：${missing.join('、')}');
    }
    final err = widget.state.write(
      (s) => s.save('quotation', payload, id: widget.id),
    );
    if (err != null) return setState(() => error = err);
    Navigator.pop(context);
  }

  /// Choosing a contact copies their details into the quotation, so later
  /// edits to the contact never rewrite what was recorded here.
  Widget _contactPicker() {
    final supplierId = data['supplier_id'] as String?;
    final contacts = supplierId == null
        ? <Hit>[]
        : store.contactsOf(supplierId);
    final current = contacts.any((c) => c.id == data['contact_id'])
        ? data['contact_id'] as String?
        : null;
    return DropdownButtonFormField<String?>(
      key: ValueKey('contact-$supplierId'),
      initialValue: current,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: '联系人（可选）',
        helperText: supplierId != null && contacts.isEmpty
            ? '这个供应商还没有联系人，可在"供应商"中添加'
            : null,
      ),
      items: [
        const DropdownMenuItem(value: null, child: Text('不指定')),
        for (final c in contacts)
          DropdownMenuItem(
            value: c.id,
            child: Text(
              [
                c.data['name'],
                c.data['phone'] ?? c.data['wechat'] ?? c.data['email'],
              ].whereType<String>().join('  '),
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
      onChanged: (id) => setState(() {
        final c = contacts.where((c) => c.id == id).firstOrNull?.data;
        data['contact_id'] = id;
        data['contact_snapshot'] = c == null
            ? null
            : {
                for (final k in ['name', 'phone', 'wechat', 'email']) k: c[k],
              };
      }),
    );
  }

  Widget _text(String key, String label, {String? hint, bool number = false}) =>
      TextField(
        controller: c[key],
        decoration: InputDecoration(labelText: label, hintText: hint),
        keyboardType: number
            ? const TextInputType.numberWithOptions(decimal: true)
            : null,
      );

  Widget _pair(Widget a, Widget b) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Row(
      children: [
        Expanded(child: a),
        const SizedBox(width: 12),
        Expanded(child: b),
      ],
    ),
  );

  Widget _group(String title) => Padding(
    padding: const EdgeInsets.only(top: 4, bottom: 8),
    child: Text(
      title,
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: Tokens.ink2,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => SaveKeys(
    onSave: _save,
    child: AlertDialog(
      title: Text(widget.id == null ? '新建报价' : '编辑报价'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              _group('报价内容'),
              _pair(
                _picker('supplier', 'supplier_id', '供应商'),
                _picker('product', 'product_id', '物料'),
              ),
              _contactPicker(),
              const SizedBox(height: 12),
              _pair(
                _text('price', '单价', number: true),
                _text('unit_snapshot', '单位'),
              ),
              _pair(
                DropdownButtonFormField<String>(
                  initialValue: data['tax_mode'] as String,
                  decoration: const InputDecoration(labelText: '价格口径'),
                  items: const [
                    DropdownMenuItem(value: 'included', child: Text('含税')),
                    DropdownMenuItem(value: 'excluded', child: Text('不含税')),
                    DropdownMenuItem(
                      value: 'unknown',
                      child: Text('未知（不参与比价）'),
                    ),
                  ],
                  onChanged: (v) => setState(() => data['tax_mode'] = v),
                ),
                _text('tax_rate', '税率 %', number: true),
              ),
              DropdownButtonFormField<String?>(
                initialValue: data['price_basis'] as String?,
                decoration: const InputDecoration(labelText: '价格性质'),
                items: const [
                  DropdownMenuItem(value: null, child: Text('正式报价（书面报价单等）')),
                  DropdownMenuItem(
                    value: 'verbal',
                    child: Text('口头询价（仅参考，不用于预算）'),
                  ),
                  DropdownMenuItem(
                    value: 'reference',
                    child: Text('网上或第三方参考价（不用于预算）'),
                  ),
                ],
                onChanged: (v) => setState(() => data['price_basis'] = v),
              ),
              const SizedBox(height: 12),
              _pair(
                _text('min_qty', '起订量', number: true),
                _text('lead_time_days', '交期（天）', number: true),
              ),
              _group('询价信息'),
              _pair(
                _picker('project', 'project_id', '项目'),
                _text('inquirer_name', '询价人'),
              ),
              _pair(
                _dateField('inquiry_date', '询价日期'),
                _text('inquiry_location', '询价地点'),
              ),
              _group('报价范围'),
              IncludesPicker(
                value: (data['includes'] as List?)?.cast<String>(),
                onChanged: (v) => setState(() => data['includes'] = v),
              ),
              const SizedBox(height: 12),
              _pair(
                _text('extra_cost', '附加费用（合计，如运费）', number: true),
                _text('warranty_months', '质保（月）', number: true),
              ),
              _group('有效期与备注'),
              _pair(
                _dateField('quoted_on', '报价日期'),
                _dateField('valid_until', '有效期至', clearable: true),
              ),
              _text('notes', '备注'),
              const SizedBox(height: 12),
              AttachmentsField(
                state: widget.state,
                ids: ((data['attachment_ids'] as List?) ?? const [])
                    .cast<String>(),
                onChanged: (v) => setState(
                  () => data['attachment_ids'] = v.isEmpty ? null : v,
                ),
              ),
              if (data['awarded_on'] != null) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
                  decoration: BoxDecoration(
                    color: Tokens.accentTint,
                    borderRadius: BorderRadius.circular(Tokens.radius),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.verified_outlined, color: Tokens.accentDeep),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '已于 ${data['awarded_on']} 定标，成交单价 ${data['deal_price']}'
                          '${data['award_note'] == null ? '' : '：${data['award_note']}'}',
                        ),
                      ),
                      TextButton(
                        onPressed: () {
                          final err = widget.state.write(
                            (s) => s.withdrawAward(widget.id!),
                          );
                          if (err != null) return setState(() => error = err);
                          Navigator.pop(context);
                        },
                        child: const Text('撤销定标'),
                      ),
                    ],
                  ),
                ),
              ],
              if (error != null) ...[
                const SizedBox(height: 12),
                Text(error!, style: TextStyle(color: Tokens.red)),
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
        FilledButton(onPressed: _save, child: const Text('保存报价')),
      ],
    ),
  );
}
