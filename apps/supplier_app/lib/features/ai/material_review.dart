import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:supplier_core/supplier_core.dart';

import '../../app/app_state.dart';
import '../../app/format.dart';
import '../../app/theme.dart';
import '../../widgets/draft_frame.dart';
import '../../widgets/ledger.dart';
import '../projects/project_form.dart';

// Compare complete numeric tokens without losing the original highlight span.
// String canonicalization avoids rounding long amounts through a double.
String? _canonicalNumber(String value) {
  if (!RegExp(r'^[+-]?(?:\d+|\d{1,3}(?:,\d{3})+)(?:\.\d+)?$').hasMatch(value)) {
    return null;
  }
  var number = value.replaceAll(',', '');
  final negative = number.startsWith('-');
  number = number.replaceFirst(RegExp(r'^[+-]'), '');
  final parts = number.split('.');
  final whole = parts.first.replaceFirst(RegExp(r'^0+(?=\d)'), '');
  final fraction = parts.length == 1
      ? ''
      : parts.last.replaceFirst(RegExp(r'0+$'), '');
  final zero = whole == '0' && fraction.isEmpty;
  return '${negative && !zero ? '-' : ''}$whole${fraction.isEmpty ? '' : '.$fraction'}';
}

({int start, int end})? _sourceMatch(
  String source,
  String field,
  String value,
) {
  if (!const {'price', 'qty', 'tax_rate', 'lead_time_days'}.contains(field)) {
    final at = source.indexOf(value);
    return at < 0 ? null : (start: at, end: at + value.length);
  }
  final wanted = _canonicalNumber(value.replaceFirst(RegExp(r'%$'), ''));
  if (wanted == null) return null;
  for (final token in RegExp(
    r'[+-]?\d+(?:[,.]\d+)*(?:[eE][+-]?\d+)?(?:万|千|亿)?',
  ).allMatches(source)) {
    // Do not treat model/identifier digits as a standalone numeric amount.
    if (token.start > 0 &&
        RegExp(r'[A-Za-z0-9_.]').hasMatch(source[token.start - 1])) {
      continue;
    }
    if (token.end < source.length &&
        RegExp(r'[A-Za-z0-9_]').hasMatch(source[token.end])) {
      continue;
    }
    if (_canonicalNumber(token.group(0)!) == wanted) {
      return (start: token.start, end: token.end);
    }
  }
  return null;
}

/// Mutable review state for one offer; the plan itself stays immutable and
/// is replaced when the offer is edited.
class _Row {
  _Row(this.plan)
    : supplierId = plan.supplierId,
      productId = plan.productId,
      include = plan.error == null;
  OfferPlan plan;
  String? supplierId, productId;
  bool include;
  Offer get offer => plan.offer;
  bool get ready => include && plan.error == null;
}

class MaterialReview extends StatefulWidget {
  const MaterialReview({
    super.key,
    required this.state,
    required this.plans,
    required this.onBack,
    this.projectId,
    this.source,
    this.masterData = false,
  });
  final AppState state;

  /// Importing a material list: only suppliers, contacts and materials are
  /// created, so no project or inquirer is asked for.
  final bool masterData;
  final List<OfferPlan> plans;

  /// Kept as an attachment on every new quotation.
  final ({String name, List<int> bytes})? source;
  final String? projectId;
  final VoidCallback onBack;

  @override
  State<MaterialReview> createState() => _MaterialReviewState();
}

class _MaterialReviewState extends State<MaterialReview> {
  late final rows = [for (final p in widget.plans) _Row(p)];
  late final projects = store.searchByName('project', '', limit: 500);
  late String? projectId =
      widget.projectId ?? (projects.isEmpty ? null : projects.first.id);
  late bool newProject = projects.isEmpty;
  late final TextEditingController code, inquirer;
  final name = TextEditingController();
  var addToBudget = true;
  String? error;

  Store get store => widget.state.store;

  late final String? sourceText = _readSource();

  String? _readSource() {
    final source = widget.source;
    if (source == null) return null;
    try {
      return source.name.toLowerCase().endsWith('.xlsx')
          ? workbookText(readXlsx(Uint8List.fromList(source.bytes)))
          : utf8.decode(source.bytes);
    } catch (_) {
      return null;
    }
  }

