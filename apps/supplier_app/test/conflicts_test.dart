import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supplier_app/app/app_state.dart';
import 'package:supplier_app/app/theme.dart';
import 'package:supplier_app/features/exchange/conflicts_page.dart';
import 'package:supplier_core/supplier_core.dart';

Map<String, Object?> _supplier(String name, {String? address}) => {
  for (final f in Supplier.fields) f: null,
  'name': name,
  'aliases': <String>[],
  'categories': <String>[],
  'address': address,
};

void main() {
  testWidgets('a conflict is resolved by choosing a value', (tester) async {
    final dir = Directory.systemTemp.createTempSync('conflicts_test');
    addTearDown(() => dir.deleteSync(recursive: true));
    var tick = DateTime.utc(2026, 9, 1);
    DateTime clock() => tick = tick.add(const Duration(seconds: 1));
    final a = Store.open('${dir.path}/a.db', device: '采购部-01', clock: clock);
    final b = Store.open('${dir.path}/b.db', device: '采购部-02', clock: clock);
    addTearDown(a.close);
    addTearDown(b.close);
    final id = a.save('supplier', _supplier('甲泵业'));
    a.exportTo('${dir.path}/a1.siq');
    b.importFrom('${dir.path}/a1.siq');
    a.save('supplier', _supplier('甲泵业', address: '上海'), id: id);
    b.save('supplier', _supplier('甲泵业', address: '苏州'), id: id);
    b.exportTo('${dir.path}/b1.siq');
    a.importFrom('${dir.path}/b1.siq');
    final state = AppState.test(a, dir);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: ConflictsPage(state: state),
      ),
    );
    expect(find.text('供应商「甲泵业」 · 地址'), findsOneWidget);
    expect(find.textContaining('当前采用'), findsOneWidget);
    // Keep the value that is not in use.
    final other = a.get('supplier', id)!.data['address'] == '上海' ? '苏州' : '上海';
    await tester.tap(
      find.descendant(
        of: find.ancestor(of: find.text(other), matching: find.byType(Row)),
        matching: find.text('保留这个'),
      ),
    );
    await tester.pumpAndSettle();
    expect(a.get('supplier', id)!.data['address'], other);
    expect(find.text('没有待确认的冲突'), findsOneWidget);
  });
}
