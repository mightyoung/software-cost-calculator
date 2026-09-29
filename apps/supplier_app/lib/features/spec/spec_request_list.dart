import 'package:flutter/material.dart';
import 'package:supplier_core/supplier_core.dart';

import '../../app/app_state.dart';
import '../../app/theme.dart';
import '../../widgets/ledger.dart';
import 'spec_import.dart';
import 'spec_request_page.dart';

/// All technical requirements, from the command palette.
Future<void> showSpecRequests(BuildContext context, AppState state) =>
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          appBar: AppBar(
            backgroundColor: Tokens.canvas,
            title: const Text('技术要求选型'),
          ),
          body: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: SpecRequestList(state: state),
          ),
        ),
      ),
    );

/// Technical requirements (of one project, or all) with their progress.
class SpecRequestList extends StatelessWidget {
  const SpecRequestList({super.key, required this.state, this.projectId});
  final AppState state;
  final String? projectId;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: state,
    builder: (context, _) {
      final store = state.store;
      final requests = store.specRequests(projectId: projectId);
      final add = FilledButton.icon(
        onPressed: () => showSpecImport(context, state, projectId: projectId),
        icon: const Icon(Icons.upload_file, size: 18),
        label: const Text('导入技术要求'),
      );
      if (requests.isEmpty) {
        return EmptyState(
          title: '还没有技术要求',
          body:
              '导入招标或设计的技术要求（Excel、粘贴文字，或本项目待询价的物料行），'
              '软件把条款读成可比较的条件，在物料库里找出符合的设备，定选后导出技术偏离表。',
          actions: [add],
        );
      }
      return ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          Align(alignment: Alignment.centerRight, child: add),
          const SizedBox(height: 8),
          for (final r in requests)
            () {
              final items = store.specItemsOf(r.id);
              final chosen = items
                  .where((i) => i.data['chosen_product_id'] != null)
                  .length;
              final open = [
                for (final i in items)
                  ...clausesOf(i).where((c) => !c.reviewed),
              ].length;
              final project = r.data['project_id'] == null || projectId != null
                  ? null
                  : store.get('project', r.data['project_id']! as String)?.data;
              return Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  title: Text('${r.data['title']}'),
                  subtitle: Text(
                    [
                      if (project != null) '${project['name']}',
                      '${items.length} 项',
                      '已定选 $chosen',
                      if (open > 0) '待核对条款 $open',
                      if (r.data['source_name'] case final String s) '来源：$s',
                    ].join(' · '),
                    style: TextStyle(color: Tokens.ink3),
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => showSpecRequest(context, state, r.id),
                ),
              );
            }(),
        ],
      );
    },
  );
}
