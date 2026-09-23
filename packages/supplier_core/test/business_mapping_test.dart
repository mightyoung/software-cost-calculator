import 'package:supplier_core/src/exchange/business_mapping.dart';
import 'package:test/test.dart';

void main() {
  RawBusinessCell number(String value) => RawBusinessCell(
    coordinate: 'C7',
    kind: BusinessCellKind.number,
    lexical: value,
  );
  RawBusinessCell text(String value) => RawBusinessCell(
    coordinate: 'C7',
    kind: BusinessCellKind.text,
    lexical: value,
  );

  test('raw decimal exponent conversion never passes through double', () {
    expect(number('1.2340001E+1').decimal(), '12.340001');
    expect(number('9.99999999999999999e11').decimal(), '999999999999.999999');
    expect(number('0e999').decimal(), '0');
    expect(number('1e-6').decimal(), '0.000001');
    expect(number('.5').decimal(), '0.5');
    expect(number('00012.3400').decimal(), '12.34');
    expect(number('0').decimal(), '0');
  });

  test(
    'precision, invalid numeric and exponent limits reject at coordinate',
    () {
      for (final value in [
        '-1',
        '1e12',
        '1e-7',
        '12.340001000000001',
        'NaN',
        'Infinity',
        '1e1000000',
        '1e',
        ' 1',
        '0.0000000',
      ]) {
        expect(
          () => number(value).decimal(),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'coordinate',
              contains('C7'),
            ),
          ),
        );
      }
    },
  );

  test(
    'text identifiers retain zeroes; numeric identifiers are never guessed',
    () {
      expect(text(' 000123-A ').text(), '000123-A');
      expect(text('0013800000000').text(), '0013800000000');
      expect(() => number('123').text(), throwsFormatException);
      expect(
        () => number('1.234567890123456E+17').text(),
        throwsFormatException,
      );
    },
  );

  test('formula caches, booleans and errors cannot become business values', () {
    final formula = RawBusinessCell(
      coordinate: 'D2',
      kind: BusinessCellKind.number,
      lexical: '12.34',
      formula: 'SUM(A1:A3)',
    );
    expect(() => formula.decimal(), throwsFormatException);
    expect(() => formula.sourcePresence, throwsFormatException);
    for (final kind in [
      BusinessCellKind.boolean,
      BusinessCellKind.error,
      BusinessCellKind.date,
    ]) {
      final cell = RawBusinessCell(coordinate: 'A1', kind: kind, lexical: '1');
      expect(() => cell.text(), throwsFormatException);
      expect(() => cell.decimal(), throwsFormatException);
    }
  });

  test(
    'missing column, blank cell and zero retain distinct source presence',
    () {
      expect(
        businessSourceCell(null, (c) => c.text()).presence.name,
        'missing',
      );
      expect(
        businessSourceCell(text('  '), (c) => c.text()).presence.name,
        'blank',
      );
      expect(businessSourceCell(number('0'), (c) => c.decimal()).value, '0');
    },
  );

  test(
    '1900 system excludes phantom leap day, including its time fraction',
    () {
      expect(number('1').excelDate().time.date, '1900-01-01');
      expect(number('59').excelDate().time.date, '1900-02-28');
      expect(number('61').excelDate().time.date, '1900-03-01');
      for (final value in ['60', '60.5', '0', '-1']) {
        expect(() => number(value).excelDate(), throwsFormatException);
      }
    },
  );

  test('1904 system starts at zero and is offset by 1462 days', () {
    expect(number('0').excelDate(date1904: true).time.date, '1904-01-01');
    expect(number('1462').excelDate().time.date, '1904-01-01');
    expect(number('59').excelDate(date1904: true).time.date, '1904-02-29');
  });

  test('date-only inputs do not manufacture an instant or offset', () {
    final result = number('45292').excelDate();
    expect(result.time.date, '2024-01-01');
    expect(result.time.precision, 'date');
    expect(result.time.instant, isNull);
    expect(result.time.offsetMinutes, isNull);
    expect(() => number('45292.5').excelDate(), throwsFormatException);
  });

  test('Excel time needs explicit precision and batch UTC offset', () {
    expect(
      () => number('45292.5').excelDate(instant: true),
      throwsFormatException,
    );
    final result = number(
      '45292.5',
    ).excelDate(instant: true, offsetMinutes: 480);
    expect(result.time.date, '2024-01-01');
    expect(result.time.instant, '2024-01-01T04:00:00.000Z');
    expect(result.millisecondsRounded, isFalse);
    expect(
      () => number('45292.5').excelDate(instant: true, offsetMinutes: 841),
      throwsFormatException,
    );
  });

  test('fractional-day conversion reports any rounding to milliseconds', () {
    final result = number(
      '45292.333333333336',
    ).excelDate(instant: true, offsetMinutes: 0);
    expect(result.time.instant, '2024-01-01T08:00:00.000Z');
    expect(result.millisecondsRounded, isTrue);
  });

  test('UTC overflow errors retain workbook cell coordinate', () {
    expect(
      () => number('2958465.999').excelDate(instant: true, offsetMinutes: -840),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'coordinate',
          contains('C7'),
        ),
      ),
    );
  });

  test('rounding cannot silently cross a calendar-day boundary', () {
    expect(
      () =>
          number('59.999999999999').excelDate(instant: true, offsetMinutes: 0),
      throwsFormatException,
    );
  });

  test(
    'only supported workbook dates and bounded cell lexical values accepted',
    () {
      expect(number('2958465').excelDate().time.date, '9999-12-31');
      expect(() => number('2958466').excelDate(), throwsFormatException);
      expect(() => number('1e999').excelDate(), throwsFormatException);
      expect(() => text('x' * 32768), throwsFormatException);
      expect(() => text('\u000b'), throwsFormatException);
      expect(
        () => RawBusinessCell(
          coordinate: 'A1',
          kind: BusinessCellKind.blank,
          lexical: '12',
        ),
        throwsFormatException,
      );
    },
  );
}
