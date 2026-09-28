import 'package:flutter/material.dart';
import 'package:supplier_core/supplier_core.dart';

import '../../app/app_state.dart';
import '../../app/theme.dart';
import '../quotes/quote_extras.dart';

/// Records or revises one supplier's quotation for one inquiry line.
Future<void> showInquiryCell(
  BuildContext context,
  AppState state, {
  required String inquiryId,
  required String itemId,
  required String supplierId,
  Map<String, Object?>? current,
}) => showDialog(
  context: context,
  builder: (_) => _CellDialog(
    state: state,
    inquiryId: inquiryId,
    itemId: itemId,
    supplierId: supplierId,
    current: current,
  ),
);

class _CellDialog extends StatefulWidget {
  const _CellDialog({
    required this.state,
    required this.inquiryId,
    required this.itemId,
    required this.supplierId,
    this.current,
  });
  final AppState state;
  final String inquiryId, itemId, supplierId;
  final Map<String, Object?>? current;

  @override
  State<_CellDialog> createState() => _CellDialogState();
}

class _CellDialogState extends State<_CellDialog> {
  static const _texts = [
    ('price', '单价'),
    ('tax_rate', '税率 %'),
    ('extra_cost', '附加费用（合计）'),
    ('lead_time_days', '交期（天）'),
    ('warranty_months', '质保（月）'),
    ('notes', '备注'),
  ];
  final c = <String, TextEditingController>{};
  late final inquirer = TextEditingController(
    text: widget.state.setting('inquirer') ?? '',
  );
  late String taxMode = widget.current?['tax_mode'] as String? ?? 'included';
  late List<String>? includes = (widget.current?['includes'] as List?)
      ?.cast<String>();
  late String? validUntil = widget.current?['valid_until'] as String?;
  late List<String> attachments =
      ((widget.current?['attachment_ids'] as List?) ?? const []).cast<String>();
  String? error;

  @override
  void initState() {
    super.initState();
    for (final (k, _) in _texts) {
      final v = widget.current?[k];
      c[k] = TextEditingController(text: v == null ? '' : '$v');
    }
  }

  @override
  void dispose() {
    for (final x in [...c.values, inquirer]) {
      x.dispose();
    }
    super.dispose();
  }

  String? _t(String k) {
    final v = c[k]!.text.trim().replaceAll(',', '');
    return v.isEmpty ? null : v;
  }

  void _save() {
    final price = tryDecimal(_t('price'), positive: true);
    if (price == null) return setState(() => error = '单价应为大于 0 的数字');
    if (inquirer.text.trim().isEmpty) return setState(() => error = '填写询价人');
    int? whole(String k) => _t(k) == null ? null : int.tryParse(_t(k)!);
    for (final k in ['lead_time_days', 'warranty_months']) {
      if (_t(k) != null && whole(k) == null) {
        return setState(() => error = '交期和质保请填整数');
      }
    }
    final err = widget.state.write(
      (s) => s.quoteForInquiry(
        widget.inquiryId,
        widget.itemId,
        widget.supplierId,
        price: price,
        context: (inquirer: inquirer.text.trim(), asOf: null),
        taxMode: taxMode,
        taxRate: _t('tax_rate'),
        extraCost: _t('extra_cost'),
        includes: includes,
        leadTimeDays: whole('lead_time_days'),
        validUntil: validUntil,
        warrantyMonths: whole('warranty_months'),
        notes: _t('notes'),
        attachmentIds: attachments.isEmpty ? null : attachments,
      ),
    );
    if (err != null) return setState(() => error = err);
    widget.state.saveSetting('inquirer', inquirer.text.trim());
    Navigator.pop(context);
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime.tryParse(validUntil ?? '') ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null) setState(() => validUntil = localDay(picked));
  }

  @override
  Widget build(BuildContext context) {
    final store = widget.state.store;
    final supplier = store.get('supplier', widget.supplierId)?.data['name'];
    final item = store.get('project_item', widget.itemId)!.data;
    final name = item['product_id'] == null
        ? item['name']
        : store.get('product', item['product_id']! as String)?.data['name'];
    Widget field(String k, String label) => TextField(
      controller: c[k],
      keyboardType: k == 'notes'
          ? null
          : const TextInputType.numberWithOptions(decimal: true),
      decoration: InputDecoration(labelText: label),
    );
    Widget pair(Widget a, Widget b) => Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Expanded(child: a),
          const SizedBox(width: 12),
          Expanded(child: b),
        ],
      ),
    );
    return AlertDialog(
      title: Text('$supplier · $name'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              pair(
                field('price', '单价（每${item['unit']}）'),
                DropdownButtonFormField<String>(
                  initialValue: taxMode,
                  decoration: const InputDecoration(labelText: '价格口径'),
                  items: [
                    for (final e in taxModeLabels.entries)
                      DropdownMenuItem(value: e.key, child: Text(e.value)),
                  ],
                  onChanged: (v) => setState(() => taxMode = v!),
                ),
              ),
              pair(field('tax_rate', '税率 %'), field('extra_cost', '附加费用（合计）')),
              pair(
                field('lead_time_days', '交期（天）'),
                field('warranty_months', '质保（月）'),
              ),
              InkWell(
                onTap: _pickDate,
                child: InputDecorator(
                  decoration: const InputDecoration(labelText: '有效期至'),
                  child: Text(
                    validUntil ?? '未填',
                    style: TextStyle(
                      color: validUntil == null ? Tokens.ink3 : Tokens.ink,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              IncludesPicker(
                value: includes,
                onChanged: (v) => setState(() => includes = v),
              ),
              const SizedBox(height: 12),
              pair(
                field('notes', '备注'),
                TextField(
                  controller: inquirer,
                  decoration: const InputDecoration(labelText: '询价人'),
                ),
              ),
              AttachmentsField(
                state: widget.state,
                ids: attachments,
                onChanged: (v) => setState(() => attachments = v),
              ),
              if (error != null) ...[
                const SizedBox(height: 10),
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
    );
  }
}
