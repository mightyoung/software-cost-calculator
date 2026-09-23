import 'package:supplier_core/src/contracts.dart';
import 'package:supplier_core/src/exchange/space_budget.dart';
import 'package:test/test.dart';

void main() {
  test('working space includes all caller estimates without a package cap', () {
    final budget = SpaceBudget(
      components: {
        'source': 400 * 1024 * 1024,
        'staging': 800 * 1024 * 1024,
        'backup': 900 * 1024 * 1024,
        'journal': 300 * 1024 * 1024,
      },
      availableBytes: 2400 * 1024 * 1024,
    );
    expect(budget.fits, isTrue);
    budget.requireAvailable();
    final insufficient = SpaceBudget(
      components: budget.components,
      availableBytes: 1,
    );
    expect(insufficient.requireAvailable, throwsA(isA<DomainFailure>()));
    expect(SpaceBudget(components: budget.components).fits, isNull);
  });
  test('accumulation remains exact beyond JavaScript safe sum', () {
    final budget = SpaceBudget(
      components: {'a': 9007199254740991, 'b': 9007199254740991},
    );
    expect(budget.estimatedBytes.toString(), '18014398509481982');
    expect(() => SpaceBudget(components: {'invalid': -1}), throwsArgumentError);
  });
  test('actual expanded bytes are counted across entries before admission', () {
    final budget = VolumeBudget();
    budget.checkCompressedSize(VolumeBudget.maxCompressedBytes);
    budget.addExpandedBytes(VolumeBudget.maxExpandedBytes - 1);
    budget.addEntry();
    budget.addExpandedBytes(1);
    expect(budget.expandedBytes, VolumeBudget.maxExpandedBytes);
    expect(() => budget.addExpandedBytes(1), throwsA(isA<DomainFailure>()));
    expect(() => budget.addExpandedBytes(0), throwsA(isA<DomainFailure>()));
    expect(budget.expandedBytes, VolumeBudget.maxExpandedBytes);
  });
  test(
    'compressed entry and row caps reject one over their exact boundary',
    () {
      expect(
        () => VolumeBudget().checkCompressedSize(
          VolumeBudget.maxCompressedBytes + 1,
        ),
        throwsA(isA<DomainFailure>()),
      );
      final entries = VolumeBudget();
      for (var i = 0; i < VolumeBudget.maxEntries; i++) {
        entries.addEntry();
      }
      expect(entries.addEntry, throwsA(isA<DomainFailure>()));
      final rows = VolumeBudget();
      for (var i = 0; i < VolumeBudget.maxDataRows; i++) {
        rows.addDataRow();
      }
      expect(rows.addDataRow, throwsA(isA<DomainFailure>()));
      expect(rows.dataRows, 5000);
    },
  );
}
