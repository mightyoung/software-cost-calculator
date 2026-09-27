import 'package:flutter/material.dart';
import 'package:supplier_core/supplier_core.dart';

import '../../app/app_state.dart';
import '../../app/format.dart';
import '../../app/theme.dart';
import '../../widgets/ledger.dart';

const _entityLabels = {
  'supplier': '供应商',
  'contact': '联系人',
  'product': '物料',
  'project': '项目',
  'quotation': '报价',
  'project_item': '预算行',
};

Future<void> showConflicts(BuildContext context, AppState state) =>
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => ConflictsPage(state: state)));

/// Same field changed on two devices from the same starting value. The
/// newer edit is in effect; the user confirms which one stays.
class ConflictsPage extends StatelessWidget {
  const ConflictsPage({super.key, required this.state});
  final AppState state;

  String _title(FieldConflict c) {
    final store = state.store;
    final d = store.get(c.entity, c.entityId)?.data ?? const {};
    String? productName(Object? id) => id == null
        ? null
        : store.get('product', id as String)?.data['name'] as String?;
    final name = switch (c.entity) {
      'quotation' => productName(d['product_id']),
      'project_item' => d['name'] as String? ?? productName(d['product_id']),
      _ => d['name'] as String? ?? d['code'] as String?,
    };
    return '${_entityLabels[c.entity] ?? c.entity}「${name ?? '未命名'}」'
        ' · ${fieldLabels[c.field] ?? c.field}';
  }

  String _local(String at) {
    final t = DateTime.parse(at).toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
  }

  String _show(Object? v) => switch (v) {
    null => '（空）',
    List<Object?> l => l.isEmpty ? '（空）' : l.join('、'),
    _ => '$v',
  };

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(backgroundColor: Tokens.canvas, title: const Text('修改冲突')),
    body: ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final conflicts = state.store.openConflicts();
        if (conflicts.isEmpty) {
          return const EmptyState(title: '没有待确认的冲突', body: '两台设备改了同一处时会列在这里。');
        }
        return ListView(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
          children: [
            const Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: Text(
                '下面每一处都被两台设备同时修改过。目前采用的是时间较晚的修改，请确认要保留哪一个；'
                '确认结果会随同步与交换传到其他设备。',
                style: TextStyle(color: Tokens.ink2, height: 1.6),
              ),
            ),
            for (final c in conflicts) _card(context, c),
          ],
        );
      },
    ),
  );

  Widget _card(BuildContext context, FieldConflict c) {
    final current = state.store.get(c.entity, c.entityId)?.data[c.field];
    Widget option(FieldValue v) {
      final inUse = _show(v.value) == _show(current);
      return Container(
        margin: const EdgeInsets.only(top: 8),
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        decoration: BoxDecoration(
          color: inUse ? Tokens.accentTint : Tokens.sunken,
          borderRadius: BorderRadius.circular(Tokens.radius),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_show(v.value)),
                  Text(
                    '${v.device} · ${_local(v.at)}'
                    '${inUse ? ' · 当前采用' : ''}',
                    style: const TextStyle(fontSize: 12, color: Tokens.ink3),
                  ),
                ],
              ),
            ),
            TextButton(
              onPressed: () {
                final err = state.write((s) => s.resolveConflict(c, v.value));
                if (err != null) {
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(SnackBar(content: Text(err)));
                }
              },
              child: const Text('保留这个'),
            ),
          ],
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Tokens.surface,
        border: Border.all(color: Tokens.rule),
        borderRadius: BorderRadius.circular(Tokens.radius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(_title(c), style: const TextStyle(fontWeight: FontWeight.w600)),
          option(c.first),
          option(c.second),
        ],
      ),
    );
  }
}
