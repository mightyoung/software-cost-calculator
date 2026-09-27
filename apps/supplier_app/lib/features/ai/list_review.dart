import 'package:flutter/material.dart';
import 'package:supplier_core/supplier_core.dart';

import '../../app/app_state.dart';
import '../../app/format.dart';
import '../../app/theme.dart';
import '../../widgets/draft_frame.dart';
import '../../widgets/ledger.dart';
import '../projects/project_form.dart';

enum _Filter { all, matched, attention, inquiry }

/// Mutable review state for one proposed line; the core proposal stays
/// immutable and is rebuilt on "generate".
class _Row {
  _Row(this.line)
    : productId = line.productId,
      qty = TextEditingController(text: _leadingNumber(line.item.qty) ?? '');
  final ProposedLine line;
  String? productId;
  final TextEditingController qty;

  bool get changedByUser => productId != line.productId;

  /// Untouched auto-filled quantity passes the list's original text on, so
  /// the core keeps "清单原文数量：约300" in the notes; a number the user typed
  /// is an explicit decision and is used as is.
  String? get quantityText {
    final typed = qty.text.trim();
    if (typed.isEmpty || typed == _leadingNumber(line.item.qty)) {
      return line.item.qty;
    }
    return typed;
  }

  bool get qtyUncertain =>
      _leadingNumber(line.item.qty) != line.item.qty?.trim();
  bool get attention =>
      productId == null ||
      qtyUncertain ||
      (!changedByUser && line.confidence != 'high');
}

/// First number in the list's quantity text ("约300" -> 300), as the core does.
String? _leadingNumber(String? raw) => RegExp(
  r'[0-9][0-9,]*(?:\.[0-9]+)?',
).firstMatch(raw ?? '')?[0]?.replaceAll(',', '');

class ListReview extends StatefulWidget {
  const ListReview({
    super.key,
    required this.state,
    required this.source,
    required this.sourceName,
    required this.lines,
    required this.currency,
    required this.taxMode,
    required this.onBack,
  });
  final AppState state;
  final String source;
  final String? sourceName;
  final List<ProposedLine> lines;
  final String currency, taxMode;
  final VoidCallback onBack;

  @override
  State<ListReview> createState() => _ListReviewState();
}

class _ListReviewState extends State<ListReview> {
  late final rows = [for (final l in widget.lines) _Row(l)];
  late final code = TextEditingController(
    text: suggestProjectCode(widget.state),
  );
  final name = TextEditingController();
  final customer = TextEditingController();
  final markup = TextEditingController(text: '0');
  var filter = _Filter.all;
  int? focused;
  String? error;

  Store get store => widget.state.store;

  @override
  void dispose() {
    for (final c in [code, name, customer, markup, ...rows.map((r) => r.qty)]) {
      c.dispose();
    }
    super.dispose();
  }

  QuoteOption? _best(_Row r) {
    final productId = r.productId;
    if (productId == null) return null;
    final o = store.quoteOptionsFor(
      productId,
      currency: widget.currency,
      taxMode: widget.taxMode,
      qty: parseQty(r.quantityText).$1,
    );
    return o.isNotEmpty && o.first.valid ? o.first : null;
  }

