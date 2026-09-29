import 'dart:io';

import 'package:sqlite3/sqlite3.dart';
import 'package:supplier_core/supplier_core.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

/// Counts real SELECT calls while still executing them against SQLite.
class CountingDatabase implements Database {
  CountingDatabase(this.delegate);
  final Database delegate;
  int selects = 0;

  @override
  ResultSet select(String sql, [List<Object?> parameters = const []]) {
    selects++;
    return delegate.select(sql, parameters);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test(
    'quality completeness matches individual checks with bounded queries',
    () {
      tmp = Directory.systemTemp.createTempSync('quality_scale');
      final source = device('A');
      addTearDown(() {
        source.close();
        tmp.deleteSync(recursive: true);
      });
      final ids = <String>[];
      final values = {
        'th.temp_range': '-40~85℃',
        'th.rh_range': '0~100%RH',
        'th.temp_accuracy': '0.5℃',
        'th.rh_accuracy': '3%RH',
        'io.output': '4-20mA',
      };
      source.transaction(() {
        for (var i = 0; i < 300; i++) {
          final id = source.save('product', {
            ...product('温湿度传感器$i'),
            'spec_class': 'sensor.th',
          });
          ids.add(id);
          final properties = i % 3 == 0 ? values.keys : values.keys.take(i % 3);
          for (final property in properties) {
            source.setParam(
              id,
              property,
              parseParamText(specProperty(property)!, values[property]!)!,
              confirmed: i % 3 != 0,
            );
          }
        }
        source.clearParam(ids.first, 'th.temp_range');
        source.delete('product', ids[1]);
        source.mergeInto('product', ids[2], ids[4]);
        source.save('product', product('温湿度传感器未分类'));
        source.save('product', product('普通物料'));
      });

      final db = CountingDatabase(source.db);
      final s = Store(db, device: 'test');
      final liveIds = ids.where((id) {
        final r = source.get('product', id)!;
        return !r.deleted && r.data['merged_into'] == null;
      });
      final individualTimer = Stopwatch()..start();
      final expected = liveIds.where((id) {
        final c = s.paramCompleteness(id);
        return c.filled < c.total;
      }).length;
      individualTimer.stop();
      final individualQueries = db.selects;
      db.selects = 0;
      final qualityTimer = Stopwatch()..start();
      final checks = {for (final c in s.dataQuality()) c.key: c.count};
      qualityTimer.stop();
      print(
        '300 products: individual completeness $individualQueries SELECTs, '
        '${individualTimer.elapsedMicroseconds} us; full dataQuality '
        '${db.selects} SELECTs, ${qualityTimer.elapsedMicroseconds} us',
      );
      expect(checks['products_missing_key_params'], expected);
      expect(checks['products_missing_key_params'], 199);
      expect(checks['products_unclassified'], 1);
      expect(checks['products_unconfirmed_params'], 100);
      expect(db.selects, lessThanOrEqualTo(12));

      // A later edit must be visible without invalidating any cached state.
      source.setParam(
        ids.first,
        'th.temp_range',
        parseParamText(specProperty('th.temp_range')!, '-40~85℃')!,
      );
      expect(
        s
            .dataQuality()
            .singleWhere((c) => c.key == 'products_missing_key_params')
            .count,
        expected - 1,
      );
    },
  );
}
