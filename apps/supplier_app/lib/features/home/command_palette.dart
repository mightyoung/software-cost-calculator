import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supplier_core/supplier_core.dart';

import '../../app/app_state.dart';
import '../../app/shell.dart';
import '../../app/theme.dart';
import '../../platform/files.dart';
import '../ai/material_import_page.dart';
import '../catalog/catalog_page.dart';
import '../projects/project_form.dart';
import '../quotes/quote_form.dart';
import '../records/open_record.dart';
import '../spec/spec_match_page.dart';

/// One entry of the palette: an action, a page or a record.
class _Entry {
  const _Entry(this.label, this.icon, this.run, {this.sub, this.keys});
  final String label;
  final IconData icon;
  final String? sub, keys;
  final Future<void> Function(BuildContext context) run;
}

/// Ctrl+K: search projects, suppliers and materials by name, model or
/// pinyin initials, jump to a page or start a common action.
Future<void> showCommandPalette(
  BuildContext context,
  AppState state,
  ValueChanged<Section> onGo,
) async {
  final picked = await showDialog<_Entry>(
    context: context,
    barrierColor: Colors.black26,
    builder: (_) => _Palette(state: state, onGo: onGo),
  );
  if (picked != null && context.mounted) await picked.run(context);
}

class _Palette extends StatefulWidget {
  const _Palette({required this.state, required this.onGo});
  final AppState state;
  final ValueChanged<Section> onGo;

  @override
  State<_Palette> createState() => _PaletteState();
}

class _PaletteState extends State<_Palette> {
  final query = TextEditingController();
  var index = 0;

  late final List<_Entry> actions = [
    _Entry(
      '录报价',
      Icons.add,
      keys: 'Ctrl+N',
      (c) => showQuoteForm(c, widget.state),
    ),
    _Entry('智能导入报价', Icons.auto_awesome_outlined, (c) async {
      final msg = await showMaterialImport(c, widget.state);
      if (msg != null && c.mounted) toast(c, msg);
    }),
    _Entry('新建项目', Icons.create_new_folder_outlined, (c) async {
      final id = await showProjectForm(c, widget.state);
      if (id != null && c.mounted) {
        await openRecord(c, widget.state, 'project', id);
      }
    }),
    _Entry('按要求找物料', Icons.rule, (c) => showSpecMatch(c, widget.state)),
    _Entry(
      '新建供应商',
      Icons.factory_outlined,
      (c) => showCatalogForm(c, widget.state, 'supplier'),
    ),
    _Entry(
      '新建物料',
      Icons.inventory_2_outlined,
      (c) => showCatalogForm(c, widget.state, 'product'),
    ),
    for (final (i, s) in Section.values.indexed)
      _Entry(
        '打开 ${s.label}',
        s.icon,
        keys: s == Section.settings
            ? 'Ctrl+,'
            : (i < 8 ? 'Ctrl+${i + 1}' : null),
        (_) async => widget.onGo(s),
      ),
    _Entry('快捷键一览', Icons.keyboard_outlined, keys: 'Ctrl+/', showShortcutHelp),
  ];

  static const _types = {
    'project': ('项目', Icons.folder_copy_outlined),
    'supplier': ('供应商', Icons.factory_outlined),
    'product': ('物料', Icons.inventory_2_outlined),
  };

  List<_Entry> get entries {
    final q = query.text.trim();
    if (q.isEmpty) return actions;
    final lower = q.toLowerCase();
    final store = widget.state.store;
    return [
      for (final a in actions)
        if (a.label.toLowerCase().contains(lower)) a,
      for (final MapEntry(key: type, value: (label, icon)) in _types.entries)
        for (final h in store.searchByName(type, q, limit: 6))
          _Entry(
            h.data['name']! as String,
            icon,
            sub: [
              label,
              if (type == 'project') h.data['code'],
              if (type == 'product') ...[h.data['brand'], h.data['model']],
            ].whereType<String>().join(' · '),
            (c) => openRecord(c, widget.state, type, h.id),
          ),
    ];
  }

