// Local visual check: renders key screens with a real CJK font into
// test/screens/*.png. Skipped where the macOS system font is unavailable.
//   flutter test test/screenshot_test.dart --update-goldens
@Tags(['screenshot'])
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supplier_app/app/app_state.dart';
import 'package:supplier_app/app/shell.dart';
import 'package:supplier_app/features/spec/param_view.dart';
import 'package:supplier_app/features/spec/spec_match_page.dart';
import 'package:supplier_app/features/spec/spec_request_page.dart';

import 'spec_match_page_test.dart' show seedSensors;
import 'package:supplier_app/app/theme.dart';
import 'package:supplier_app/features/ai/list_review.dart';
import 'package:supplier_app/features/ai/material_import_page.dart';
import 'package:supplier_app/features/ai/material_review.dart';
import 'package:supplier_app/features/catalog/catalog_page.dart';
import 'package:supplier_app/features/exchange/conflicts_page.dart';
import 'package:supplier_app/features/exchange/lan_push_page.dart';
import 'package:supplier_app/features/inquiries/inquiry_page.dart';
import 'package:supplier_core/supplier_core.dart';

const _font = '/System/Library/Fonts/Supplemental/Arial Unicode.ttf';

Map<String, Object?> _b(List<String> f, Map<String, Object?> v) => {
  for (final k in f) k: null,
  ...v,
};

void _seed(Store s) {
  final today = localDay(s.clock());
  String sup(String n) => s.save(
    'supplier',
    _b(Supplier.fields, {
      'name': n,
      'aliases': <String>[],
      'categories': <String>[],
    }),
  );
  String prod(String n, String unit, String model, [String? spec]) => s.save(
    'product',
    _b(Product.fields, {
      'name': n,
      'unit': unit,
      'model': model,
      'specification': spec,
    }),
  );
  final p = s.save(
    'project',
    _b(Project.fields, {
      'code': '2026-WH01-015',
      'name': '泵房改造工程',
      'status': 'active',
      'type': 'market',
      'level': 'A',
      'customer': '华东水务',
      'leader': '王工',
      'contract_no': 'HD-2026-0412',
      'contract_amount': '205000',
      'currency': 'CNY',
      'tax_mode': 'included',
      'markup_rate': '15',
    }),
  );
  s.save(
    'project',
    _b(Project.fields, {
      'code': '2026-WH01-014',
      'name': '二期配电柜更换',
      'status': 'active',
      'customer': '江南化工',
      'currency': 'CNY',
      'tax_mode': 'included',
      'markup_rate': '10',
    }),
  );
  String quote(
    String supplier,
    String product,
    String price, {
    String? until,
    String? quoted,
  }) => s.save(
    'quotation',
    _b(Quotation.fields, {
      'supplier_id': supplier,
      'product_id': product,
      'project_id': p,
      'price': price,
      'currency': 'CNY',
      'tax_mode': 'included',
      'unit_snapshot': s.get('product', product)!.data['unit'],
      'min_qty': '1',
      'quoted_on': quoted ?? today,
      'valid_until': until,
      'inquirer_name': '王工',
      'inquiry_precision': 'date',
      'inquiry_date': today,
      'capture_mode': 'standard',
    }),
  );
  void line(Map<String, Object?> v) => s.save(
    'project_item',
    _b(ProjectItem.fields, {'project_id': p, 'qty': '1', ...v}),
  );
  final pump = prod('不锈钢离心泵', '台', 'IS80-65-160', '304');
  final cab = prod('变频控制柜', '面', '15kW 一拖二');
  final valve = prod('闸阀', '个', 'Z41H-16C DN100');
  final cable = prod('动力电缆', '米', 'YJV-4×25');
  final q1 = quote(sup('甲泵业'), pump, '32500');
  quote(sup('乙机电'), pump, '29800');
  final q2 = quote(sup('申江电气'), cab, '48600');
  final q3 = quote(sup('永泰阀门'), valve, '1205');
  final q4 = quote(
    sup('宝胜电缆'),
    cable,
    '135',
    quoted: '2026-01-05',
    until: '2026-01-31',
  );
  line({
    'category': 'material',
    'product_id': pump,
    'quotation_id': q1,
    'qty': '2',
    'unit': '台',
    'unit_cost': '32500',
  });
  line({
    'category': 'material',
    'product_id': cab,
    'quotation_id': q2,
    'unit': '面',
    'unit_cost': '48600',
  });
  line({
    'category': 'material',
    'product_id': valve,
    'quotation_id': q3,
    'qty': '4',
    'unit': '个',
    'unit_cost': '1205',
  });
  line({
    'category': 'material',
    'name': '电磁流量计',
    'unit': '台',
    'unit_cost': '0',
    'notes': '要求：DN100，远传 4–20mA',
  });
  line({
    'category': 'material',
    'product_id': cable,
    'quotation_id': q4,
    'qty': '300',
    'unit': '米',
    'unit_cost': '135',
  });
  line({
    'category': 'labor',
    'name': '设备安装调试',
    'unit': '项',
    'unit_cost': '18000',
  });
  line({
    'category': 'labor',
    'name': '电缆敷设',
    'qty': '300',
    'unit': '米',
    'unit_cost': '13',
  });
  line({
    'category': 'other',
    'name': '运输及吊装',
    'unit': '项',
    'unit_cost': '6000',
  });
}

