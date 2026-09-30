import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supplier_app/app/app_state.dart';
import 'package:supplier_app/app/theme.dart';
import 'package:supplier_app/features/catalog/catalog_page.dart';
import 'package:supplier_app/widgets/app_icon.dart';
import 'package:supplier_app/widgets/icon_paths.g.dart';
import 'package:supplier_app/widgets/material_icon.dart';
import 'package:supplier_core/supplier_core.dart';

void main() {
  test('explicit category wins and unknown categories remain generic', () {
    expect(
      materialIconFor(category: ' 阀门 ', name: '水泵测试配件'),
      Icons.tune_outlined,
    );
    expect(
      materialIconFor(category: '待分类', name: '离心水泵'),
      Icons.inventory_2_outlined,
    );
    expect(materialIconFor(), Icons.inventory_2_outlined);
    expect(materialIconFor(name: 'IS80-65-160'), Icons.inventory_2_outlined);
    expect(
      materialIconFor(category: ' ', name: '不锈钢离心泵'),
      Icons.water_drop_outlined,
    );
    expect(materialIconFor(name: '不锈钢弯头'), Icons.route_outlined);
  });

  test('all typical material categories have distinct custom geometry', () {
    const categories = [
      '水泵',
      '阀门',
      '管道',
      '管件',
      '法兰',
      '电机',
      '控制柜',
      '电缆',
      '仪表',
      '紧固件',
      '轴承',
      '钢材',
      '换热器',
      '储罐',
      '过滤器',
      '风机',
      '压缩机',
      '密封件',
      '服务器',
      '工控机',
      '电脑',
      '显示器',
      '物联网关',
      '交换机',
      '路由器',
    ];
    final icons = categories.map((c) => materialIconFor(category: c));
    expect(icons.toSet(), hasLength(categories.length));
    expect(icons.every(businessIconPaths.containsKey), isTrue);
    expect(
      icons.map((i) => businessIconPaths[i]).toSet(),
      hasLength(categories.length),
    );
  });

  test(
    'computing equipment uses specific categories before generic computer names',
    () {
      expect(
        materialIconFor(name: '工业平板电脑'),
        Icons.precision_manufacturing_outlined,
      );
      expect(materialIconFor(name: '电脑显示器'), Icons.monitor_outlined);
      expect(materialIconFor(name: '机架服务器'), Icons.dns_outlined);
      expect(materialIconFor(name: 'IoT Gateway'), Icons.device_hub_outlined);
      expect(
        materialIconFor(name: 'Ethernet Switch'),
        Icons.settings_ethernet_outlined,
      );
      expect(materialIconFor(name: '工业路由器'), Icons.router_outlined);
      expect(materialIconFor(name: '台式电脑'), Icons.desktop_windows_outlined);
      expect(
        materialIconFor(category: '显示器', name: '工业电脑配套'),
        Icons.monitor_outlined,
      );
      expect(
        materialIconFor(category: '待分类', name: '机架服务器'),
        Icons.inventory_2_outlined,
      );
    },
  );

  for (final brightness in Brightness.values) {
    testWidgets('material geometry paints in $brightness without errors', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(brightness: brightness),
          home: const Scaffold(body: MaterialIcon(category: '水泵')),
        ),
      );
      expect(find.byType(AppIcon), findsOneWidget);
      expect(find.byType(CustomPaint), findsWidgets);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('catalog adds category icon while keeping row data and search', (
    tester,
  ) async {
    final dir = Directory.systemTemp.createTempSync('material_icons');
    final store = Store.open('${dir.path}/c.db', device: '测试');
    final state = AppState.test(store, dir);
    addTearDown(() {
      store.close();
      dir.deleteSync(recursive: true);
    });
    for (final (name, category) in [('试验水泵', '水泵'), ('检修套装', '待分类')]) {
      store.save('product', {
        for (final f in Product.fields) f: null,
        'name': name,
        'unit': '件',
        'category': category,
      });
    }
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: Scaffold(
          body: CatalogPage(state: state, type: 'product'),
        ),
      ),
    );
    expect(find.byType(MaterialIcon), findsNWidgets(2));
    expect(find.text('试验水泵'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '检修');
    await tester.pumpAndSettle();
    expect(find.byType(MaterialIcon), findsOneWidget);
    expect(find.text('找到 1 个'), findsOneWidget);
    expect(store.productCategories(), containsAll(['水泵', '待分类']));
    expect(tester.takeException(), isNull);
  });
}
