import 'package:flutter/material.dart';
import 'package:supplier_core/supplier_core.dart';

import '../../app/app_state.dart';
import '../../app/format.dart';
import '../../app/theme.dart';
import '../../widgets/ledger.dart';
import 'project_detail.dart';
import 'project_form.dart';

class ProjectsPage extends StatefulWidget {
  const ProjectsPage({super.key, required this.state});
  final AppState state;

  @override
  State<ProjectsPage> createState() => _ProjectsPageState();
}

class _ProjectsPageState extends State<ProjectsPage> {
  String? selected;
  String search = '';
  String? status = 'active';

  AppState get state => widget.state;

  Future<void> _create() async {
    final id = await showProjectForm(context, state);
    if (id != null) setState(() => selected = id);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: state,
    builder: (context, _) {
      final projects = [
        for (final h in state.store.searchByName('project', search, limit: 500))
          if (status == null || h.data['status'] == status) h,
      ];
      final wide = MediaQuery.sizeOf(context).width >= 1024;
      final list = _ProjectList(
        projects: projects,
        store: state.store,
        selected: wide ? selected : null,
        status: status,
        onSearch: (v) => setState(() => search = v),
        onStatus: (v) => setState(() => status = v),
        onCreate: _create,
        onOpen: (id) {
          if (wide) return setState(() => selected = id);
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => Scaffold(
                appBar: AppBar(backgroundColor: Tokens.canvas),
                body: ProjectDetail(state: state, projectId: id, compact: true),
              ),
            ),
          );
        },
      );
      if (!wide) return list;
      final current =
          selected != null &&
              state.store.get('project', selected!)?.deleted == false
          ? selected
          : (projects.isEmpty ? null : projects.first.id);
      return Row(
        children: [
          SizedBox(width: 240, child: list),
          const VerticalDivider(width: 1),
          Expanded(
            child: current == null
                ? EmptyState(
                    title: '建立第一个项目',
                    body: '项目用来汇总报价与成本预算，可从客户清单一键生成。',
                    actions: [
                      FilledButton(
                        onPressed: _create,
                        child: const Text('新建项目'),
                      ),
                    ],
                  )
                : ProjectDetail(
                    key: ValueKey(current),
                    state: state,
                    projectId: current,
                  ),
          ),
        ],
      );
    },
  );
}

class _ProjectList extends StatelessWidget {
  const _ProjectList({
    required this.projects,
    required this.store,
    required this.selected,
    required this.status,
    required this.onSearch,
    required this.onStatus,
    required this.onCreate,
    required this.onOpen,
  });
  final List<Hit> projects;
  final Store store;
  final String? selected, status;
  final ValueChanged<String> onSearch;
  final ValueChanged<String?> onStatus;
  final VoidCallback onCreate;
  final ValueChanged<String> onOpen;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 14, 12, 8),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search, size: 18),
                  hintText: '搜索项目或编号',
                ),
                onChanged: onSearch,
              ),
            ),
            const SizedBox(width: 8),
            IconButton.outlined(
              tooltip: '新建项目',
              onPressed: onCreate,
              icon: const Icon(Icons.add, size: 18),
            ),
          ],
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
        child: Row(
          children: [
            for (final (label, value) in [
              ('进行中', 'active'),
              ('策划中', 'planning'),
              ('全部', null),
            ])
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: _Pill(
                  label: label,
                  selected: status == value,
                  onTap: () => onStatus(value),
                ),
              ),
          ],
        ),
      ),
      const Divider(),
      Expanded(
        child: projects.isEmpty
            ? const Padding(
                padding: EdgeInsets.all(16),
                child: Text('没有符合条件的项目', style: TextStyle(color: Tokens.ink3)),
              )
            : ListView.separated(
                itemCount: projects.length,
                separatorBuilder: (_, _) => const Divider(),
                itemBuilder: (context, i) {
                  final p = projects[i];
                  final on = p.id == selected;
                  final cost = store.budget(p.id, withWarnings: false).cost;
                  return Material(
                    color: on ? Tokens.surface : Colors.transparent,
                    child: InkWell(
                      onTap: () => onOpen(p.id),
                      child: Container(
                        decoration: BoxDecoration(
                          border: on
                              ? const Border(
                                  left: BorderSide(
                                    color: Tokens.accent,
                                    width: 3,
                                  ),
                                )
                              : null,
                        ),
                        padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            MonoText(p.data['code']! as String),
                            const SizedBox(height: 3),
                            Text(
                              p.data['name']! as String,
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 14,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 2),
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    p.data['customer'] as String? ?? '',
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: Tokens.ink3,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                Text(
                                  '成本 ${yuan(cost)}',
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: Tokens.ink3,
                                    fontFeatures: tabular,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
      ),
    ],
  );
}

String projectLabel(Map<String, Object?> p) => '${p['name']}（${p['code']}）';
String statusLabel(Object? s) => statusLabels[s] ?? '$s';

class _Pill extends StatelessWidget {
  const _Pill({
    required this.label,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    selected: selected,
    button: true,
    child: InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 4),
        decoration: BoxDecoration(
          color: selected ? Tokens.ink : Tokens.surface,
          border: Border.all(color: selected ? Tokens.ink : Tokens.ruleStrong),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: selected ? Colors.white : Tokens.ink2,
          ),
        ),
      ),
    ),
  );
}