const _list =
    '泵房改造询价清单\n1. 不锈钢离心泵，Q=100m3/h，H=32m，2台（一用一备）\n2. 闸阀 DN100 PN16 ×4\n3. 动力电缆 YJV 4*25，约 300m\n4. 电磁流量计 DN100 远传 1台\n合计：略';

List<ProposedLine> _proposals(Store s) {
  Hit find(String word) => s.searchProducts([word]).first;
  ProposedLine line(
    String name,
    String? req,
    String qty,
    String unit,
    Hit? hit,
    String conf,
    String? reason,
  ) => ProposedLine(
    RequestedItem(name, req, qty, unit, [name]),
    hit == null ? const [] : [hit],
    productId: hit?.id,
    confidence: conf,
    reason: reason,
  );
  return [
    line(
      '不锈钢离心泵',
      'Q=100m³/h，H=32m',
      '2',
      '台',
      find('离心泵'),
      'high',
      '流量、扬程、材质一致',
    ),
    line('闸阀 DN100 PN16', null, '4', '个', find('闸阀'), 'high', '规格一致'),
    line('动力电缆', 'YJV 4*25', '约300', '米', find('电缆'), 'medium', '规格一致，电压等级未写明'),
    line('电磁流量计', 'DN100 远传', '1', '台', null, 'low', null),
  ];
}

const _pasted = '''张经理（甲泵业）13812345678：
不锈钢离心泵 IS80-65-160，304 材质，Q=50m³/h H=32m，含税 31800 元/台，交期 20 天，报价有效期到 10 月 31 日。
永泰阀门 李工 微信 yongtai_li：闸阀 Z41H-16C DN100，不含税 1180/个。
华通仪表 陈经理 chen@huatong.cn
1. 电磁流量计 LDG-100，DN100，远传 4-20mA，6850 元
2. 压力变送器 0-1.6MPa，价格另报
宝胜电缆：耐火电缆 NH-YJV 4×25，面议''';

Widget _importScreen(String name, AppState state) {
  if (name == 'desktop_import_input') return MaterialImportPage(state: state);
  Offer o(Map<String, Object?> raw) => cleanOffer(raw);
  final offers = [
    o({
      'supplier': '甲泵业',
      'contact_name': '张经理',
      'phone': '13812345678',
      'name': '不锈钢离心泵',
      'model': 'IS80-65-160',
      'specification': '304 材质，Q=50m³/h，H=32m',
      'unit': '台',
      'price': '3180',
      'tax_mode': 'included',
      'valid_until': '2026-10-31',
      'lead_time_days': '20',
    }),
    o({
      'supplier': '永泰阀门有限公司',
      'contact_name': '李工',
      'wechat': 'yongtai_li',
      'name': '闸阀',
      'model': 'Z41H-16C DN100',
      'unit': '个',
      'price': '1180',
      'tax_mode': 'excluded',
    }),
    o({
      'supplier': '华通仪表',
      'contact_name': '陈经理',
      'email': 'chen@huatong.cn',
      'name': '电磁流量计',
      'model': 'LDG-100',
      'specification': 'DN100，远传 4-20mA',
      'unit': '台',
      'price': '6850',
    }),
    o({
      'supplier': '华通仪表',
      'contact_name': '陈经理',
      'email': 'chen@huatong.cn',
      'name': '压力变送器',
      'specification': '0-1.6MPa',
      'unit': '台',
      'notes': '价格另报',
    }),
    o({
      'supplier': '宝胜电缆',
      'name': '耐火电缆',
      'model': 'NH-YJV 4×25',
      'price': '面议',
    }),
  ];
  return Scaffold(
    appBar: AppBar(
      backgroundColor: Tokens.canvas,
      title: const Text('智能导入报价 · 核对'),
    ),
    body: MaterialReview(
      state: state,
      plans: [
        for (final x in offers) state.store.planOffer(x, source: _pasted),
      ],
      onBack: () {},
    ),
  );
}