  void _showSource(String field, String value) {
    if (field == 'tax_mode') value = taxModeLabels[value] ?? value;
    final original = sourceText;
    final match = original == null
        ? null
        : _sourceMatch(original, field, value);
    final at = match?.start ?? -1;
    final matchEnd = match?.end ?? 0;
    // Keep the match visible even in a long workbook or pasted conversation.
    final start = at < 0 || at < 160 ? 0 : at - 160;
    final end = at < 0
        ? (original?.length ?? 0)
        : (matchEnd + 160).clamp(0, original!.length);
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('${offerFields[field]!.$1} · 核对原文'),
        content: SizedBox(
          width: 600,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('识别结果：$value'),
                const SizedBox(height: 8),
                Text(widget.source!.name, style: TextStyle(color: Tokens.ink3)),
                const SizedBox(height: 12),
                if (original == null)
                  const Text('无法显示这份附件的原文，请返回查看原始文件后核对。')
                else if (at < 0) ...[
                  Text(
                    '未找到完全相同的原文，可能经过格式整理或人工修改。请核对以下原文，必要时修改识别结果。',
                    style: TextStyle(color: Tokens.amber),
                  ),
                  const SizedBox(height: 12),
                  SelectableText(original),
                ] else ...[
                  Text(
                    '高亮为原文中的匹配内容；仍需核对它是否属于当前报价。',
                    style: TextStyle(color: Tokens.ink2),
                  ),
                  const SizedBox(height: 12),
                  SelectableText.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text:
                              '${start > 0 ? '…' : ''}${original.substring(start, at)}',
                        ),
                        TextSpan(
                          text: original.substring(at, matchEnd),
                          style: TextStyle(
                            backgroundColor: Tokens.amberBg,
                            color: Tokens.ink,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        TextSpan(
                          text:
                              '${original.substring(matchEnd, end)}${end < original.length ? '…' : ''}',
                        ),
                      ],
                    ),
                  ),
                  if (start > 0 || end < original.length)
                    ExpansionTile(
                      title: const Text('查看完整原文'),
                      children: [SelectableText(original)],
                    ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    code = TextEditingController(text: suggestProjectCode(widget.state));
    inquirer = TextEditingController(
      text: widget.state.setting('inquirer') ?? '',
    );
  }

  @override
  void dispose() {
    for (final c in [code, name, inquirer]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _edit(_Row r) async {
    final offer = await showDialog<Offer>(
      context: context,
      builder: (_) => _OfferForm(offer: r.offer),
    );
    if (offer == null) return;
    setState(() {
      // Edited by the user: their values need no source check.
      r.plan = store.planOffer(offer);
      r.supplierId = r.plan.supplierId;
      r.productId = r.plan.productId;
      r.include = r.plan.error == null;
    });
  }

  void _apply() {
    final ready = rows.where((r) => r.ready).toList();
    if (widget.masterData) return _applyMasterData(ready);
    final person = inquirer.text.trim();
    if (person.isEmpty) return setState(() => error = '填写询价人');
    if (newProject && name.text.trim().isEmpty) {
      return setState(() => error = '填写新项目名称');
    }
    if (!newProject && projectId == null) {
      return setState(() => error = '选择一个项目');
    }
    late ImportSummary sum;
    final err = widget.state.write(
      (s) => s.transaction(() {
        final pid = newProject
            ? s.save('project', {
                for (final f in Project.fields) f: null,
                'code': code.text.trim(),
                'name': name.text.trim(),
                'status': 'active',
                'currency': 'CNY',
                'tax_mode': 'included',
                'markup_rate': '0',
              })
            : projectId!;
        sum = s.applyOffers(
          [
            for (final r in ready)
              (
                offer: r.offer,
                supplierId: r.supplierId,
                productId: r.productId,
              ),
          ],
          projectId: pid,
          inquirer: person,
          addToBudget: addToBudget,
          source: widget.source,
        );
      }),
    );
    if (err != null) return setState(() => error = err);
    widget.state.saveSetting('inquirer', person);
    Navigator.of(context).pop(
      [
        '已导入 ${sum.quotations} 条报价',
        if (sum.duplicates > 0) '${sum.duplicates} 条已存在未重复写入',
        if (sum.suppliers > 0) '新建供应商 ${sum.suppliers}',
        if (sum.contacts > 0) '联系人 ${sum.contacts}',
        if (sum.products > 0) '物料 ${sum.products}',
        if (sum.items > 0) '加入预算 ${sum.items} 行',
      ].join('，'),
    );
  }

  void _applyMasterData(List<_Row> ready) {
    late ImportSummary sum;
    final err = widget.state.write(
      (s) => sum = s.applyOffers(
        [
          for (final r in ready)
            (offer: r.offer, supplierId: r.supplierId, productId: r.productId),
        ],
        projectId: null,
        inquirer: widget.state.deviceName,
      ),
    );
    if (err != null) return setState(() => error = err);
    Navigator.of(context).pop(
      [
        '新建物料 ${sum.products}',
        if (sum.suppliers > 0) '供应商 ${sum.suppliers}',
        if (sum.contacts > 0) '联系人 ${sum.contacts}',
      ].join('，'),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ready = rows.where((r) => r.ready).toList();
    final newSuppliers = {
      for (final r in ready)
        if (r.supplierId == null) ?r.offer['supplier'],
    }.length;
    final newProducts = ready.where((r) => r.productId == null).length;
    final priced = ready
        .where(
          (r) =>
              r.offer['price'] != null &&
              (r.supplierId != null || r.offer['supplier'] != null),
        )
        .length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(20, 4, 20, 8),
          child: Text(
            '虚线框内是 AI 整理出的内容，确认前不会写入。可以逐条修改，或改为对应本机已有的供应商和物料。',
            style: TextStyle(color: Tokens.ink2),
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: DraftFrame(
              child: Material(
                color: Tokens.surface,
                child: ListView.separated(
                  itemCount: rows.length,
                  separatorBuilder: (_, _) => const Divider(),
                  itemBuilder: (context, i) => _rowView(rows[i]),
                ),
              ),
            ),
          ),
        ),
        _footer(ready.length, priced, newSuppliers, newProducts),
      ],
    );
  }

  Widget _rowView(_Row r) {
    final o = r.offer;
    final wide = MediaQuery.sizeOf(context).width >= 760;
    final contact = [
      ?o['contact_name'],
      ?o['phone'],
      if (o['wechat'] != null) '微信 ${o['wechat']}',
      ?o['email'],
    ].join(' ');
    final tags = [
      if (r.plan.error != null)
        HintTag(r.plan.error!, icon: Icons.error_outline, tone: HintTone.error)
      else if (o['supplier'] == null && r.supplierId == null)
        const HintTag('没有供应商，只登记物料', icon: Icons.info_outline)
      else if (o['price'] == null)
        const HintTag('没有单价，只登记物料', icon: Icons.info_outline),
      if (o['price'] != null && o['tax_mode'] == 'unknown')
        const HintTag('含税口径未知', icon: Icons.help_outline),
      if (r.plan.unverified.isNotEmpty)
        HintTag(
          '原文中找不到：${r.plan.unverified.map((k) => offerFields[k]!.$1).join('、')}，请核对',
          icon: Icons.find_in_page_outlined,
          tone: HintTone.error,
        ),
    ];
    final price = Column(
      crossAxisAlignment: wide
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      children: [
        Text(
          o['price'] == null
              ? '—'
              : '${money(o['price'], prefix: o['currency'] == 'CNY' ? '¥' : '${o['currency']} ')} / ${o['unit'] ?? '?'}',
          style: const TextStyle(
            fontFeatures: tabular,
            fontWeight: FontWeight.w600,
          ),
        ),
        Text(
          [
            if (o['price'] != null) taxModeLabels[o['tax_mode']],
            if (o['qty'] != null) '数量 ${o['qty']}',
            if (o['valid_until'] != null) '有效至 ${o['valid_until']}',
          ].whereType<String>().join(' · '),
          style: TextStyle(fontSize: 12, color: Tokens.ink3),
        ),
      ],
    );
    final main = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          [o['name'], o['brand'], o['model']].whereType<String>().join(' · '),
          style: const TextStyle(fontWeight: FontWeight.w500),
        ),
        if (o['specification'] != null)
          Text(
            o['specification']!,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: Tokens.ink3),
          ),
        Text(
          [?o['supplier'], if (contact.isNotEmpty) contact].join(' · '),
          style: TextStyle(fontSize: 12, color: Tokens.ink2),
        ),
        if (!wide) ...[const SizedBox(height: 4), price],
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (o['supplier'] != null || r.plan.supplierCandidates.isNotEmpty)
              _picker(
                value: r.supplierId,
                newLabel: '新建供应商：${o['supplier'] ?? '（未识别）'}',
                candidates: r.plan.supplierCandidates,
                label: (d) => d['name']! as String,
                onChanged: (v) => setState(() => r.supplierId = v),
              ),
            _picker(
              value: r.productId,
              newLabel: '新建物料',
              candidates: r.plan.productCandidates,
              label: (d) => [
                d['name'],
                d['brand'],
                d['model'],
              ].whereType<String>().join(' · '),
              onChanged: (v) => setState(() => r.productId = v),
            ),
          ],
        ),
        if (tags.isNotEmpty) ...[
          const SizedBox(height: 6),
          Wrap(spacing: 6, runSpacing: 4, children: tags),
        ],
        if (widget.source != null)
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: const Text('核对字段原文', style: TextStyle(fontSize: 12)),
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final field in offerFields.keys)
                      if (o[field] != null && o[field]!.isNotEmpty)
                        ActionChip(
                          label: Text(
                            '${offerFields[field]!.$1}：${field == 'tax_mode' ? taxModeLabels[o[field]] ?? o[field] : o[field]}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          tooltip: '查看${offerFields[field]!.$1}的原文',
                          onPressed: () => _showSource(field, o[field]!),
                        ),
                  ],
                ),
              ),
            ],
          ),
      ],
    );
    return Container(
      decoration: BoxDecoration(
        border: r.plan.error != null
            ? Border(left: BorderSide(color: Tokens.red, width: 3))
            : null,
      ),
      padding: const EdgeInsets.fromLTRB(4, 10, 8, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Checkbox(
            value: r.ready,
            onChanged: r.plan.error != null
                ? null
                : (v) => setState(() => r.include = v!),
          ),
          Expanded(child: main),
          if (wide) ...[
            const SizedBox(width: 12),
            SizedBox(width: 170, child: price),
          ],
          IconButton(
            tooltip: '修改',
            icon: const Icon(Icons.edit_outlined, size: 18),
            onPressed: () => _edit(r),
          ),
        ],
      ),
    );
  }

  Widget _picker({
    required String? value,
    required String newLabel,
    required List<Hit> candidates,
    required String Function(Map<String, Object?>) label,
    required ValueChanged<String?> onChanged,
  }) => ConstrainedBox(
    constraints: const BoxConstraints(maxWidth: 280),
    child: DropdownButtonFormField<String?>(
      initialValue: value,
      isExpanded: true,
      style: Theme.of(
        context,
      ).textTheme.bodyMedium!.copyWith(color: Tokens.ink),
      decoration: const InputDecoration(
        isDense: true,
        contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      ),
      items: [
        DropdownMenuItem(
          value: null,
          child: Text(newLabel, overflow: TextOverflow.ellipsis),
        ),
        for (final h in candidates)
          DropdownMenuItem(
            value: h.id,
            child: Text('已有：${label(h.data)}', overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: onChanged,
    ),
  );

  Widget _footer(int ready, int priced, int newSuppliers, int newProducts) {
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.masterData)
            Text(
              '只登记供应商、联系人和物料；表里的单价不会存为报价（报价需要所属项目和询价人，可以之后用"智能导入"导入）。',
              style: TextStyle(fontSize: 12, color: Tokens.ink3),
            )
          else
            Wrap(
              spacing: 10,
              runSpacing: 10,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: false, label: Text('已有项目')),
                    ButtonSegment(value: true, label: Text('新建项目')),
                  ],
                  selected: {newProject},
                  showSelectedIcon: false,
                  onSelectionChanged: projects.isEmpty
                      ? null
                      : (v) => setState(() => newProject = v.single),
                ),
                if (newProject) ...[
                  field(code, '项目编号', 150),
                  field(name, '项目名称', 200),
                ] else
                  SizedBox(
                    width: 260,
                    child: DropdownButtonFormField<String>(
                      initialValue: projectId,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: '报价所属项目'),
                      items: [
                        for (final p in projects)
                          DropdownMenuItem(
                            value: p.id,
                            child: Text(
                              '${p.data['name']}（${p.data['code']}）',
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: (v) => setState(() => projectId = v),
                    ),
                  ),
                field(inquirer, '询价人', 120),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Checkbox(
                      value: addToBudget,
                      onChanged: (v) => setState(() => addToBudget = v!),
                    ),
                    const Text('同时加入项目成本预算'),
                  ],
                ),
              ],
            ),
          const SizedBox(height: 10),
          Builder(
            builder: (context) {
              final summary = Text(
                error ??
                    [
                      if (!widget.masterData) '$priced 条报价',
                      '新建供应商 $newSuppliers',
                      '新建物料 $newProducts',
                    ].join(' · '),
                style: TextStyle(
                  color: error == null ? Tokens.ink2 : Tokens.red,
                ),
              );
              final back = OutlinedButton(
                onPressed: widget.onBack,
                child: const Text('返回修改'),
              );
              final confirm = FilledButton.icon(
                onPressed: ready == 0 ? null : _apply,
                icon: const Icon(Icons.check, size: 18),
                label: Text('确认导入（$ready 条）'),
              );
              // Phones: the summary gets its own line above the buttons.
              if (MediaQuery.sizeOf(context).width < 600) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    summary,
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        back,
                        const SizedBox(width: 8),
                        Expanded(child: confirm),
                      ],
                    ),
                  ],
                );
              }
              return Row(
                children: [
                  Expanded(child: summary),
                  const SizedBox(width: 10),
                  back,
                  const SizedBox(width: 8),
                  confirm,
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

/// Edits every field of one offer. Returns the cleaned offer.
class _OfferForm extends StatefulWidget {
  const _OfferForm({required this.offer});
  final Offer offer;

  @override
  State<_OfferForm> createState() => _OfferFormState();
}

class _OfferFormState extends State<_OfferForm> {
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
