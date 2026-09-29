import 'package:flutter/material.dart';

import 'package:supplier_core/supplier_core.dart';

import '../../app/theme.dart';

/// Edits one recognised offer before it is reviewed again.
class OfferForm extends StatefulWidget {
  const OfferForm({super.key, required this.offer});
  final Offer offer;

  @override
  State<OfferForm> createState() => _OfferFormState();
}

class _OfferFormState extends State<OfferForm> {
  late final c = {
    for (final k in offerFields.keys)
      if (k != 'tax_mode') k: TextEditingController(text: widget.offer[k]),
  };
  late String taxMode = widget.offer['tax_mode'] ?? 'unknown';
  String? error;

  @override
  void dispose() {
    for (final x in c.values) {
      x.dispose();
    }
    super.dispose();
  }

  String? _problem(Offer o) {
    bool bad(String k, bool Function(String) ok) => o[k] != null && !ok(o[k]!);
    bool isDate(String s) => RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(s);
    if (bad('price', (s) => parsePrice(s) != null)) return '单价应为数字';
    if (bad('tax_rate', (s) => parsePrice(s.replaceAll('%', '')) != null)) {
      return '税率应为数字';
    }
    if (bad('quoted_on', isDate) || bad('valid_until', isDate)) {
      return '日期格式为 2026-09-30';
    }
    if (bad('lead_time_days', (s) => int.tryParse(s) != null)) {
      return '交期填天数';
    }
    if (o['quoted_on'] != null &&
        o['valid_until'] != null &&
        o['valid_until']!.compareTo(o['quoted_on']!) < 0) {
      return '有效期不能早于报价日期';
    }
    return null;
  }

  void _save() {
    final raw = <String, String?>{
      for (final e in c.entries)
        e.key: e.value.text.trim().isEmpty ? null : e.value.text.trim(),
      'tax_mode': taxMode,
    };
    final problem = _problem(raw);
    if (problem != null) return setState(() => error = problem);
    Navigator.pop(context, cleanOffer(raw));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('修改报价信息'),
    content: SizedBox(
      width: 560,
      child: SingleChildScrollView(
        child: Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (final MapEntry(key: k, value: (label, _))
                in offerFields.entries)
              if (k == 'tax_mode')
                SizedBox(
                  width: 170,
                  child: DropdownButtonFormField<String>(
                    initialValue: taxMode,
                    decoration: InputDecoration(labelText: label),
                    items: [
                      for (final e in taxModeLabels.entries)
                        DropdownMenuItem(value: e.key, child: Text(e.value)),
                    ],
                    onChanged: (v) => setState(() => taxMode = v!),
                  ),
                )
              else
                SizedBox(
                  width: const {'specification', 'notes'}.contains(k)
                      ? 540
                      : 170,
                  child: TextField(
                    controller: c[k],
                    maxLines: const {'specification', 'notes'}.contains(k)
                        ? 3
                        : 1,
                    decoration: InputDecoration(labelText: label),
                  ),
                ),
            if (error != null)
              Text(error!, style: TextStyle(color: Tokens.red)),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(onPressed: _save, child: const Text('保存')),
    ],
  );
}
