import 'package:flutter/material.dart';
import 'package:supplier_core/supplier_core.dart';

import '../../app/app_state.dart';
import '../../app/format.dart';
import '../../app/theme.dart';
import '../../platform/files.dart';
import '../../widgets/ledger.dart';

Future<void> showTrash(BuildContext context, AppState state) => Navigator.of(
  context,
).push(MaterialPageRoute<void>(builder: (_) => TrashPage(state: state)));

/// How a record is named in the bin.
String recordTitle(Store store, String type, Map<String, Object?> d) {
  String? name(String t, Object? id) =>
      id is String ? store.get(t, id)?.data['name'] as String? : null;
  return switch (type) {
    'quotation' => [
      name('product', d['product_id']),
      name('supplier', d['supplier_id']),
      money(d['price'] as String?, prefix: '¥'),
    ].whereType<String>().join(' · '),
    'project_item' =>
      (d['name'] ?? name('product', d['product_id']) ?? '预算行') as String,
    'inquiry' => d['title'] as String? ?? '询价单',
    _ => d['name'] as String? ?? '',
  };
}

/// Recently deleted records, each restorable.
class TrashPage extends StatelessWidget {
  const TrashPage({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(backgroundColor: Tokens.canvas, title: const Text('已删除的记录')),
    body: ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final bin = state.store.deletedRecords();
        if (bin.isEmpty) {
          return const EmptyState(
            title: '没有已删除的记录',
            body: '删除的供应商、物料、项目、报价等会出现在这里，可以随时恢复。',
          );
        }
        return ListView(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
          children: [
            const Padding(
              padding: EdgeInsets.only(bottom: 10),
              child: Text(
                '恢复后记录回到原处，并随同步与交换传到其他设备。',
                style: TextStyle(color: Tokens.ink2),
              ),
            ),
            Container(
              decoration: BoxDecoration(
                color: Tokens.surface,
                border: Border.all(color: Tokens.rule),
                borderRadius: BorderRadius.circular(Tokens.radius),
              ),
              child: Column(
                children: [
                  for (final (i, r) in bin.indexed)
                    Container(
                      padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
                      decoration: BoxDecoration(
                        border: i == 0
                            ? null
                            : const Border(top: BorderSide(color: Tokens.rule)),
                      ),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 64,
                            child: Text(
                              ontology[r.type]!.label,
                              style: const TextStyle(color: Tokens.ink3),
                            ),
                          ),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(recordTitle(state.store, r.type, r.data)),
                                Text(
                                  '${r.at.substring(0, 16).replaceFirst('T', ' ')} 由 ${r.by} 删除',
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: Tokens.ink3,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          TextButton(
                            onPressed: () {
                              final err = state.write(
                                (s) => s.restore(r.type, r.id),
                              );
                              toast(context, err ?? '已恢复');
                            },
                            child: const Text('恢复'),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
        );
      },
    ),
  );
}
