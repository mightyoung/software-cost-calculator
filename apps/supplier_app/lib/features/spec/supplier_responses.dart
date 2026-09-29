import 'package:flutter/material.dart';
import 'package:supplier_core/supplier_core.dart';

import '../../app/app_state.dart';
import '../../app/theme.dart';
import 'spec_widgets.dart';

/// Each supplier's guarantee per clause, judged against the clause; a
/// stated 无偏离 the value contradicts is called out.
class SupplierResponses extends StatelessWidget {
  const SupplierResponses({
    super.key,
    required this.state,
    required this.item,
    required this.responses,
  });
  final AppState state;
  final Record item;
  final List<Record> responses;

  @override
  Widget build(BuildContext context) {
    final store = state.store;
    final checks = [
      for (final r in responses)
        (
          store
                  .get('supplier', r.data['supplier_id']! as String)
                  ?.data['name'] ??
              '?',
          store.checkResponse(item, r),
        ),
    ];
    final clauses = clausesOf(item);
    Widget cell(double w, Widget child) => Container(
      width: w,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        border: Border(
          right: BorderSide(color: Tokens.rule),
          bottom: BorderSide(color: Tokens.rule),
        ),
      ),
      child: child,
    );
    Widget answer(ResponseCheck x) {
      final (mark, color) = switch (x.checked) {
        Outcome.exact => ('✓', Tokens.green),
        Outcome.better => ('✓ +', Tokens.green),
        Outcome.worse => ('✗', Tokens.red),
        Outcome.unknown => ('?', Tokens.amber),
      };
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$mark  ${x.response ?? '未填写'}',
            style: TextStyle(color: color, fontWeight: FontWeight.w500),
          ),
          if (x.contradicted)
            Text(
              '声明${deviationLabels[x.stated]}，与数值不符',
              style: TextStyle(fontSize: 12, color: Tokens.red),
            )
          else if (x.why != null && x.checked != Outcome.exact)
            Text(x.why!, style: TextStyle(fontSize: 12, color: Tokens.ink3)),
          if (x.note case final n?)
            Text(n, style: TextStyle(fontSize: 12, color: Tokens.ink3)),
        ],
      );
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Container(
        decoration: BoxDecoration(
          color: Tokens.surface,
          border: Border.all(color: Tokens.rule),
          borderRadius: BorderRadius.circular(Tokens.radius),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  cell(260, Text('条款', style: TextStyle(color: Tokens.ink2))),
                  for (final (name, list) in checks)
                    cell(
                      200,
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '$name',
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          Text(
                            '负偏离 ${list.where((x) => x.checked == Outcome.worse).length}'
                            ' · 待确认 ${list.where((x) => x.checked == Outcome.unknown).length}',
                            style: TextStyle(fontSize: 12, color: Tokens.ink3),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            for (final (i, c) in clauses.indexed)
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    cell(
                      260,
                      Text(
                        '${markPrefix(c.mark)}${c.text}',
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    for (final (_, list) in checks) cell(200, answer(list[i])),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