/// An inquiry on the pump-room project: three lines, three suppliers.
/// Matching page over three sample sensors.
Widget _specMatch(Store store, AppState state) {
  seedSensors(store);
  return SpecMatchPage(state: state);
}

Widget _specRequest(Store store, AppState state) {
  seedSensors(store);
  final req = store.createSpecRequest('泵房监控系统技术要求', [
    draftItem(
      '温湿度传感器',
      '（1）测量范围，温度-20℃~+80℃；相对湿度：0%~+100%RH。\n'
          '（2）测量精度要求：温度优于±0.3℃，相对湿度优于±3%。\n'
          '（3）输出信号4-20mA或RS485标准工业信号，与温湿度监控系统控制器或采集器适配。\n'
          '★（4）防护等级不低于IP65。\n'
          '（5）防爆等级不低于EX d IIBT4 Gb。',
      qty: '25',
      unit: '个',
    ),
    draftItem('工控机', 'CPU：八核及以上，主频2.3GHz及以上；内存：DDR4 16GB', qty: '5', unit: '台'),
    draftItem('显示器', '尺寸不小于27英寸，最佳固有分辨率不小于2K', qty: '7', unit: '台'),
  ]);
  return SpecRequestPage(state: state, requestId: req);
}

Widget _paramView(Store store, AppState state) {
  seedSensors(store);
  final id = store.save('product', {
    for (final f in Product.fields) f: null,
    'name': '温湿度变送器',
    'unit': '个',
    'model': 'THT-3',
    'specification': '测量范围-30~70℃；湿度0~100%RH；精度±0.3℃；RS485输出；IP65',
  });
  store.applyParamFill(store.planParamFill(productIds: [id]));
  return ParamViewPage(state: state);
}

/// The workbench with an open inquiry waiting for replies.
Shell _home(Store store, AppState state) {
  _inquiry(store);
  return Shell(state: state);
}

String _inquiry(Store store) {
  String supplierId(String n) => store.searchByName('supplier', n).first.id;
  final project = store.searchByName('project', '泵房改造工程').single.id;
  final lines = {
    for (final l in store.budget(project, withWarnings: false).lines)
      if (l.data['category'] == 'material')
        (l.data['name'] as String?) ??
            store.get('product', l.data['product_id']! as String)!.data['name']!
                as String: l
            .id,
  };
  final jia = supplierId('甲泵业'), yi = supplierId('乙机电');
  final yt = supplierId('永泰阀门');
  final inq = store.createInquiry(
    project,
    '泵房改造 · 泵阀仪表询价',
    itemIds: [lines['不锈钢离心泵']!, lines['闸阀']!, lines['电磁流量计']!],
    supplierIds: [jia, yi, yt],
  );
  const ctx = (inquirer: '王工', asOf: null);
  final won = store.quoteForInquiry(
    inq,
    lines['不锈钢离心泵']!,
    jia,
    price: '31800',
    includes: const ['freight', 'installation'],
    leadTimeDays: 20,
    context: ctx,
  );
  store.quoteForInquiry(
    inq,
    lines['不锈钢离心泵']!,
    yi,
    price: '29800',
    extraCost: '3000',
    includes: const [],
    leadTimeDays: 30,
    context: ctx,
  );
  store.quoteForInquiry(
    inq,
    lines['闸阀']!,
    yi,
    price: '1250',
    includes: const ['freight'],
    context: ctx,
  );
  store.quoteForInquiry(
    inq,
    lines['闸阀']!,
    yt,
    price: '1180',
    taxMode: 'excluded',
    context: ctx,
  );
  store.quoteForInquiry(
    inq,
    lines['电磁流量计']!,
    jia,
    price: '6850',
    leadTimeDays: 15,
    context: ctx,
  );
  store.award(
    won,
    itemId: lines['不锈钢离心泵'],
    dealPrice: '31000',
    note: '含运输安装，交期最短',
  );
  return inq;
}

