import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supplier_app/main.dart';

void main() {
  testWidgets('shell exposes blocked gate and no business write action', (
    tester,
  ) async {
    await tester.pumpWidget(const SupplierProbeApp());
    await tester.pumpAndSettle();
    expect(find.text('业务写入已关闭'), findsOneWidget);
    expect(find.textContaining('不能证明数据持久化'), findsOneWidget);
    expect(find.byType(FloatingActionButton), findsNothing);
    expect(find.byType(TextField), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
