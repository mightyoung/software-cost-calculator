import 'package:flutter/material.dart';
import 'package:supplier_core/supplier_core.dart';

import '../../app/app_state.dart';
import '../../widgets/app_icon.dart';
import '../../platform/files.dart';
import '../spec/spec_item_panel.dart';
import 'ask_page.dart';
import 'list_to_project.dart';
import 'material_import_page.dart';

/// Local task history. Opening this page never runs a model or writes business data.
class AiTasksPage extends StatelessWidget {
  const AiTasksPage({super.key, required this.state});
  final AppState state;

  String _title(AiTask task) => switch (task) {
    AiTask.conversation => '问数据',
    AiTask.offerExtraction => '智能导入报价',
    AiTask.listProposal => '按清单建项目',
    AiTask.clauseReading => '读取技术条款',
    AiTask.parameterExtraction => '提取技术参数',
  };

  Future<void> _resume(BuildContext context, AiJob job) async {
    try {
      if (job.task == AiTask.clauseReading) {
        final item = state.store.get(
          'spec_item',
          job.input['itemId'] as String,
        );
        if (!state.specAi ||
            item == null ||
            item.deleted ||
            item.data['spec_class'] == null ||
            !clausesOf(
              item,
            ).any((c) => !c.reviewed && (c.isText || c.hint != null))) {
          throw const FormatException('原条款已变化或条款 AI 已关闭，请回到需求项检查后重新开始');
        }
      }
      final Widget page = switch (job.task) {
        AiTask.offerExtraction => MaterialImportPage(
          state: state,
          resumeJobId: job.id,
        ),
        AiTask.listProposal => ListToProjectPage(
          state: state,
          resumeJobId: job.id,
        ),
        AiTask.conversation => Scaffold(
          appBar: AppBar(title: const Text('继续问数据')),
          body: AskPage(state: state, resumeJobId: job.id),
        ),
        AiTask.clauseReading => Scaffold(
          appBar: AppBar(title: const Text('继续读取条款')),
          body: SpecItemPanel(
            state: state,
            itemId: job.input['itemId'] as String,
            resumeJobId: job.id,
          ),
        ),
        AiTask.parameterExtraction => throw const FormatException(
          '这类任务暂不支持从此处继续',
        ),
      };
      await Navigator.of(
        context,
      ).push(MaterialPageRoute<void>(builder: (_) => page));
    } catch (e) {
      if (context.mounted) toast(context, friendlyError('$e'));
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: state,
    builder: (context, _) {
      late List<AiJob> jobs;
      try {
        jobs = state.aiTasks;
      } catch (e) {
        return Center(child: Text('任务记录读取失败：${friendlyError('$e')}'));
      }
      return ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text('AI 任务', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          const Text(
            '任务保存在本机。点击继续才会执行；导入结果仍需核对确认。继续会重新生成核对草稿，尚未确认的手工修改不会保留。删除任务记录不会删除已经导入的数据。',
          ),
          const SizedBox(height: 20),
          if (jobs.isEmpty) const Text('暂无 AI 任务'),
          for (final job in jobs)
            Card(
              child: ListTile(
                title: Text(_title(job.task)),
                subtitle: Text(
                  [
                    switch (job.status) {
                      'running' => '执行中或上次执行中断',
                      'ready' => '待核对确认',
                      'finished' => '已完成',
                      'stale' => '原始数据已变化',
                      'cancelled' => '已停止',
                      'paused' => '已暂停，可继续',
                      'failed' => '执行未完成',
                      _ => '等待继续',
                    },
                    '已保留 ${job.stepCount} 个步骤 · ${job.updatedAt}',
                    if (job.message != null) job.message!,
                  ].join('\n'),
                ),
                trailing: Wrap(
                  children: [
                    if (!['finished', 'stale'].contains(job.status) &&
                        job.task != AiTask.parameterExtraction)
                      TextButton(
                        onPressed: () => _resume(context, job),
                        child: const Text('继续'),
                      ),
                    IconButton(
                      tooltip: '删除任务记录',
                      icon: const AppIcon(Icons.delete_outline),
                      onPressed: () {
                        try {
                          state.discardAiTask(job.id);
                        } catch (e) {
                          toast(context, friendlyError('$e'));
                        }
                      },
                    ),
                  ],
                ),
              ),
            ),
        ],
      );
    },
  );
}