/// Deterministic clock so timestamps in the picture never change.
DateTime Function() _fixedClock() {
  var t = DateTime(2026, 9, 20, 14, 30);
  return () => t = t.add(const Duration(seconds: 1));
}

/// Two devices change the same supplier's address and phone-less notes.
void _conflict(Store store, Directory dir) {
  final other = Store.open(
    '${dir.path}/other.db',
    device: '采购部-02',
    clock: _fixedClock(),
  );
  final id = store.searchByName('supplier', '永泰阀门').single.id;
  store.exportTo('${dir.path}/a.siq');
  other.importFrom('${dir.path}/a.siq');
  final base = store.get('supplier', id)!.data;
  store.save('supplier', {...base, 'address': '温州市龙湾区永强大道 88 号'}, id: id);
  other.save('supplier', {...base, 'address': '温州市瓯海区娄桥工业园 12 号'}, id: id);
  final pump = store.searchProducts(['离心泵']).first;
  final pBase = store.get('product', pump.id)!.data;
  store.save('product', {
    ...pBase,
    'specification': '304 不锈钢，Q=50m³/h',
  }, id: pump.id);
  other.save('product', {
    ...pBase,
    'specification': '316L 不锈钢，Q=50m³/h',
  }, id: pump.id);
  other.exportTo('${dir.path}/b.siq');
  store.importFrom('${dir.path}/b.siq');
  other.close();
}

