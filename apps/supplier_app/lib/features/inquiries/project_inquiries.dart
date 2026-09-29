import 'package:flutter/material.dart';
import 'package:supplier_core/supplier_core.dart';

import '../../widgets/app_icon.dart';
import '../../app/app_state.dart';
import '../../app/theme.dart';
import '../../widgets/ledger.dart';
import 'inquiry_create.dart';
import 'inquiry_page.dart';

/// A project's inquiries with their progress.
class ProjectInquiries extends StatelessWidget {
  const ProjectInquiries({
    super.key,
    required this.state,
    required this.projectId,
  });
  final AppState state;
  final String projectId;

  Future<void> _create(BuildContext context) async {
    final id = await showCreateInquiry(context, state, projectId);
    if (id != null && context.mounted) await openInquiry(context, state, id);
  }

  @override
  Widget build(BuildContext context) {
    final store = state.store;
    final list = store.inquiriesOf(projectId);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '把待询价的行发给几家供应商，回来的报价在矩阵里逐行比较并定标，定标后自动回填预算。',
                style: TextStyle(color: Tokens.ink2),
              ),
            ),
            const SizedBox(width: 12),
            FilledButton.icon(
              onPressed: () => _create(context),
              icon: const AppIcon(Icons.send_outlined, size: 18),
              label: const Text('发起询价'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Expanded(
          child: list.isEmpty
              ? const EmptyState(title: '还没有询价单', body: '从预算中选出要询价的行，邀请供应商报价。')
              : ListView(
                  children: [
                    for (final inq in list)
                      () {
                        final m = store.inquiryMatrix(inq.id);
                        final replied = m.answered.values
                            .where((n) => n > 0)
                            .length;
                        final awarded = m.rows
                            .where(
                              (r) => r.cells.any((c) => c?.awarded ?? false),
                            )
                            .length;
                        return Card(
                          margin: const EdgeInsets.only(bottom: 8),
                          child: ListTile(
                            title: Text(inq.data['title']! as String),
                            subtitle: Text(
                              [
                                '${m.rows.length} 行',
                                '已回复 $replied/${m.suppliers.length} 家',
                                '已定标 $awarded/${m.rows.length}',
                                '截止 ${inq.data['due_date'] ?? '不限'}',
                                if (inq.data['status'] == 'closed') '已结束',
                              ].join(' · '),
                            ),
                            trailing: const AppIcon(Icons.chevron_right),
                            onTap: () => openInquiry(context, state, inq.id),
                          ),
                        );
                      }(),
                  ],
                ),
        ),
      ],
    );
  }
}
