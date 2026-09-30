import 'dart:io';
import 'package:supplier_core/supplier_core.dart';

void main() {
  final failures = <String>[];
  final dir = Directory.systemTemp.createTempSync('sq-bench-');
  print('benchmark outputs: ${dir.path}');
  final s = Store.open('${dir.path}/a.db', device: 'WH01');
  final sw = Stopwatch()..start();
  late List<String> sups, prods, pros;
  s.transaction(() {
    sups = [
      for (var i = 0; i < 10000; i++)
        s.save('supplier', {
          'name': '供应商$i',
          'aliases': <String>[],
          'address': '某市某区某路$i号',
          'categories': ['电气'],
          'notes': null,
          'merged_into': null,
        }),
    ];
    prods = [
      for (var i = 0; i < 20000; i++)
        s.save('product', {
          'name': '物料$i',
          'unit': '件',
          'brand': '品牌${i % 50}',
          'model': 'M-$i',
          'specification': '规格说明$i',
          'category': '类别${i % 20}',
          'notes': null,
          'merged_into': null,
          'attributes': null,
          'unit_conversions': null,
        }),
    ];
    pros = [
      for (var i = 0; i < 500; i++)
        s.save('project', {
          'code': '2026-WH01-$i',
          'name': '项目$i',
          'status': 'active',
          'type': 'market',
          'level': 'A',
          'customer': '客户$i',
          'contract_no': null,
          'contract_amount': '1000000',
          'department': null,
          'leader': null,
          'start_date': null,
          'end_date': null,
          'currency': 'CNY',
          'tax_mode': 'included',
          'markup_rate': '10',
          'notes': null,
        }),
    ];
    for (var i = 0; i < 100000; i++) {
      s.save('quotation', {
        'supplier_id': sups[i % 10000],
        'product_id': prods[i % 20000],
        'price': '${i % 997}.${i % 100}',
        'currency': 'CNY',
        'tax_mode': 'included',
        'unit_snapshot': '件',
        'min_qty': '1',
        'quoted_on': '2026-09-01',
        'contact_id': null,
        'contact_snapshot': null,
        'tax_rate': '13',
        'lead_time_days': 7,
        'valid_until': null,
        'notes': '备注$i',
        'project_id': pros[i % 500],
        'inquiry_location': null,
        'inquirer_name': '张三',
        'inquiry_precision': 'date',
        'inquiry_date': '2026-09-01',
        'inquired_at': null,
        'inquiry_utc_offset_minutes': null,
        'capture_mode': 'standard',
        'includes': null,
        'warranty_months': null,
        'extra_cost': null,
        'deal_price': null,
        'awarded_on': null,
        'award_note': null,
        'inquiry_id': null,
        'attachment_ids': null,
        'price_basis': null,
      });
    }
  });
  print('generate ${sw.elapsedMilliseconds} ms');
  s.db.execute('PRAGMA wal_checkpoint(TRUNCATE)');
  final dbBytes = File('${dir.path}/a.db').lengthSync();
  print('db $dbBytes bytes (${dbBytes ~/ 1048576} MiB; limit 150000000)');
  if (dbBytes > 150000000) failures.add('database size');
  sw.reset();
  s.exportTo('${dir.path}/x.siq');
  final exportMs = sw.elapsedMilliseconds;
  print(
    'export $exportMs ms, file ${File('${dir.path}/x.siq').lengthSync() ~/ 1048576} MiB',
  );
  if (exportMs > 60000) failures.add('exchange export');
  final b = Store.open('${dir.path}/b.db', device: 'WH02');
  sw.reset();
  b.importFrom('${dir.path}/x.siq');
  final importMs = sw.elapsedMilliseconds;
  print('import into empty $importMs ms');
  if (importMs > 60000) failures.add('exchange import');
  sw.reset();
  b.importFrom('${dir.path}/x.siq');
  print('re-import (no changes) ${sw.elapsedMilliseconds} ms');
  // Interactive queries: fail when one is several times slower than today
  // (limits allow for JIT and slow CI runners), e.g. the search index
  // stopped being used.
  void timed(String label, int limitMs, Object? Function() run) {
    sw.reset();
    run();
    final ms = sw.elapsedMilliseconds;
    print('$label $ms ms (limit $limitMs)');
    if (ms > limitMs) failures.add(label);
  }

  timed(
    'quoteOptions',
    100,
    () => b.quoteOptions(pros[0], prods[0], asOf: DateTime.utc(2026, 9, 10)),
  );
  timed('compareQuotes', 100, () => b.compareQuotes(prods[0]));
  timed('searchProducts', 300, () => b.searchProducts(['物料1999', '品牌7']));
  timed('searchProducts, 2-char term hitting all 20k', 300, () {
    return b.searchProducts(['物料']);
  });
  timed('pinyin search', 300, () => b.searchByName('supplier', 'gys'));
  // List pages: whole tables with counts, and one sorted page of quotes.
  timed('supplier table (10k)', 3000, () => b.supplierRows());
  timed('product table (20k)', 3000, () => b.productRows());
  // CI runners measured 560-1030 ms for these two; the limits leave ~2x
  // headroom so a slow runner does not fail a build; a 2x regression still does.
  timed('quote page, newest 200 of 100k', 2000, () => b.quoteRows());
  timed(
    'quote page, usable by price',
    2000,
    () => b.quoteRows(filter: QuoteFilter.usable, sort: QuoteSort.price),
  );
  // Matching: one class of 2,000 materials with typed parameters.
  b.transaction(() {
    for (var i = 0; i < 2000; i++) {
      final id = b.save('product', {
        'name': '工控机$i',
        'unit': '台',
        'brand': null,
        'model': 'IPC-$i',
        'specification': null,
        'category': null,
        'notes': null,
        'merged_into': null,
        'attributes': null,
        'unit_conversions': null,
        'spec_class': 'computer.ipc',
      });
      b.setParam(id, 'cpu.cores', {'v': '${4 + i % 16}'});
      b.setParam(id, 'cpu.base_freq', {'v': '2.${i % 9}', 'u': 'GHz'});
      b.setParam(id, 'mem.total', {'v': '${8 * (1 + i % 4)}', 'u': 'GiB'});
    }
  });
  timed(
    'match 2,000 materials of a class',
    1500,
    () => b.matchSpec('computer.ipc', const [
      SpecConstraint('cpu.cores', 'ge', {'v': '8'}),
      SpecConstraint('cpu.base_freq', 'ge', {'v': '2.3', 'u': 'GHz'}),
      SpecConstraint('mem.total', 'ge', {'v': '16', 'u': 'GiB'}),
    ]),
  );
  print('rss ${ProcessInfo.maxRss ~/ 1048576} MiB');
  if (failures.isNotEmpty) {
    print('BENCHMARK FAILED: ${failures.join(', ')}');
    exitCode = 1;
  }
}
