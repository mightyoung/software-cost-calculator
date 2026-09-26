import 'package:flutter/material.dart';
import 'package:supplier_core/supplier_core.dart';

import '../../app/app_state.dart';
import '../../app/format.dart';
import '../../app/theme.dart';

typedef AwardChoice = ({String quotationId, String label});

/// Picks the winning quotation, the agreed unit price and the reason. With
/// [itemId] the budget line is priced with the award. Returns true when
/// awarded.
Future<bool> showAwardDialog(
  BuildContext context,
  AppState state, {
  required List<AwardChoice> choices,
  String? initial,
  String? itemId,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (_) => _AwardDialog(
        state: state,
        choices: choices,
        initial: initial ?? choices.first.quotationId,
        itemId: itemId,
      ),
    ) ??
    false;

/// The budget line of the quotation's project that uses the same material.
String? budgetLineFor(Store store, Map<String, Object?> quote) {
  final projectId = quote['project_id'] as String?;
  if (projectId == null) return null;
  for (final l in store.budget(projectId, withWarnings: false).lines) {
    if (l.data['product_id'] == quote['product_id']) return l.id;
  }
  return null;
}

class _AwardDialog extends StatefulWidget {
  const _AwardDialog({
    required this.state,
    required this.choices,
    required this.initial,
    this.itemId,
  });
  final AppState state;
  final List<AwardChoice> choices;
  final String initial;
  final String? itemId;

  @override
  State<_AwardDialog> createState() => _AwardDialogState();
}

class _AwardDialogState extends State<_AwardDialog> {
  late String chosen = widget.initial;
  late final deal = TextEditingController(text: _price(widget.initial));
  final note = TextEditingController();
  String? error;

  String _price(String id) =>
      widget.state.store.get('quotation', id)!.data['price']! as String;

  @override
  void dispose() {
    deal.dispose();
    note.dispose();
    super.dispose();
  }

  void _save() {
    final price = tryDecimal(deal.text.replaceAll(',', ''), positive: true);
    if (price == null) return setState(() => error = '成交单价应为大于 0 的数字');
    final err = widget.state.write(
      (s) => s.award(
        chosen,
        itemId: widget.itemId,
        dealPrice: price,
        note: note.text.trim().isEmpty ? null : note.text.trim(),
      ),
    );
    if (err != null) return setState(() => error = err);
    Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('定标'),
    content: SizedBox(
      width: 460,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.choices.length > 1)
            RadioGroup<String>(
              groupValue: chosen,
              onChanged: (v) => setState(() {
                chosen = v!;
                deal.text = _price(v);
              }),
              child: Column(
                children: [
                  for (final c in widget.choices)
                    RadioListTile<String>(
                      value: c.quotationId,
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text(c.label),
                    ),
                ],
              ),
            )
          else
            Text(widget.choices.single.label),
          const SizedBox(height: 12),
          TextField(
            controller: deal,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              labelText: '成交单价',
              helperText: '谈判后的价格；默认等于报价',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: note,
            decoration: const InputDecoration(
              labelText: '定标理由',
              hintText: '例如 含税价最低、交期最短、含安装调试',
            ),
          ),
          if (widget.itemId != null) ...[
            const SizedBox(height: 10),
            const Text(
              '确认后，预算中这一行的成本单价会改为成交单价。',
              style: TextStyle(fontSize: 12, color: Tokens.ink3),
            ),
          ],
          if (error != null) ...[
            const SizedBox(height: 10),
            Text(error!, style: const TextStyle(color: Tokens.red)),
          ],
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context, false),
        child: const Text('取消'),
      ),
      FilledButton(onPressed: _save, child: const Text('确认定标')),
    ],
  );
}

/// "甲泵业 · ¥3,200.00 / 台"
String quoteLabel(Store store, Map<String, Object?> q, {String? effective}) {
  final supplier = store.get('supplier', q['supplier_id']! as String)?.data;
  final prefix = q['currency'] == 'CNY' ? '¥' : '${q['currency']} ';
  return [
    supplier?['name'] ?? '未知供应商',
    '${money(q['price'] as String?, prefix: prefix)} / ${q['unit_snapshot']}',
    if (effective != null && effective != q['price'])
      '有效单价 ${money(effective, prefix: prefix)}',
  ].join(' · ');
}
