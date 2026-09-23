import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:supplier_app/main.dart';
import 'package:supplier_app/platform/platform_capabilities.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // Shell smoke only. This must never be cited as persistence or lock evidence.
  testWidgets('unverified target starts with production writes disabled', (
    tester,
  ) async {
    final report = await const UnverifiedPlatformProbe('runtime').inspect();
    expect(report.productionWritesAllowed, isFalse);
    await tester.pumpWidget(const SupplierProbeApp());
    await tester.pumpAndSettle();
    expect(find.text('业务写入已关闭'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