  void _generate() {
    if (name.text.trim().isEmpty) return setState(() => error = '填写项目名称');
    final lines = [
      for (final r in rows)
        ProposedLine(
          RequestedItem(
            r.line.item.name,
            r.line.item.requirements,
            r.quantityText,
            r.line.item.unit,
            r.line.item.keywords,
          ),
          r.line.candidates,
          productId: r.productId,
          confidence: r.line.confidence,
          reason: r.line.reason,
          quote: _best(r),
        ),
    ];
    late String id;
    final err = widget.state.write(
      (s) => id = s.createProjectFromProposal({
        for (final f in Project.fields) f: null,
        'code': code.text.trim(),
        'name': name.text.trim(),
        'customer': customer.text.trim().isEmpty ? null : customer.text.trim(),
        'status': 'active',
        'currency': widget.currency,
        'tax_mode': widget.taxMode,
        'markup_rate': markup.text.trim().isEmpty ? '0' : markup.text.trim(),
      }, lines),
    );
    if (err != null) return setState(() => error = err);
    Navigator.of(context).pop(id);
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 1024;
    int count(bool Function(_Row) test) => rows.where(test).length;
    final shown = [
      for (var i = 0; i < rows.length; i++)
        if (switch (filter) {
          _Filter.all => true,
          _Filter.matched => rows[i].productId != null,
          _Filter.attention => rows[i].attention,
          _Filter.inquiry => rows[i].productId == null,
        })
          i,
    ];
    final attention = count((r) => r.attention);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
          child: Text(
            '虚线框内是尚未确认的建议，确认前不会写入任何数据。匹配时只发送了物料名称与规格，没有发送价格。',
            style: const TextStyle(color: Tokens.ink2),
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (wide) ...[
                  SizedBox(width: 280, child: _source()),
                  const SizedBox(width: 16),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final (f, label, n) in [
                            (_Filter.all, '全部', rows.length),
                            (
                              _Filter.matched,
                              '已匹配',
                              count((r) => r.productId != null),
                            ),
                            (_Filter.attention, '需确认', attention),
                            (
                              _Filter.inquiry,
                              '待询价',
                              count((r) => r.productId == null),
                            ),
                          ])
                            ChoiceChip(
                              label: Text('$label $n'),
                              selected: filter == f,
                              showCheckmark: false,
                              onSelected: (_) => setState(() => filter = f),
                            ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Expanded(
                        child: DraftFrame(
                          child: ColoredBox(
                            color: Tokens.surface,
                            child: ListView.separated(
                              itemCount: shown.length,
                              separatorBuilder: (_, _) => const Divider(),
                              itemBuilder: (context, k) =>
                                  _rowView(shown[k], wide),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        _footer(attention, wide),
      ],
    );
  }

  Widget _source() {
    final sourceLines = widget.source.split('\n');
    final needle = focused == null ? null : rows[focused!].line.item.name;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Tokens.surface,
        border: Border.all(color: Tokens.rule),
        borderRadius: BorderRadius.circular(Tokens.radius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            color: Tokens.sunken,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Text(
              '清单原文${widget.sourceName == null ? '' : ' · ${widget.sourceName}'}',
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Tokens.ink2,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: sourceLines.length,
              itemBuilder: (context, i) {
                final hit =
                    needle != null &&
                    sourceLines[i].contains(needle.split(RegExp(r'\s')).first);
                return Container(
                  color: hit ? Tokens.accentTint : null,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 4,
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 26,
                        child: Text(
                          '${i + 1}',
                          style: const TextStyle(
                            fontSize: 11,
                            color: Tokens.ink3,
                          ),
                        ),
                      ),
                      Expanded(
                        child: Text(
                          sourceLines[i],
                          style: const TextStyle(fontSize: 13, height: 1.5),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _rowView(int i, bool wide) {
    final r = rows[i];
    final item = r.line.item;
    final best = _best(r);
    final (confText, confColor, confIcon) = r.productId == null
        ? ('无匹配', Tokens.red, Icons.cancel_outlined)
        : r.changedByUser
        ? ('已手动选择', Tokens.accentDeep, Icons.check_circle_outline)
        : switch (r.line.confidence) {
            'high' => ('高', Tokens.accentDeep, Icons.check_circle_outline),
            'medium' => ('中', Tokens.amber, Icons.error_outline),
            _ => ('低', Tokens.red, Icons.cancel_outlined),
          };
    final request = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(item.name, style: const TextStyle(fontWeight: FontWeight.w500)),
        if (item.requirements != null)
          Text(
            item.requirements!,
            style: const TextStyle(fontSize: 12, color: Tokens.ink3),
          ),
      ],
    );
    final picker = DropdownButtonFormField<String?>(
      initialValue: r.productId,
      isExpanded: true,
      style: Theme.of(
        context,
      ).textTheme.bodyMedium!.copyWith(color: Tokens.ink),
      decoration: const InputDecoration(
        contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      ),
      items: [
        for (final h in r.line.candidates)
          DropdownMenuItem(
            value: h.id,
            child: Text(
              [
                h.data['name'],
                h.data['model'],
                h.data['specification'],
              ].whereType<String>().join(' · '),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        const DropdownMenuItem(value: null, child: Text('作为待询价（不关联物料）')),
      ],
      onChanged: (v) => setState(() => r.productId = v),
    );
    final confidence = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(confIcon, size: 14, color: confColor),
            const SizedBox(width: 4),
            Text(confText, style: TextStyle(fontSize: 12, color: confColor)),
          ],
        ),
        if (r.line.reason != null && !r.changedByUser)
          Text(
            r.line.reason!,
            style: const TextStyle(fontSize: 12, color: Tokens.ink3),
          ),
      ],
    );
    final price = Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text(
          best == null
              ? '—'
              : '${money(best.price)}${best.converted ? '（口径折算）' : ''}',
          style: const TextStyle(fontFeatures: tabular),
        ),
        if (best != null)
          Text(
            '${store.get('supplier', best.data['supplier_id']! as String)?.data['name'] ?? ''}${best.validityPending ? ' · 有效期待确认' : ''}',
            style: const TextStyle(fontSize: 12, color: Tokens.ink3),
            textAlign: TextAlign.right,
          ),
      ],
    );
    final qty = Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        TextField(
          controller: r.qty,
          textAlign: TextAlign.right,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
            suffixText: item.unit,
            hintText: '数量',
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 8,
              vertical: 8,
            ),
          ),
          onChanged: (_) => setState(() {}),
        ),
        if (r.qtyUncertain)
          Text(
            '原文"${item.qty ?? '未写'}"',
            style: const TextStyle(fontSize: 12, color: Tokens.amber),
          ),
      ],
    );
    final body = wide
        ? Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(flex: 3, child: request),
              const SizedBox(width: 12),
              Expanded(flex: 4, child: picker),
              const SizedBox(width: 12),
              SizedBox(width: 150, child: confidence),
              const SizedBox(width: 12),
              SizedBox(width: 130, child: price),
              const SizedBox(width: 12),
              SizedBox(width: 110, child: qty),
            ],
          )
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              request,
              const SizedBox(height: 8),
              picker,
              const SizedBox(height: 8),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: confidence),
                  price,
                  const SizedBox(width: 12),
                  SizedBox(width: 110, child: qty),
                ],
              ),
            ],
          );
    return InkWell(
      onTap: () => setState(() => focused = i),
      child: Container(
        decoration: BoxDecoration(
          border: r.attention
              ? const Border(left: BorderSide(color: Tokens.amber, width: 3))
              : null,
        ),
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: body,
      ),
    );
  }

  Widget _footer(int attention, bool wide) {
    Widget field(TextEditingController c, String label, double width) =>
        SizedBox(
          width: width,
          child: TextField(
            controller: c,
            decoration: InputDecoration(labelText: label),
          ),
        );
    return Container(
      margin: const EdgeInsets.fromLTRB(20, 12, 20, 16),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Tokens.surface,
        border: Border.all(color: Tokens.rule),
        borderRadius: BorderRadius.circular(Tokens.radius),
      ),
      child: Wrap(
        spacing: 10,
        runSpacing: 10,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          field(code, '项目编号', 150),
          field(name, '项目名称', 200),
          field(customer, '客户', 150),
          field(markup, '加价率 %', 90),
          if (attention > 0)
            HintText('$attention 项需确认', icon: Icons.warning_amber_rounded),
          if (error != null)
            Text(error!, style: const TextStyle(color: Tokens.red)),
          OutlinedButton(onPressed: widget.onBack, child: const Text('返回修改清单')),
          FilledButton.icon(
            onPressed: _generate,
            icon: const Icon(Icons.check, size: 18),
            label: Text('生成项目（${rows.length} 项）'),
          ),
        ],
      ),
    );
  }
}
