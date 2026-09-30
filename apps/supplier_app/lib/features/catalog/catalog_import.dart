import 'package:flutter/material.dart';

import '../../app/motion.dart';
import 'package:supplier_core/supplier_core.dart';

import '../../app/app_state.dart';
import '../../app/theme.dart';
import '../../platform/files.dart';
import '../ai/material_import_page.dart';

/// Bulk import of an existing supplier or material list from Excel: the
/// first step for a new user. Nothing is written before confirming.
Future<void> importCatalogList(
  BuildContext context,
  AppState state,
  String type,
) async {
  final file = await pickBytesForUi(context, ['xlsx']);
  if (file == null || !context.mounted) return;
  final XWorkbook book;
  try {
    book = readXlsx(file.bytes);
  } on FormatException catch (e) {
    return toast(context, '无法读取 ${file.name}：${friendlyError(e.message)}');
  }
  if (type == 'product') {
    final offers = offersFromWorkbook(book, materials: true);
    if (offers == null || offers.isEmpty) {
      return toast(context, '没有找到物料表头：需要"名称"列，以及"类型""品牌""型号"或"技术参数"之一');
    }
    final msg = await showMaterialImport(
      context,
      state,
      table: (name: file.name, bytes: file.bytes, offers: offers),
      masterData: true,
    );
    if (msg != null && context.mounted) toast(context, msg);
    return;
  }
  final plans = state.store.planSupplierSheet(book);
  if (plans == null || plans.isEmpty) {
    return toast(context, '没有找到供应商表头：需要"供应商名称"或"名称"列');
  }
  final ok = await showAppDialog<bool>(
    context: context,
    builder: (_) => _SupplierPreview(name: file.name, plans: plans),
  );
  if (ok != true || !context.mounted) return;
  late ({int suppliers, int contacts}) sum;
  final err = state.write((s) => sum = s.applySupplierSheet(plans));
  toast(context, err ?? '新建供应商 ${sum.suppliers}，联系人 ${sum.contacts}');
}

class _SupplierPreview extends StatelessWidget {
  const _SupplierPreview({required this.name, required this.plans});
  final String name;
  final List<SupplierRowPlan> plans;

  @override
  Widget build(BuildContext context) {
    final errors = plans.where((p) => p.error != null).toList();
    final created = plans.where((p) => p.supplier != null).length;
    final existing = plans.where((p) => p.existingId != null).length;
    final contacts = plans
        .where((p) => p.error == null && p.contact != null)
        .length;
    return AlertDialog(
      scrollable: true,
      title: Text('导入供应商：$name'),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '新建 $created 家 · 已有 $existing 家（只补充新的联系人）· '
              '带联系方式 $contacts 行 · 有问题 ${errors.length} 行',
            ),
            const SizedBox(height: 4),
            Text(
              '名称与本机已有供应商相同（忽略"有限公司"等字样）时不会重复新建。',
              style: TextStyle(fontSize: 12, color: Tokens.ink3),
            ),
            for (final e in errors.take(8))
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  '第 ${e.row} 行：${friendlyError(e.error!)}',
                  style: TextStyle(color: Tokens.red),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: plans.length == errors.length
              ? null
              : () => Navigator.pop(context, true),
          child: const Text('确认导入'),
        ),
      ],
    );
  }
}
