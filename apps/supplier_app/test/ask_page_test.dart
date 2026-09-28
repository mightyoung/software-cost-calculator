import 'package:supplier_app/app/theme.dart';
import 'package:supplier_app/app/app_state.dart';
import 'package:flutter/material.dart';
import 'dart:io';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:supplier_app/features/ai/ask_page.dart';
import 'package:supplier_core/supplier_core.dart';

const _id = '546aff01-c05c-4e08-ac41-09ffc126235a';

void main() {
  test('answers keep record marks and lose stray ids', () {
    final mark = '[[supplier:$_id|甲泵业]]';
    expect(tidyAnswer('$mark 报价最低（ID $_id），交期 15 天。'), '$mark 报价最低，交期 15 天。');
    expect(tidyAnswer('配电柜更换项目（编号 P-002，ID `$_id`）没有预算行'), '配电柜更换项目没有预算行');
    expect(tidyAnswer('离心水泵，id：`$_id`，单位台'), '离心水泵，单位台');
    final m = recordRef.firstMatch(tidyAnswer('见 $mark'))!;
    expect([m[1], m[2], m[3]], ['supplier', _id, '甲泵业']);
  });

  testWidgets('earlier questions stay until cleared', (tester) async {
    final dir = Directory.systemTemp.createTempSync('ask_history');
    addTearDown(() => dir.deleteSync(recursive: true));
    final store = Store.open('${dir.path}/a.db', device: '测试机');
    addTearDown(store.close);
    final state = AppState.test(store, dir)
      ..saveSetting(
        'ask_history',
        jsonEncode([
          [true, '离心泵最低价？', false],
          [false, '目前最低 3,200 元。', false],
        ]),
      );
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: Scaffold(body: AskPage(state: state)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('离心泵最低价？'), findsOneWidget);
    await tester.tap(find.text('清空记录'));
    await tester.pumpAndSettle();
    expect(find.text('离心泵最低价？'), findsNothing);
    expect(state.setting('ask_history'), isNull);
  });
}
