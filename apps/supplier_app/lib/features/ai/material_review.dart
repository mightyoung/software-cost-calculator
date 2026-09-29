import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../app/motion.dart';
import 'package:supplier_core/supplier_core.dart';

import '../../widgets/app_icon.dart';
import '../../app/app_state.dart';
import '../../app/format.dart';
import '../../app/theme.dart';
import '../../widgets/draft_frame.dart';
import '../../widgets/ledger.dart';
import '../projects/project_form.dart';
import 'material_source.dart';
import 'offer_form.dart';

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
    this.aiTaskId,
  });
  final AppState state;
  final String? aiTaskId;

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
  final reviewScroll = ScrollController();
  var showProjectSettings = false;
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
    reviewScroll.dispose();
    for (final c in [code, name, inquirer]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _edit(_Row r) async {
    final offer = await showAppDialog<Offer>(
      context: context,
      builder: (_) => OfferForm(offer: r.offer),
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

  void _settingsError(String message) {
    setState(() {
      error = message;
      showProjectSettings = true;
    });
    if (reviewScroll.hasClients) reviewScroll.jumpTo(0);
  }

  void _apply() {
    final ready = rows.where((r) => r.ready).toList();
    if (widget.masterData) return _applyMasterData(ready);
    final person = inquirer.text.trim();
    if (person.isEmpty) return _settingsError('填写询价人');
    if (newProject && name.text.trim().isEmpty) {
      return _settingsError('填写新项目名称');
    }
    if (!newProject && projectId == null) {
      return _settingsError('选择一个项目');
    }
    late ImportSummary sum;
    final err = widget.state.write(
      (_) => widget.state.commitAiTask(
        widget.aiTaskId,
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
      ),
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
      (_) => widget.state.commitAiTask(
        widget.aiTaskId,
        (s) => sum = s.applyOffers(
          [
            for (final r in ready)
              (
                offer: r.offer,
                supplierId: r.supplierId,
                productId: r.productId,
              ),
          ],
          projectId: null,
          inquirer: widget.state.deviceName,
        ),
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
    final guidance = Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
      child: Text(
        '虚线框内是 AI 整理出的内容，确认前不会写入。可以逐条修改，或改为对应本机已有的供应商和物料。',
        style: TextStyle(color: Tokens.ink2),
      ),
    );
    if (MediaQuery.sizeOf(context).width < 600) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: ListView.builder(
              key: const ValueKey('review-content'),
              controller: reviewScroll,
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              itemCount: rows.length + 2,
              itemBuilder: (context, index) {
                if (index == 0) return guidance;
                if (index == 1) {
                  if (!showProjectSettings) return const SizedBox.shrink();
                  return Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
                    child: _projectFields(compact: true),
                  );
                }
                return Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
                  child: DraftFrame(
                    child: Material(
                      color: Tokens.surface,
                      child: _rowView(rows[index - 2]),
                    ),
                  ),
                );
              },
            ),
          ),
          Container(
            key: const ValueKey('review-confirmation'),
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 12),
            decoration: BoxDecoration(
              color: Tokens.surface,
              border: Border(top: BorderSide(color: Tokens.rule)),
            ),
            child: SafeArea(
              top: false,
              child: _confirmation(
                ready.length,
                priced,
                newSuppliers,
                newProducts,
              ),
            ),
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        guidance,
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
        _reviewHint(
          r.plan.error!,
          icon: Icons.error_outline,
          tone: HintTone.error,
        )
      else if (o['supplier'] == null && r.supplierId == null)
        _reviewHint('没有供应商，只登记物料', icon: Icons.info_outline)
      else if (o['price'] == null)
        _reviewHint('没有单价，只登记物料', icon: Icons.info_outline),
      if (o['price'] != null && o['tax_mode'] == 'unknown')
        _reviewHint('含税口径未知', icon: Icons.help_outline),
      if (r.plan.unverified.isNotEmpty)
        _reviewHint(
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
                          onPressed: () => showSourceEvidence(
                            context,
                            original: sourceText,
                            sourceName: widget.source!.name,
                            field: field,
                            value: o[field]!,
                          ),
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
        color: r.plan.error != null ? Tokens.redBg : null,
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
            icon: const AppIcon(Icons.edit_outlined, size: 18),
            onPressed: () => _edit(r),
          ),
        ],
      ),
    );
  }

  Widget _reviewHint(
    String text, {
    required IconData icon,
    HintTone tone = HintTone.warning,
  }) {
    if (MediaQuery.sizeOf(context).width >= 600) {
      return HintTag(text, icon: icon, tone: tone);
    }
    final isError = tone == HintTone.error;
    final color = isError ? Tokens.red : Tokens.amber;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 5),
      decoration: BoxDecoration(
        color: isError ? Tokens.redBg : Tokens.amberBg,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppIcon(icon, size: 16, color: color),
          const SizedBox(width: 5),
          Expanded(
            child: Text(text, style: TextStyle(fontSize: 12, color: color)),
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

  Widget _projectFields({bool compact = false}) {
    Widget field(TextEditingController c, String label, double width) =>
        SizedBox(
          width: compact ? double.infinity : width,
          child: TextField(
            controller: c,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(labelText: label),
          ),
        );
    if (widget.masterData) {
      return Text(
        '只登记供应商、联系人和物料；表里的单价不会存为报价（报价需要所属项目和询价人，可以之后用"智能导入"导入）。',
        style: TextStyle(fontSize: 12, color: Tokens.ink3),
      );
    }
    final fields = <Widget>[
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
          width: compact ? double.infinity : 260,
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
        mainAxisSize: compact ? MainAxisSize.max : MainAxisSize.min,
        children: [
          Checkbox(
            value: addToBudget,
            onChanged: (v) => setState(() => addToBudget = v!),
          ),
          if (compact)
            const Expanded(child: Text('同时加入项目成本预算'))
          else
            const Text('同时加入项目成本预算'),
        ],
      ),
    ];
    if (compact) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < fields.length; i++) ...[
            if (i > 0) const SizedBox(height: 12),
            fields[i],
          ],
        ],
      );
    }
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: fields,
    );
  }

  Widget _footer(int ready, int priced, int newSuppliers, int newProducts) {
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
          _projectFields(),
          const SizedBox(height: 10),
          _confirmation(ready, priced, newSuppliers, newProducts),
        ],
      ),
    );
  }

  Widget _confirmation(
    int ready,
    int priced,
    int newSuppliers,
    int newProducts,
  ) {
    final summary = Text(
      error ??
          [
            if (!widget.masterData) '$priced 条报价',
            '新建供应商 $newSuppliers',
            '新建物料 $newProducts',
          ].join(' · '),
      style: TextStyle(color: error == null ? Tokens.ink2 : Tokens.red),
    );
    final back = OutlinedButton(
      onPressed: widget.onBack,
      child: const Text('返回修改'),
    );
    final confirm = FilledButton.icon(
      onPressed: ready == 0 ? null : _apply,
      icon: const AppIcon(Icons.check, size: 18),
      label: Text('确认导入（$ready 条）'),
    );
    // Phones: the summary gets its own line above the buttons.
    if (MediaQuery.sizeOf(context).width < 600) {
      final destination = newProject
          ? (name.text.trim().isEmpty ? '请填写新项目' : '新项目：${name.text.trim()}')
          : '项目：${store.get('project', projectId ?? '')?.data['name'] ?? '请选择项目'}';
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!widget.masterData)
            TextButton(
              key: const ValueKey('review-destination'),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 4),
                alignment: Alignment.centerLeft,
              ),
              onPressed: () {
                setState(() => showProjectSettings = !showProjectSettings);
                reviewScroll.jumpTo(0);
              },
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '$destination\n${addToBudget ? '同时加入预算' : '仅登记报价'}',
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Text('调整设置'),
                  const SizedBox(width: 4),
                  const AppIcon(Icons.expand_less, size: 18),
                ],
              ),
            ),
          if (widget.masterData)
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text('仅登记供应商、联系人和物料；不保存报价'),
            ),
          summary,
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(child: back),
              const SizedBox(width: 8),
              Expanded(flex: 2, child: confirm),
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
  }
}

/// Edits every field of one offer. Returns the cleaned offer.