void main() {
  final hasFont = File(_font).existsSync();
  TestWidgetsFlutterBinding.ensureInitialized();
  const storage = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(storage, null),
  );

  setUpAll(() async {
    if (!hasFont) return;
    final bytes = File(_font).readAsBytesSync();
    for (final family in ['Roboto', ...fontFallback, 'monospace']) {
      final loader = FontLoader(family)
        ..addFont(Future.value(ByteData.sublistView(bytes)));
      await loader.load();
    }
    // Codes use the platform monospace (Consolas on Windows, Menlo on
    // macOS); the shots stand in Andale Mono (no CJK, like Consolas) under the first name of that stack.
    const mono = '/System/Library/Fonts/Supplemental/Andale Mono.ttf';
    if (File(mono).existsSync()) {
      // Every name of the stack, so none falls to the test font's boxes.
      for (final family in [monoFamily, ...monoFallback.take(3)]) {
        final loader = FontLoader(family)
          ..addFont(
            Future.value(ByteData.sublistView(File(mono).readAsBytesSync())),
          );
        await loader.load();
      }
    }
    final icons = File(
      '${Platform.environment['FLUTTER_ROOT']}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    );
    if (icons.existsSync()) {
      final loader = FontLoader('MaterialIcons')
        ..addFont(Future.value(ByteData.sublistView(icons.readAsBytesSync())));
      await loader.load();
    }
  });

  Future<void> shoot(
    WidgetTester tester,
    Size size,
    String name, [
    Future<void> Function()? act,
  ]) async {
    // dark_* shots are the desktop_* scene in the dark appearance.
    final golden = name;
    if (name.startsWith('dark_')) {
      Tokens.dark = true;
      addTearDown(() => Tokens.dark = false);
      name = name.replaceFirst('dark_', 'desktop_');
    }
    final dir = Directory.systemTemp.createTempSync('shot');
    final store = Store.open(
      '${dir.path}/s.db',
      device: '采购部-01',
      // Fixed so dates and validity in the shots never drift.
      clock: _fixedClock(),
    );
    _seed(store);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = AppState.test(store, dir);
    if (name == 'desktop_conflicts') _conflict(store, dir);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildTheme(),
        home: name == 'desktop_conflicts'
            ? ConflictsPage(state: state)
            : name == 'desktop_spec_match'
            ? _specMatch(store, state)
            : name == 'desktop_spec_request'
            ? _specRequest(store, state)
            : name == 'desktop_param_view'
            ? _paramView(store, state)
            : name == 'desktop_inquiry'
            ? InquiryPage(state: state, id: _inquiry(store))
            : name.contains('import')
            ? _importScreen(name, state)
            : name == 'desktop_review'
            ? Scaffold(
                appBar: AppBar(
                  backgroundColor: Tokens.canvas,
                  title: const Text('按清单建项目 · 核对匹配'),
                ),
                body: ListReview(
                  state: state,
                  source: _list,
                  sourceName: '泵房改造询价清单.xlsx',
                  lines: _proposals(store),
                  currency: 'CNY',
                  taxMode: 'included',
                  onBack: () {},
                ),
              )
            : name.startsWith('desktop_home')
            ? _home(store, state)
            : Shell(state: state, initial: Section.projects),
      ),
    );
    await tester.pumpAndSettle();
    if (act != null) await act();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('screens/$golden.png'),
    );
    store.close();
  }

  for (final (scene, act) in [
    ('dark_home', null),
    (
      'dark_budget',
      (WidgetTester t) async {
        await t.tap(find.text('泵房改造工程'));
        await t.pumpAndSettle();
      },
    ),
    (
      'dark_quotes',
      (WidgetTester t) async {
        await t.tap(find.text('报价').first);
        await t.pumpAndSettle();
      },
    ),
    ('dark_inquiry', null),
  ]) {
    testWidgets(
      'dark appearance $scene',
      (t) => shoot(
        t,
        const Size(1280, 800),
        scene,
        act == null ? null : () => act(t),
      ),
      skip: !hasFont,
    );
  }

  testWidgets(
    'desktop material form with typed parameters',
    (t) => shoot(t, const Size(1280, 1000), 'desktop_params_form', () async {
      await t.tap(find.text('物料').first);
      await t.pumpAndSettle();
      await t.tap(find.text('新建物料'));
      await t.pumpAndSettle();
      await t.enterText(find.widgetWithText(TextField, '物料名称'), '温湿度变送器');
      await t.enterText(find.widgetWithText(TextField, '单位'), '个');
      await t.pumpAndSettle();
      await t.tap(find.text('用「温湿度传感器」'));
      await t.pumpAndSettle();
      await t.enterText(
        find.widgetWithText(TextField, '温度测量范围 ·关键'),
        '-40~85℃',
      );
      await t.enterText(find.widgetWithText(TextField, '温度精度 ·关键'), '±0.2');
      await t.enterText(find.widgetWithText(TextField, '温度分辨率'), '0.1');
      await t.pumpAndSettle();
      await t.drag(
        find.byType(SingleChildScrollView).last,
        const Offset(0, -260),
      );
      await t.pumpAndSettle();
    }),
    skip: !hasFont,
  );

  testWidgets(
    'desktop param view',
    (t) => shoot(t, const Size(1280, 800), 'desktop_param_view', () async {
      await t.tap(find.byType(DropdownButtonFormField<String>));
      await t.pumpAndSettle();
      await t.tap(find.text('温湿度传感器').last);
      await t.pumpAndSettle();
    }),
    skip: !hasFont,
  );

  testWidgets(
    'desktop spec request',
    (t) => shoot(t, const Size(1280, 900), 'desktop_spec_request'),
    skip: !hasFont,
  );

  testWidgets(
    'desktop spec match',
    (t) => shoot(t, const Size(1280, 900), 'desktop_spec_match', () async {
      await t.tap(find.byType(DropdownButtonFormField<String?>));
      await t.pumpAndSettle();
      await t.tap(find.text('温湿度传感器').last);
      await t.pumpAndSettle();
      final values = find.widgetWithText(TextField, '要求值');
      await t.enterText(values.at(0), '-20~80℃');
      await t.enterText(values.at(2), '±0.3℃');
      await t.enterText(values.at(4), '4-20mA或RS485');
      await t.tap(find.text('添加条件'));
      await t.pumpAndSettle();
      await t.tap(
        find.widgetWithText(DropdownButtonFormField<String>, '参数').last,
      );
      await t.pumpAndSettle();
      await t.tap(find.text('防爆标志').last);
      await t.pumpAndSettle();
      await t.enterText(values.last, 'Ex d IIB T4 Gb');
      await t.pumpAndSettle();
      await t.drag(find.byType(ListView).first, const Offset(0, -420));
      await t.pumpAndSettle();
      await t.tap(find.text('显示不满足的 1 个物料'));
      await t.pumpAndSettle();
    }),
    skip: !hasFont,
  );

  testWidgets(
    'desktop home',
    (t) => shoot(t, const Size(1280, 800), 'desktop_home'),
    skip: !hasFont,
  );

  testWidgets(
    'desktop command palette',
    (t) => shoot(t, const Size(1280, 800), 'desktop_home_palette', () async {
      await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await t.sendKeyEvent(LogicalKeyboardKey.keyK);
      await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await t.pumpAndSettle();
      await t.enterText(find.byType(TextField).last, 'lxb');
      await t.pumpAndSettle();
    }),
    skip: !hasFont,
  );

  testWidgets(
    'desktop project budget',
    (t) => shoot(t, const Size(1280, 800), 'desktop_budget', () async {
      await t.tap(find.text('泵房改造工程'));
      await t.pumpAndSettle();
    }),
    skip: !hasFont,
  );

  testWidgets(
    'desktop add material panel',
    (t) => shoot(t, const Size(1280, 800), 'desktop_add', () async {
      await t.tap(find.text('泵房改造工程'));
      await t.pumpAndSettle();
      await t.tap(find.text('添加物料').first);
      await t.pumpAndSettle();
    }),
    skip: !hasFont,
  );

  testWidgets(
    'phone project list',
    (t) => shoot(t, const Size(390, 844), 'phone_projects'),
    skip: !hasFont,
  );

  testWidgets(
    'phone project budget',
    (t) => shoot(t, const Size(390, 844), 'phone_budget', () async {
      await t.tap(find.text('泵房改造工程'));
      await t.pumpAndSettle();
    }),
    skip: !hasFont,
  );

  testWidgets(
    'desktop list review',
    (t) => shoot(t, const Size(1280, 800), 'desktop_review'),
    skip: !hasFont,
  );

  testWidgets(
    'desktop ask data',
    (t) => shoot(t, const Size(1280, 800), 'desktop_ask', () async {
      await t.tap(find.text('问数据'));
      await t.pumpAndSettle();
    }),
    skip: !hasFont,
  );

  testWidgets(
    'desktop settings',
    (t) => shoot(t, const Size(1280, 800), 'desktop_settings', () async {
      await t.tap(find.text('设置'));
      await t.pumpAndSettle();
    }),
    skip: !hasFont,
  );

  testWidgets(
    'desktop quote comparison',
    (t) => shoot(t, const Size(1280, 800), 'desktop_compare', () async {
      await t.tap(find.text('报价').first);
      await t.pumpAndSettle();
      await t.enterText(find.byType(TextField).first, '离心泵');
      await t.pumpAndSettle();
      await t.tap(find.byType(ActionChip).first);
      await t.pumpAndSettle();
    }),
    skip: !hasFont,
  );
  testWidgets(
    'desktop smart import input',
    (t) => shoot(t, const Size(1280, 800), 'desktop_import_input', () async {
      await t.enterText(find.byType(TextField), _pasted);
      await t.pumpAndSettle();
    }),
    skip: !hasFont,
  );
  testWidgets(
    'desktop smart import review',
    (t) => shoot(t, const Size(1280, 800), 'desktop_import_review'),
    skip: !hasFont,
  );
  testWidgets(
    'phone smart import review',
    (t) => shoot(t, const Size(390, 844), 'phone_import_review'),
    skip: !hasFont,
  );
  testWidgets(
    'desktop duplicate supplier hint',
    (t) => shoot(t, const Size(1280, 800), 'desktop_duplicate', () async {
      final shell = find.byType(Shell);
      final state = t.widget<Shell>(shell).state;
      final dup = state.store.save('supplier', {
        for (final f in Supplier.fields) f: null,
        'name': '永泰阀门有限公司',
        'aliases': <String>[],
        'categories': <String>[],
      });
      showCatalogForm(t.element(shell), state, 'supplier', id: dup);
      await t.pumpAndSettle();
    }),
    skip: !hasFont,
  );
  testWidgets(
    'desktop conflicts',
    (t) => shoot(t, const Size(1280, 800), 'desktop_conflicts'),
    skip: !hasFont,
  );
  testWidgets(
    'desktop inquiry matrix',
    (t) => shoot(t, const Size(1280, 800), 'desktop_inquiry'),
    skip: !hasFont,
  );
  testWidgets(
    'desktop material form with key attributes',
    (t) => shoot(t, const Size(1280, 860), 'desktop_product_form', () async {
      final shell = find.byType(Shell);
      final state = t.widget<Shell>(shell).state;
      final store = state.store;
      final pump = store.searchProducts(['离心泵']).first;
      store.save('product', {
        ...pump.data,
        'category': '水泵',
        'attributes': {'流量': '50m³/h', '扬程': '32m', '材质': '304 不锈钢'},
      }, id: pump.id);
      store.save('product', {
        for (final f in Product.fields) f: null,
        'name': '管道泵',
        'unit': '台',
        'category': '水泵',
        'attributes': {'流量': '25m³/h', '功率': '4kW'},
      });
      showCatalogForm(t.element(shell), state, 'product', id: pump.id);
      await t.pumpAndSettle();
    }),
    skip: !hasFont,
  );
  testWidgets(
    'desktop exchange with shared folder and update notice',
    (t) => shoot(t, const Size(1280, 860), 'desktop_exchange', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(storage, (_) async => null);
      final state = t.widget<Shell>(find.byType(Shell)).state;
      final shared = Directory('${Directory.systemTemp.path}/siq-shot-shared');
      if (shared.existsSync()) shared.deleteSync(recursive: true);
      shared.createSync();
      File('${shared.path}/版本.json').writeAsStringSync(
        '{"version": "1.0.99", "notes": "新增询价单和定标", "file": "询价台账-1.0.99-windows.zip"}',
      );
      state.saveSetting('sync_dir', shared.path);
      state.saveSetting('device_id', '12345678-aaaa-4bbb-8ccc-1234567890ab');
      state.syncNow();
      await t.tap(find.text('同步与交换'));
      await t.pumpAndSettle();
    }),
    skip: !hasFont,
  );
  testWidgets(
    'desktop LAN push picker',
    (t) => shoot(t, const Size(1280, 860), 'desktop_lan_push', () async {
      final state = t.widget<Shell>(find.byType(Shell)).state;
      final project = state.store.searchByName('project', '泵房改造工程').single.id;
      showLanPush(
        t.element(find.byType(Shell)),
        state,
        chosen: {
          'project': {project},
        },
      );
      await t.pumpAndSettle();
    }),
    skip: !hasFont,
  );
  for (final (tab, name) in [
    ('数据模型', 'desktop_data_model'),
    ('数据质量', 'desktop_data_quality'),
    ('AI 接入', 'desktop_data_ai'),
  ]) {
    testWidgets(
      'desktop data centre: $tab',
      (t) => shoot(t, const Size(1280, 1000), name, () async {
        await t.tap(find.text('数据中心'));
        await t.pumpAndSettle();
        await t.tap(find.text(tab));
        await t.pumpAndSettle();
      }),
      skip: !hasFont,
    );
  }
  testWidgets(
    'phone data centre',
    (t) => shoot(t, const Size(390, 844), 'phone_data_model', () async {
      await t.tap(find.text('更多'));
      await t.pumpAndSettle();
      await t.tap(find.text('数据中心'));
      await t.pumpAndSettle();
    }),
    skip: !hasFont,
  );
  for (final (nav, name) in [
    ('报价', 'desktop_quotes'),
    ('供应商', 'desktop_suppliers'),
    ('物料', 'desktop_products'),
  ]) {
    testWidgets(
      'desktop table $name',
      (t) => shoot(t, const Size(1280, 800), name, () async {
        await t.tap(find.text(nav).first);
        await t.pumpAndSettle();
      }),
      skip: !hasFont,
    );
  }
  for (final (nav, row, name) in [
    ('供应商', '甲泵业', 'desktop_supplier_detail'),
    ('物料', '不锈钢离心泵', 'desktop_product_detail'),
  ]) {
    testWidgets(
      'desktop detail $name',
      (t) => shoot(t, const Size(1280, 860), name, () async {
        await t.tap(find.text(nav).first);
        await t.pumpAndSettle();
        await t.tap(find.text(row).first);
        await t.pumpAndSettle();
      }),
      skip: !hasFont,
    );
  }
}
