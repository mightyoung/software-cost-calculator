import 'package:flutter/material.dart';

import '../../app/workspace.dart';

class JobHistoryPage extends StatefulWidget {
  const JobHistoryPage({super.key, required this.workspace, this.onResume});

  final SupplierWorkspace workspace;
  final Future<void> Function(WorkspaceJob job)? onResume;

  @override
  State<JobHistoryPage> createState() => _JobHistoryPageState();
}

class _JobHistoryPageState extends State<JobHistoryPage> {
  late Future<List<WorkspaceJob>> _jobs = widget.workspace.jobHistory();
  String? _error;
  String? _busy;

  Future<void> _resume(WorkspaceJob job) async {
    setState(() {
      _busy = job.id;
      _error = null;
    });
    try {
      await widget.onResume!(job);
      if (mounted) setState(() => _jobs = widget.workspace.jobHistory());
    } catch (error) {
      if (mounted) setState(() => _error = '任务未继续：$error');
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('文件任务记录'),
      actions: [
        IconButton(
          tooltip: '刷新',
          onPressed: _busy == null
              ? () => setState(() => _jobs = widget.workspace.jobHistory())
              : null,
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: FutureBuilder<List<WorkspaceJob>>(
      future: _jobs,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(
            child: CircularProgressIndicator(semanticsLabel: '正在读取文件任务'),
          );
        }
        if (snapshot.hasError) {
          return _Message(
            message: '任务记录读取失败：${snapshot.error}',
            action: () => setState(() => _jobs = widget.workspace.jobHistory()),
          );
        }
        final jobs = snapshot.requireData;
        if (jobs.isEmpty) {
          return const _Message(message: '还没有业务导入或完整同步任务。');
        }
        return ListView(
          padding: const EdgeInsets.all(24),
          children: [
            if (_error != null)
              Semantics(
                liveRegion: true,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              ),
            for (final job in jobs)
              Card(
                child: ListTile(
                  leading: _busy == job.id
                      ? const SizedBox.square(
                          dimension: 24,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(_icon(job.state)),
                  title: Text(_label(job.state)),
                  subtitle: SelectableText(
                    '${job.sourceLength} 字节 · 基线 generation ${job.generation}\n任务 ${job.id}'
                    '${job.sourceDigest == null ? '\n源文件尚未绑定' : '\n源摘要 ${job.sourceDigest}'}',
                  ),
                  isThreeLine: true,
                  trailing: widget.onResume != null && !job.terminal
                      ? OutlinedButton(
                          onPressed: _busy == null ? () => _resume(job) : null,
                          child: const Text('继续'),
                        )
                      : null,
                ),
              ),
          ],
        );
      },
    ),
  );
}

String _label(String state) => switch (state) {
  'created' => '等待读取文件',
  'parsing' => '解析中断，可重新选择同一文件',
  'validating' => '验证中断，可重新核对',
  'previewReady' => '等待确认',
  'committing' => '正在核对提交结果',
  'committed' => '已完成',
  'cancelled' => '已取消',
  'failed' => '失败，原任务保留',
  _ => state,
};

IconData _icon(String state) => switch (state) {
  'committed' => Icons.check_circle_outline,
  'cancelled' => Icons.cancel_outlined,
  'failed' => Icons.error_outline,
  'previewReady' => Icons.fact_check_outlined,
  _ => Icons.pending_outlined,
};

class _Message extends StatelessWidget {
  const _Message({required this.message, this.action});
  final String message;
  final VoidCallback? action;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(message, textAlign: TextAlign.center),
          if (action != null) ...[
            const SizedBox(height: 12),
            OutlinedButton(onPressed: action, child: const Text('重试')),
          ],
        ],
      ),
    ),
  );
}