  @override
  void dispose() {
    query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final list = entries;
    index = index.clamp(0, list.isEmpty ? 0 : list.length - 1);
    void move(int by) =>
        setState(() => index = list.isEmpty ? 0 : (index + by) % list.length);
    return Align(
      alignment: const Alignment(0, -0.6),
      child: Material(
        color: Tokens.surface,
        shape: RoundedRectangleBorder(
          side: BorderSide(color: Tokens.ruleStrong),
          borderRadius: BorderRadius.circular(Tokens.radius + 2),
        ),
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          width: 560,
          height: 420,
          child: Column(
            children: [
              CallbackShortcuts(
                bindings: {
                  const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
                      move(1),
                  const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
                      move(-1),
                },
                child: TextField(
                  controller: query,
                  autofocus: true,
                  decoration: const InputDecoration(
                    hintText: '搜索项目、供应商、物料（支持拼音首字母），或输入命令',
                    prefixIcon: Icon(Icons.search),
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    filled: false,
                  ),
                  onChanged: (_) => setState(() => index = 0),
                  onSubmitted: (_) {
                    if (list.isNotEmpty) Navigator.pop(context, list[index]);
                  },
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: list.isEmpty
                    ? Center(
                        child: Text(
                          '没有找到',
                          style: TextStyle(color: Tokens.ink3),
                        ),
                      )
                    : ListView.builder(
                        itemCount: list.length,
                        itemBuilder: (context, i) {
                          final e = list[i];
                          return ListTile(
                            dense: true,
                            selected: i == index,
                            selectedTileColor: Tokens.accentTint,
                            leading: Icon(e.icon, size: 18),
                            title: Text(
                              e.label,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: e.sub == null || e.sub!.isEmpty
                                ? null
                                : Text(e.sub!, overflow: TextOverflow.ellipsis),
                            trailing: e.keys == null
                                ? null
                                : Text(
                                    e.keys!,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: Tokens.ink3,
                                    ),
                                  ),
                            onTap: () => Navigator.pop(context, e),
                          );
                        },
                      ),
              ),
              Container(
                width: double.infinity,
                color: Tokens.sunken,
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 6,
                ),
                child: Text(
                  '↑↓ 选择 · Enter 打开 · Esc 关闭',
                  style: TextStyle(fontSize: 12, color: Tokens.ink3),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

const shortcutList = [
  ('Ctrl+K 或 Ctrl+F', '搜索与命令'),
  ('Ctrl+1 … Ctrl+8', '按侧栏顺序切换页面'),
  ('Ctrl+,', '设置'),
  ('Ctrl+N', '录报价'),
  ('Ctrl+Enter', '在表单里保存'),
  ('Enter / 数字键', '预算表：开始编辑；Enter 保存并跳到下一行'),
  ('↑ ↓ ← → / Tab', '在预算表单元格之间移动'),
  ('Esc', '关闭对话框'),
  ('Ctrl+/', '快捷键一览'),
];

Future<void> showShortcutHelp(BuildContext context) => showDialog<void>(
  context: context,
  builder: (context) => AlertDialog(
    title: const Text('快捷键'),
    content: SizedBox(
      width: 360,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (keys, what) in shortcutList)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(
                children: [
                  SizedBox(
                    width: 130,
                    child: Text(
                      keys,
                      style: const TextStyle(
                        fontFamily: monoFamily,
                        fontFamilyFallback: monoFallback,
                      ),
                    ),
                  ),
                  Expanded(child: Text(what)),
                ],
              ),
            ),
          const SizedBox(height: 6),
          Text(
            'macOS 上用 ⌘ 代替 Ctrl。',
            style: TextStyle(fontSize: 12, color: Tokens.ink3),
          ),
        ],
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
