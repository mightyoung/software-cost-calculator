import 'package:flutter/material.dart';
import 'package:supplier_core/supplier_core.dart';

import '../../app/app_state.dart';
import '../../app/theme.dart';
import '../../platform/cjk_font.dart';
import '../../platform/files.dart';
import '../../widgets/ledger.dart';
import 'spec_item_panel.dart';

Future<void> showSpecRequest(
  BuildContext context,
  AppState state,
  String requestId,
) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    builder: (_) => SpecRequestPage(state: state, requestId: requestId),
  ),
);

/// One technical requirement: its items on the left, the chosen item's
/// clauses, matching and choice on the right (design §10.3). Phones show
/// the list and open an item full screen.
class SpecRequestPage extends StatefulWidget {
  const SpecRequestPage({
    super.key,
    required this.state,
    required this.requestId,
  });
  final AppState state;
  final String requestId;

  @override
  State<SpecRequestPage> createState() => _SpecRequestPageState();
}

class _SpecRequestPageState extends State<SpecRequestPage> {
  String? selected;
  AppState get state => widget.state;

  Future<void> _export(Map<String, Object?> req, {required bool pdf}) async {
    final name = '技术偏离表-${req['title']}-${today()}';
    if (!pdf) {
      final saved = await saveBytes(
        '$name.xlsx',
        state.store.deviationXlsx(widget.requestId),
        extensions: ['xlsx'],
      );
      if (saved && mounted) toast(context, '已导出技术偏离表');
      return;
    }
    final font = await cjkFont();
    if (!mounted) return;
    if (font == null) {
      return toast(context, '本机没有找到可嵌入 PDF 的中文字体，请改用 Excel 导出');
    }
    final bytes = await state.store.deviationPdf(widget.requestId, font);
    final saved = await saveBytes('$name.pdf', bytes, extensions: ['pdf']);
    if (saved && mounted) toast(context, '已导出技术偏离表 PDF');
  }

  Future<void> _exportSuppliers(Map<String, Object?> req) async {
    final saved = await saveBytes(
      '供应商偏离表-${req['title']}-${today()}.xlsx',
      state.store.supplierDeviationXlsx(widget.requestId),
      extensions: ['xlsx'],
    );
    if (saved && mounted) toast(context, '已导出供应商偏离表');
  }

  void _addToBudget() {
    late int n;
    final err = state.write((s) => n = s.addItemsToBudget(widget.requestId));
    toast(
      context,
      err ??
          (n == 0
              ? '需求项都已在项目预算里'
              : '已加入 $n 行待询价物料。在项目的询价单里发给供应商，询价表会带上逐条填写的技术响应页。'),
    );
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('删除这份技术要求？'),
        content: const Text('连同其中的需求项和定选记录一起删除，可在回收站恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final problem = state.write((s) => s.deleteSpecRequest(widget.requestId));
    if (problem != null) return toast(context, problem);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: state,
    builder: (context, _) {
      final rec = state.store.get('spec_request', widget.requestId);
      if (rec == null || rec.deleted) {
        return Scaffold(
          appBar: AppBar(backgroundColor: Tokens.canvas),
          body: const EmptyState(title: '技术要求已删除', body: '这份技术要求已在本机或其他设备上删除。'),
        );
      }
      final items = state.store.specItemsOf(widget.requestId);
      final current = items.where((i) => i.id == selected).firstOrNull;
      return Scaffold(
        appBar: AppBar(
          backgroundColor: Tokens.canvas,
          title: Text('${rec.data['title']}'),
          actions: [
            MenuAnchor(
              menuChildren: [
                MenuItemButton(
                  onPressed: () => _export(rec.data, pdf: false),
                  child: const Text('导出技术偏离表（Excel）'),
                ),
                MenuItemButton(
                  onPressed: () => _export(rec.data, pdf: true),
                  child: const Text('导出技术偏离表（PDF）'),
                ),
                MenuItemButton(
                  onPressed: () => _exportSuppliers(rec.data),
                  child: const Text('导出供应商偏离表（Excel）'),
                ),
                if (rec.data['project_id'] != null) ...[
                  const Divider(height: 8),
                  MenuItemButton(
                    onPressed: _addToBudget,
                    child: const Text('加入项目预算（待询价）'),
                  ),
                ],
                const Divider(height: 8),
                MenuItemButton(
                  onPressed: _delete,
                  child: const Text('删除这份技术要求'),
                ),
              ],
              builder: (context, controller, _) => IconButton(
                tooltip: '导出与更多',
                icon: const Icon(Icons.more_horiz),
                onPressed: () =>
                    controller.isOpen ? controller.close() : controller.open(),
              ),
            ),
            const SizedBox(width: 8),
          ],
        ),
        body: items.isEmpty
            ? const EmptyState(title: '没有需求项', body: '导入时没有识别出设备。')
            : LayoutBuilder(
                builder: (context, box) {
                  final wide = box.maxWidth >= 900;
                  final list = _ItemList(
                    items: items,
                    selected: wide ? (current ?? items.first).id : null,
                    onTap: (id) => wide
                        ? setState(() => selected = id)
                        : Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => Scaffold(
                                appBar: AppBar(backgroundColor: Tokens.canvas),
                                body: SpecItemPanel(state: state, itemId: id),
                              ),
                            ),
                          ),
                  );
                  if (!wide) return list;
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(width: 300, child: list),
                      VerticalDivider(width: 1, color: Tokens.rule),
                      Expanded(
                        child: SpecItemPanel(
                          key: ValueKey((current ?? items.first).id),
                          state: state,
                          itemId: (current ?? items.first).id,
                        ),
                      ),
                    ],
                  );
                },
              ),
      );
    },
  );
}

class _ItemList extends StatelessWidget {
  const _ItemList({
    required this.items,
    required this.selected,
    required this.onTap,
  });
  final List<Record> items;
  final String? selected;
  final ValueChanged<String> onTap;

  @override
  Widget build(BuildContext context) {
    final open = [
      for (final i in items) clausesOf(i).where((c) => !c.reviewed).length,
    ];
    final chosen = items.where((i) => i.data['chosen_product_id'] != null);
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Text(
            '${items.length} 项 · 已定选 ${chosen.length} · 待核对条款 ${open.fold(0, (a, b) => a + b)}',
            style: TextStyle(color: Tokens.ink2, fontSize: 13),
          ),
        ),
        for (final (k, i) in items.indexed)
          ListTile(
            selected: i.id == selected,
            selectedTileColor: Tokens.sunken,
            title: Text(
              '${i.data['seq']}. ${i.data['name']}',
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              [
                i.data['spec_class'] == null
                    ? '类别待定'
                    : specClass(i.data['spec_class']! as String)?.label ??
                          '${i.data['spec_class']}',
                if (i.data['qty'] != null)
                  '×${i.data['qty']}${i.data['unit'] ?? ''}',
              ].join('　'),
              style: TextStyle(color: Tokens.ink3, fontSize: 12),
            ),
            trailing: i.data['chosen_product_id'] != null
                ? const HintTag(
                    '已定选',
                    icon: Icons.task_alt,
                    tone: HintTone.success,
                  )
                : open[k] > 0
                ? HintTag(
                    '待核对 ${open[k]}',
                    icon: Icons.rule,
                    tone: HintTone.warning,
                  )
                : null,
            onTap: () => onTap(i.id),
          ),
      ],
    );
  }
}
