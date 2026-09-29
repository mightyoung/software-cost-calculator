import 'package:flutter/material.dart';
import 'package:supplier_core/supplier_core.dart';

import '../../widgets/app_icon.dart';
import '../../app/app_state.dart';
import '../../app/theme.dart';
import '../../platform/files.dart';

const _tabs = [('project', '项目'), ('product', '物料'), ('supplier', '供应商')];

const _closureLabels = {
  'project': '项目',
  'project_item': '预算行',
  'quotation': '报价',
  'inquiry': '询价单',
  'product': '物料',
  'supplier': '供应商',
  'contact': '联系人',
};

/// Picks projects, materials and suppliers and pushes them to a nearby
/// device. [chosen] preselects records (e.g. the open project).
Future<void> showLanPush(
  BuildContext context,
  AppState state, {
  Map<String, Set<String>>? chosen,
}) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    builder: (_) => LanPushPage(state: state, chosen: chosen),
  ),
);

class LanPushPage extends StatefulWidget {
  const LanPushPage({super.key, required this.state, this.chosen});
  final AppState state;
  final Map<String, Set<String>>? chosen;

  @override
  State<LanPushPage> createState() => _LanPushPageState();
}

class _LanPushPageState extends State<LanPushPage> {
  late final Map<String, Set<String>> chosen = {
    for (final (t, _) in _tabs) t: {...?widget.chosen?[t]},
  };
  final query = TextEditingController();
  LanPeer? target;
  var sending = false;
  Store get store => widget.state.store;

  @override
  void dispose() {
    query.dispose();
    super.dispose();
  }

  List<Hit> _results(String type) {
    final q = query.text.trim();
    if (type == 'product' && q.isNotEmpty) {
      return store.searchProducts(q.split(RegExp(r'\s+')), limit: 200);
    }
    return store.searchByName(type, q, limit: 200);
  }

  String _label(String type, Map<String, Object?> d) => switch (type) {
    'project' => '${d['name']}（${d['code']}）',
    'product' => [
      d['name'],
      d['brand'],
      d['model'],
    ].whereType<String>().join(' '),
    _ => d['name'] as String? ?? '',
  };

  Future<void> _send() async {
    final to = target;
    if (to == null) return;
    setState(() => sending = true);
    final err = await widget.state.pushTo(to, {
      for (final e in chosen.entries)
        if (e.value.isNotEmpty) e.key: e.value.toList(),
    });
    if (!mounted) return;
    setState(() => sending = false);
    if (err != null) return toast(context, err);
    toast(context, '已发送给 ${to.name}，等待对方确认导入');
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final count = chosen.values.fold(0, (n, s) => n + s.length);
    final closure = count == 0 ? null : store.shareClosure(chosen);
    return DefaultTabController(
      length: _tabs.length,
      child: Scaffold(
        appBar: AppBar(
          backgroundColor: Tokens.canvas,
          title: const Text('推送到局域网设备'),
          bottom: TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [
              for (final (t, label) in _tabs)
                Tab(
                  text: chosen[t]!.isEmpty
                      ? label
                      : '$label（${chosen[t]!.length}）',
                ),
            ],
          ),
        ),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
              child: TextField(
                controller: query,
                decoration: const InputDecoration(
                  prefixIcon: AppIcon(Icons.search),
                  hintText: '搜索名称、型号或拼音首字母',
                ),
                onChanged: (_) => setState(() {}),
              ),
            ),
            Expanded(
              child: TabBarView(
                children: [
                  for (final (type, label) in _tabs)
                    Builder(
                      builder: (_) {
                        final hits = _results(type);
                        if (hits.isEmpty) {
                          return Center(
                            child: Text(
                              '没有找到$label',
                              style: TextStyle(color: Tokens.ink3),
                            ),
                          );
                        }
                        return ListView(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          children: [
                            for (final h in hits)
                              CheckboxListTile(
                                dense: true,
                                controlAffinity:
                                    ListTileControlAffinity.leading,
                                value: chosen[type]!.contains(h.id),
                                title: Text(_label(type, h.data)),
                                onChanged: (v) => setState(
                                  () => v!
                                      ? chosen[type]!.add(h.id)
                                      : chosen[type]!.remove(h.id),
                                ),
                              ),
                          ],
                        );
                      },
                    ),
                ],
              ),
            ),
            _bottomBar(closure),
          ],
        ),
      ),
    );
  }

  static String _summary(Map<String, Set<String>> closure) => [
    for (final MapEntry(key: type, value: label) in _closureLabels.entries)
      if (closure[type]?.isNotEmpty ?? false) '$label ${closure[type]!.length}',
  ].join('、');

  Widget _bottomBar(Map<String, Set<String>>? closure) => ListenableBuilder(
    listenable: widget.state,
    builder: (context, _) {
      final peers = widget.state.lan?.peers ?? const <LanPeer>[];
      // Keep the choice while the device stays listed.
      final current = peers.where((p) => p.id == target?.id).firstOrNull;
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
        decoration: BoxDecoration(
          color: Tokens.surface,
          border: Border(top: BorderSide(color: Tokens.rule)),
        ),
        child: Wrap(
          spacing: 16,
          runSpacing: 10,
          crossAxisAlignment: WrapCrossAlignment.center,
          alignment: WrapAlignment.spaceBetween,
          children: [
            Text(
              closure == null ? '勾选要推送的内容' : '将发送 ${_summary(closure)}（含关联记录）',
              style: TextStyle(color: Tokens.ink2),
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.state.lan == null)
                  TextButton(
                    onPressed: () => widget.state.setLanVisible(true),
                    child: const Text('打开"局域网可见"'),
                  )
                else
                  DropdownButton<LanPeer>(
                    value: current,
                    hint: Text(peers.isEmpty ? '附近没有设备' : '选择接收设备'),
                    items: [
                      for (final p in peers)
                        DropdownMenuItem(
                          value: p,
                          child: Text(
                            '${p.name} · ${p.address}:${p.port}（身份未验证）',
                          ),
                        ),
                    ],
                    onChanged: (p) => setState(() => target = p),
                  ),
                const SizedBox(width: 12),
                FilledButton.icon(
                  onPressed: sending || closure == null || current == null
                      ? null
                      : _send,
                  icon: const AppIcon(Icons.send, size: 18),
                  label: Text(sending ? '正在发送…' : '推送'),
                ),
              ],
            ),
          ],
        ),
      );
    },
  );
}
