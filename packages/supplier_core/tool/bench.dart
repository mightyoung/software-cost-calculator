import 'dart:io';
import 'package:supplier_core/supplier_core.dart';

void main() {
  final dir = Directory('/tmp/sq-bench/run')..createSync(recursive: true);
  for (final f in dir.listSync()) {
    f.deleteSync();
  }
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
      });
    }
  });
  print('generate ${sw.elapsedMilliseconds} ms');
  s.db.execute('PRAGMA wal_checkpoint(TRUNCATE)');
  print('db ${File('${dir.path}/a.db').lengthSync() ~/ 1048576} MiB');
  sw.reset();
  s.exportTo('${dir.path}/x.siq');
  print(
    'export ${sw.elapsedMilliseconds} ms, file ${File('${dir.path}/x.siq').lengthSync() ~/ 1048576} MiB',
  );
  final b = Store.open('${dir.path}/b.db', device: 'WH02');
  sw.reset();
  b.importFrom('${dir.path}/x.siq');
  print('import into empty ${sw.elapsedMilliseconds} ms');
  sw.reset();
  b.importFrom('${dir.path}/x.siq');
  print('re-import (no changes) ${sw.elapsedMilliseconds} ms');
  sw.reset();
  final q = b.quoteOptions(pros[0], prods[0], asOf: DateTime.utc(2026, 9, 10));
  print('quoteOptions ${sw.elapsedMilliseconds} ms (${q.length})');
  print('rss ${ProcessInfo.maxRss ~/ 1048576} MiB');
}
