import 'package:flutter/material.dart';
import 'package:supplier_core/supplier_core.dart';

import '../../app/app_state.dart';
import '../../app/motion.dart';
import '../../app/theme.dart';
import '../../platform/files.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/ledger.dart';
import '../trash/trash_page.dart' show recordTitle;

/// Publishes one supplier or quotation to the company hub after showing
/// exactly which records go with it.
Future<void> showHubPublish(
  BuildContext context,
  AppState state, {
  required String type,
  required String id,
}) async {
  final HubClient? client;
  try {
    client = await state.hub();
  } on HubException catch (e) {
    if (context.mounted) toast(context, e.message);
    return;
  }
  if (!context.mounted) return;
  if (client == null) {
    return toast(context, '还没有连接公司资料中心：在 设置 › 公司资料中心 填写地址');
  }
  final revision = await showDialog<int>(
    context: context,
    builder: (_) =>
        _PublishDialog(state: state, client: client!, type: type, id: id),
  );
  if (revision != null && context.mounted) {
    toast(context, '已发布到公司资料（第 $revision 版）');
  }
}

class _PublishDialog extends StatefulWidget {
  const _PublishDialog({
    required this.state,
    required this.client,
    required this.type,
    required this.id,
  });
  final AppState state;
  final HubClient client;
  final String type, id;

  @override
  State<_PublishDialog> createState() => _PublishDialogState();
}

class _PublishDialogState extends State<_PublishDialog> {
  HubDraft? draft;
  String? error;
  bool busy = true, contacts = false;
  Store get store => widget.state.store;

  late final contactCount = widget.type == 'supplier'
      ? store.db.select(
              "SELECT count(*) AS n FROM contact WHERE deleted = 0 "
              "AND json_extract(data,'\$.supplier_id') = ?",
              [widget.id],
            ).first['n']
            as int
      : 0;

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  Future<void> _prepare() async {
    setState(() {
      busy = true;
      error = null;
      draft = null;
    });
    try {
      final d = await prepareHubPublication(
        widget.client,
        store,
        type: widget.type,
        id: widget.id,
        includeContacts: contacts,
      );
      if (mounted) setState(() => draft = d);
    } on HubException catch (e) {
      if (mounted) setState(() => error = e.message);
    } on StateError catch (e) {
      if (mounted) setState(() => error = '不能发布：${e.message}');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _publish() async {
    final d = draft;
    if (d == null || busy) return;
    setState(() => busy = true);
    try {
      final receipt = await widget.client.publish(d.draft);
      if (mounted) Navigator.pop(context, receipt['revision'] as int?);
    } on HubException catch (e) {
      if (mounted) {
        setState(() {
          error = e.message;
          busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = draft;
    return AlertDialog(
      title: const Text('发布到公司资料'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '发布后，能访问公司资料中心的同事都能查到这些内容；撤回需要中心管理员操作。',
                style: TextStyle(color: Tokens.ink2, height: 1.5),
              ),
              if (contactCount > 0) ...[
                const SizedBox(height: 8),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: contacts,
                  onChanged: busy
                      ? null
                      : (v) {
                          setState(() => contacts = v ?? false);
                          _prepare();
                        },
                  title: Text('同时共享联系人（$contactCount 位）'),
                  subtitle: const Text('包含姓名和电话、微信、邮箱，请确认对方同意'),
                ),
              ],
              const SizedBox(height: 12),
              if (error != null) ...[
                Text(error!, style: TextStyle(color: Tokens.red)),
                const SizedBox(height: 8),
                OutlinedButton(
                  onPressed: busy ? null : _prepare,
                  child: const Text('重新核对'),
                ),
              ] else if (d == null)
                const Row(
                  children: [
                    SizedBox.square(
                      dimension: 16,
                      child: TaskProgress(compact: true),
                    ),
                    SizedBox(width: 8),
                    Expanded(child: Text('正在与中心核对…')),
                  ],
                )
              else
                ..._records(d),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton.icon(
          onPressed: busy || d == null || d.upToDate || error != null
              ? null
              : _publish,
          icon: const AppIcon(Icons.upload_file_outlined, size: 18),
          label: const Text('发布'),
        ),
      ],
    );
  }

  List<Widget> _records(HubDraft d) {
    final projects = [
      for (final r in d.records)
        if (r['entity_type'] == 'project') r['data']! as Map<String, Object?>,
    ];
    return [
      Text(
        d.upToDate
            ? '中心已是最新（第 ${d.previous} 版），无需再次发布。'
            : d.previous == 0
            ? '首次发布，共 ${d.records.length} 条记录：'
            : '将更新为第 ${d.previous + 1} 版，共 ${d.records.length} 条记录：',
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 8),
      for (final r in d.records)
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 64,
                child: Text(
                  ontology[r['entity_type']]?.label ?? '${r['entity_type']}',
                  style: TextStyle(fontSize: 12, color: Tokens.ink3),
                ),
              ),
              Expanded(
                child: Text(
                  recordTitle(
                    store,
                    r['entity_type']! as String,
                    r['data']! as Map<String, Object?>,
                  ),
                ),
              ),
            ],
          ),
        ),
      for (final p in projects) ...[
        const SizedBox(height: 6),
        HintText('包含项目「${p['name']}」的客户、合同金额等信息', icon: Icons.error_outline),
      ],
    ];
  }
}
