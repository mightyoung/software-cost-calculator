import 'package:flutter/material.dart';
import 'package:supplier_core/supplier_core.dart';

import '../../app/app_state.dart';
import '../../app/format.dart';
import '../../app/theme.dart';
import '../../widgets/ledger.dart';
import '../ai/list_to_project.dart';
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
    if (id != null && mounted) setState(() => selected = id);
  }

  Future<void> _fromList() async {
    final id = await showListToProject(context, state);
    if (id != null && mounted) setState(() => selected = id);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: state,
    builder: (context, _) {
      final projects = [
        for (final h in state.store.searchByName('project', search, limit: 500))
          if (status == null || h.data['status'] == status) h,
      ];
      return LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 1000;
          final current = projects.any((p) => p.id == selected)
              ? selected
              : (projects.isEmpty ? null : projects.first.id);
          final list = _ProjectList(
            projects: projects,
            store: state.store,
            selected: wide ? current : null,
            status: status,
            onSearch: (v) => setState(() => search = v),
            onStatus: (v) => setState(() => status = v),
            onCreate: _create,
            onFromList: _fromList,
            onOpen: (id) {
              if (wide) return setState(() => selected = id);
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => Scaffold(
                    appBar: AppBar(backgroundColor: Tokens.canvas),
                    body: ProjectDetail(
                      state: state,
                      projectId: id,
                      compact: true,
                    ),
                  ),
                ),
              );
            },
          );
          if (!wide) return list;
          return Row(
            children: [
              SizedBox(width: 240, child: list),
              const VerticalDivider(width: 1),
              Expanded(
                child: current == null
                    ? EmptyState(
                        title: '没有符合条件的项目',
                        body: '调整搜索或状态筛选，也可以创建新项目。',
                        actions: [
                          FilledButton(
                            onPressed: _create,
                            child: const Text('新建项目'),
                          ),
                          OutlinedButton(
                            onPressed: _fromList,
                            child: const Text('从清单生成'),
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
    required this.onFromList,
    required this.onOpen,
  });
  final List<Hit> projects;
  final Store store;
  final String? selected, status;
  final ValueChanged<String> onSearch;
  final ValueChanged<String?> onStatus;
  final VoidCallback onCreate, onFromList;
  final ValueChanged<String> onOpen;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 24, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('项目', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 6),
            Text('报价与成本预算', style: TextStyle(color: Tokens.ink2)),
            const SizedBox(height: 20),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton(onPressed: onCreate, child: const Text('新建项目')),
                OutlinedButton(
                  onPressed: onFromList,
                  child: const Text('从清单生成'),
                ),
              ],
            ),
            const SizedBox(height: 16),
            TextField(
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search, size: 18),
                hintText: '搜索项目或编号',
              ),
              onChanged: onSearch,
            ),
          ],
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
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
            ? Padding(
                padding: EdgeInsets.all(16),
                child: Text('没有符合条件的项目', style: TextStyle(color: Tokens.ink3)),
              )
            : ListView.separated(
                itemCount: projects.length,
                separatorBuilder: (_, _) => const Divider(),
                itemBuilder: (context, i) {
                  final p = projects[i];
                  final on = p.id == selected;
                  final b = store.budget(p.id, withWarnings: false);
                  // Material lines without a quote still to be inquired.
                  final pending = b.lines
                      .where(
                        (l) =>
                            l.data['category'] == 'material' &&
                            l.data['quotation_id'] == null,
                      )
                      .length;
                  return Semantics(
                    selected: on,
                    child: Material(
                      color: on ? Tokens.accentTint : Tokens.surface,
                      child: InkWell(
                        onTap: () => onOpen(p.id),
                        child: Container(
                          padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                p.data['name']! as String,
                                style: TextStyle(
                                  fontWeight: FontWeight.w600,
                                  fontSize: 14,
                                  color: on ? Tokens.accentDeep : Tokens.ink,
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 6),
                              MonoText(p.data['code']! as String),
                              const SizedBox(height: 8),
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      p.data['customer'] as String? ?? '',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: Tokens.ink3,
                                      ),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  Text(
                                    '成本 ${yuan(b.cost)}',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: Tokens.ink3,
                                      fontFeatures: tabular,
                                    ),
                                  ),
                                ],
                              ),
                              if (pending > 0 || b.lines.isNotEmpty) ...[
                                const SizedBox(height: 4),
                                Row(
                                  children: [
                                    if (pending > 0)
                                      HintTag(
                                        '$pending 行待询价',
                                        icon: Icons.help_outline,
                                      ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        '毛利 ${yuan(b.margin)}',
                                        textAlign: TextAlign.right,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: micros(b.margin) > BigInt.zero
                                              ? Tokens.green
                                              : Tokens.ink3,
                                          fontFeatures: tabular,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ],
                          ),
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
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: 48, minWidth: 48),
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? Tokens.accentTint : Tokens.surface,
          border: Border.all(
            color: selected ? Tokens.accent : Tokens.ruleStrong,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            color: selected ? Tokens.accentDeep : Tokens.ink2,
          ),
        ),
      ),
    ),
  );
}
