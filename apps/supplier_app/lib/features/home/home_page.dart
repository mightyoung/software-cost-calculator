import 'package:flutter/material.dart';
import 'package:supplier_core/supplier_core.dart';

import '../../app/app_state.dart';
import '../../app/format.dart';
import '../../app/shell.dart';
import '../../app/theme.dart';
import '../../platform/files.dart';
import '../../widgets/ledger.dart';
import '../ai/material_import_page.dart';
import '../projects/project_form.dart';
import '../quotes/quote_form.dart';
import '../records/open_record.dart';

/// What needs a person today, across all projects: inquiries waiting for
/// replies, lines still to be priced, quotes about to expire, conflicts.
class HomePage extends StatelessWidget {
  const HomePage({super.key, required this.state, required this.onGo});
  final AppState state;
  final ValueChanged<Section> onGo;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: state,
    builder: (context, _) {
      final w = state.store.workbench();
      return ListView(
        padding: const EdgeInsets.fromLTRB(24, 18, 24, 32),
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '工作台',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              const Text(
                'Ctrl+K 搜索与命令',
                style: TextStyle(fontSize: 12, color: Tokens.ink3),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: () => showQuoteForm(context, state),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('录报价'),
              ),
              OutlinedButton.icon(
                onPressed: () async {
                  final msg = await showMaterialImport(context, state);
                  if (msg != null && context.mounted) toast(context, msg);
                },
                icon: const Icon(Icons.auto_awesome_outlined, size: 18),
                label: const Text('智能导入'),
              ),
              OutlinedButton.icon(
                onPressed: () async {
                  final id = await showProjectForm(context, state);
                  if (id != null && context.mounted) {
                    await openRecord(context, state, 'project', id);
                  }
                },
                icon: const Icon(Icons.create_new_folder_outlined, size: 18),
                label: const Text('新建项目'),
              ),
            ],
          ),
          if (w.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 48),
              child: EmptyState(
                title: '今天没有要处理的事',
                body: '询价单的回复进度、待询价的预算行、即将到期的报价和修改冲突都会出现在这里。',
              ),
            ),
          if (w.conflicts > 0)
            _Section(
              '修改冲突',
              count: w.conflicts,
              children: [
                _Line(
                  title: '有 ${w.conflicts} 处修改在两台设备上不一致',
                  sub: '确认保留哪一个值之前，这些字段按最后导入的值显示',
                  trailing: const HintTag('待确认'),
                  onTap: () => onGo(Section.exchange),
                ),
              ],
            ),
          if (w.inquiries.isNotEmpty)
            _Section(
              '询价单',
              count: w.inquiries.length,
              children: [
                for (final i in w.inquiries)
                  _Line(
                    title: '${i.data['title']}',
                    sub: '${i.project} · 已回复 ${i.replied}/${i.suppliers} 家',
                    trailing: _due(i.daysLeft, i.data['due_date'] as String?),
                    onTap: () => openRecord(context, state, 'inquiry', i.id),
                  ),
              ],
            ),
          if (w.pending.isNotEmpty)
            _Section(
              '待询价的预算行',
              count: w.pending.fold(0, (n, p) => n + p.lines),
              children: [
                for (final p in w.pending)
                  _Line(
                    title: p.name,
                    sub: '${p.lines} 行还没有关联报价',
                    trailing: const Icon(
                      Icons.chevron_right,
                      color: Tokens.ink3,
                    ),
                    onTap: () => openRecord(context, state, 'project', p.id),
                  ),
              ],
            ),
          if (w.attention.expiringCount > 0)
            _Section(
              '30 天内到期的报价',
              count: w.attention.expiringCount,
              action: TextButton(
                onPressed: () => onGo(Section.quotes),
                child: const Text('全部报价'),
              ),
              children: [
                for (final h in w.attention.expiring)
                  _Line(
                    title: _name('product', h.data['product_id']),
                    sub:
                        '${_name('supplier', h.data['supplier_id'])} · '
                        '${money(priceOf(h.data))} / ${h.data['unit_snapshot']}',
                    trailing: HintTag(
                      '${h.data['expires_on']} 到期',
                      icon: Icons.schedule,
                    ),
                    onTap: () => openRecord(context, state, 'quotation', h.id),
                  ),
              ],
            ),
        ],
      );
    },
  );

  String _name(String type, Object? id) => id is String
      ? state.store.get(type, id)?.data['name'] as String? ?? '已删除'
      : '—';

  Widget _due(int? days, String? date) => switch (days) {
    null => const Text('未设截止日', style: TextStyle(color: Tokens.ink3)),
    < 0 => HintTag(
      '已逾期 ${-days} 天',
      icon: Icons.error_outline,
      tone: HintTone.error,
    ),
    0 => const HintTag('今天截止', icon: Icons.schedule),
    <= 3 => HintTag('还剩 $days 天', icon: Icons.schedule),
    _ => Text('$date 截止', style: const TextStyle(color: Tokens.ink2)),
  };
}

class _Section extends StatelessWidget {
  const _Section(
    this.title, {
    required this.count,
    required this.children,
    this.action,
  });
  final String title;
  final int count;
  final List<Widget> children;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(width: 8),
            Text(
              '$count',
              style: const TextStyle(color: Tokens.ink3, fontFeatures: tabular),
            ),
            const Spacer(),
            ?action,
          ],
        ),
        const SizedBox(height: 6),
        Container(
          decoration: BoxDecoration(
            color: Tokens.surface,
            border: Border.all(color: Tokens.rule),
            borderRadius: BorderRadius.circular(Tokens.radius),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(children: children),
        ),
      ],
    ),
  );
}

class _Line extends StatelessWidget {
  const _Line({
    required this.title,
    required this.sub,
    required this.trailing,
    required this.onTap,
  });
  final String title, sub;
  final Widget trailing;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Tokens.rule)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, overflow: TextOverflow.ellipsis),
                Text(
                  sub,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, color: Tokens.ink3),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          trailing,
        ],
      ),
    ),
  );
}
