import 'package:test/test.dart';
import 'package:supplier_core/src/values.dart';
import 'package:supplier_core/src/entities.dart';
import 'package:supplier_core/src/quotation.dart';

const sid = '11111111-1111-4111-8111-111111111111';
const pid = '22222222-2222-4222-8222-222222222222';
Map<String, Object?> quote() => {
  'supplier_id': sid,
  'product_id': pid,
  'price': '12.340001',
  'currency': 'CNY',
  'tax_mode': 'unknown',
  'unit_snapshot': '件',
  'min_qty': '1',
  'quoted_on': '2026-09-16',
  'contact_id': null,
  'contact_snapshot': null,
  'tax_rate': null,
  'lead_time_days': null,
  'valid_until': null,
  'notes': null,
  'project_id': '33333333-3333-4333-8333-333333333333',
  'inquiry_location': null,
  'inquirer_name': '张三',
  'inquiry_precision': 'date',
  'inquiry_date': '2026-09-16',
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
};
void main() {
  test('NFC codepoints XML validity and array ordering', () {
    expect(normalizeText(' e\u0301 ', 'name', 1), 'é');
    expect(normalizeText('😀', 'name', 1), '😀');
    for (final s in ['\u0000', '\ud800', '\udfff', '\ufffe']) {
      expect(() => normalizeText(s, 'name', 10), throwsFormatException);
    }
    expect(normalizeTextList(['z', '😀', '\ue000', 'z'], 'aliases', 20, 200), [
      'z',
      '\ue000',
      '😀',
    ]);
  });
  test('exact decimals', () {
    expect(ExactDecimal.parse('00012.340000').canonical, '12.34');
    expect(ExactDecimal.parse('0').sortKey, '000000000000000000');
    expect(
      ExactDecimal.parse('999999999999.999999').sortKey,
      '999999999999999999',
    );
    expect(
      ExactDecimal.parse('12.340001').compareTo(ExactDecimal.parse('12.34')),
      1,
    );
    for (final s in [
      '-1',
      '+1',
      '1e2',
      'NaN',
      '1.0000001',
      '1000000000000',
      '.1',
      '1.',
    ]) {
      expect(() => ExactDecimal.parse(s), throwsFormatException);
    }
    expect(
      () => ExactDecimal.parse('0', positive: true),
      throwsFormatException,
    );
  });
  test('date precision offsets and invalid inputs', () {
    expect(InquiryTime.parseInput('2026-01-01T00:15+08:00').toJson(), {
      'inquiry_precision': 'instant',
      'inquiry_date': '2026-01-01',
      'inquired_at': '2025-12-31T16:15:00.000Z',
      'inquiry_utc_offset_minutes': 480,
    });
    expect(
      InquiryTime.parseInput('2024-02-29').toJson()['inquired_at'],
      isNull,
    );
    for (final s in [
      '2023-02-29',
      '2026-04-31',
      '2026-01-01T00:00:60Z',
      '2026-01-01T00:00:00.0001Z',
      '2026-01-01T00:00:00',
      '2026-01-01T00:00+14:01',
    ]) {
      expect(() => InquiryTime.parseInput(s), throwsFormatException);
    }
  });
  test('supplier exact keys and immutable payload', () {
    final d = <String, Object?>{
      'name': '供应商',
      'aliases': <String>[],
      'address': null,
      'categories': <String>[],
      'notes': null,
      'merged_into': null,
    };
    final s = Supplier.fromJson(d);
    expect(
      () => (s.toJson()['aliases'] as List).add('x'),
      throwsUnsupportedError,
    );
    expect(
      () => Supplier.fromJson({...d, 'extra': null}),
      throwsFormatException,
    );
    expect(
      () => Supplier.fromJson({...d}..remove('notes')),
      throwsFormatException,
    );
    expect(
      () => Supplier.fromJson({...d, 'name': '😀' * 201}),
      throwsFormatException,
    );
  });
  test('quotation standard and historical validation', () {
    expect(Quotation.fromJson(quote()).missingContext, isEmpty);
    for (final f in [
      'price',
      'supplier_id',
      'product_id',
      'quoted_on',
      'inquirer_name',
    ]) {
      expect(
        () => Quotation.fromJson({...quote(), f: null}),
        throwsFormatException,
        reason: f,
      );
    }
    final h = Quotation.fromJson({
      ...quote(),
      'capture_mode': 'historical',
      'project_id': null,
      'inquirer_name': null,
      'quoted_on': null,
      'inquiry_precision': 'unknown',
      'inquiry_date': null,
    });
    expect(
      h.missingContext,
      containsAll(['project_id', 'inquirer_name', 'inquiry_date', 'quoted_on']),
    );
    expect(() => h.copyAsNewInquiry(), throwsFormatException);
    expect(
      () => h.validateEditFrom(Quotation.fromJson(quote())),
      throwsFormatException,
    );
    for (final d in [
      {'valid_until': '2026-09-15'},
      {'inquired_at': '2026-09-16T00:00:00.000Z'},
      {'tax_rate': '100.0001'},
      {'contact_id': pid},
    ]) {
      expect(
        () => Quotation.fromJson({...quote(), ...d}),
        throwsFormatException,
      );
    }
  });
  test('contact snapshot detached and supplier binding checked', () {
    final d = <String, Object?>{
      'supplier_id': sid,
      'name': ' A ',
      'phone': '000123',
      'wechat': null,
      'email': null,
      'notes': null,
    };
    final c = Contact.fromJson(d);
    final snapshot = c.snapshot;
    d['name'] = 'B';
    expect(snapshot['name'], 'A');
    final q = Quotation.fromJson({
      ...quote(),
      'contact_id': pid,
      'contact_snapshot': snapshot,
    });
    q.validateContact(pid, c);
    expect(
      () =>
          q.validateContact(pid, Contact.fromJson({...d, 'supplier_id': pid})),
      throwsFormatException,
    );
  });
  test('every text field enforces its codepoint boundary', () {
    final cases =
        <
          (
            Map<String, Object?>,
            Map<String, int>,
            Map<String, Object?> Function(Map<String, Object?>),
          )
        >[
          (
            {
              'name': 'S',
              'aliases': <String>[],
              'address': null,
              'categories': <String>[],
              'notes': null,
              'merged_into': null,
            },
            {'name': 200, 'address': 500, 'notes': 2000},
            (v) => Supplier.fromJson(v).toJson(),
          ),
          (
            {
              'supplier_id': sid,
              'name': 'C',
              'phone': '0001',
              'wechat': null,
              'email': null,
              'notes': null,
            },
            {
              'name': 200,
              'phone': 100,
              'wechat': 100,
              'email': 254,
              'notes': 2000,
            },
            (v) => Contact.fromJson(v).toJson(),
          ),
          (
            {
              'name': 'P',
              'unit': '件',
              'brand': null,
              'model': null,
              'specification': null,
              'category': null,
              'notes': null,
              'merged_into': null,
            },
            {
              'name': 200,
              'unit': 50,
              'brand': 200,
              'model': 200,
              'specification': 1000,
              'category': 100,
              'notes': 2000,
            },
            (v) => Product.fromJson(v).toJson(),
          ),
          (
            quote(),
            {
              'unit_snapshot': 50,
              'notes': 2000,
              'inquiry_location': 500,
              'inquirer_name': 200,
            },
            normalizeQuotation,
          ),
        ];
    for (final (base, limits, validate) in cases) {
      for (final entry in limits.entries) {
        expect(
          validate({...base, entry.key: '😀' * entry.value})[entry.key],
          '😀' * entry.value,
        );
        expect(
          () => validate({...base, entry.key: '😀' * (entry.value + 1)}),
          throwsFormatException,
          reason: entry.key,
        );
      }
      for (final key in base.keys) {
        expect(
          () => validate({...base}..remove(key)),
          throwsFormatException,
          reason: key,
        );
      }
      expect(
        () => validate({...base, 'unrecognized': null}),
        throwsFormatException,
      );
    }
  });
  test('array, snapshot, numeric, enum and UUID counterexamples', () {
    expect(
      () => normalizeTextList(List.filled(21, 'a'), 'aliases', 20, 200),
      throwsFormatException,
    );
    expect(
      () => normalizeTextList(['a' * 201], 'aliases', 20, 200),
      throwsFormatException,
    );
    expect(
      () => normalizeTextList(['a' * 101], 'categories', 20, 100),
      throwsFormatException,
    );
    expect(
      () => normalizeTextList([' '], 'aliases', 20, 200),
      throwsFormatException,
    );
    for (final changes in <Map<String, Object?>>[
      {'supplier_id': sid.toUpperCase().replaceFirst('1', 'A')},
      {'product_id': 'bad'},
      {'price': 1.5},
      {'min_qty': '0'},
      {'min_qty': 1},
      {'currency': 'cny'},
      {'tax_mode': 'other'},
      {'capture_mode': 'other'},
      {'tax_rate': '0.00001'},
      {'lead_time_days': -1},
      {'lead_time_days': 36501},
      {'lead_time_days': 1.5},
      {
        'contact_snapshot': {
          'name': 'A',
          'phone': null,
          'wechat': null,
          'email': null,
        },
      },
      {
        'inquiry_precision': 'instant',
        'inquired_at': '2026-09-16T16:00:00.000Z',
        'inquiry_utc_offset_minutes': 480,
      },
      {
        'inquiry_precision': 'instant',
        'inquired_at': '2026-09-16T00:00:00.000Z',
        'inquiry_utc_offset_minutes': 841,
      },
      {'inquiry_precision': 'unknown', 'inquiry_date': null},
    ]) {
      expect(
        () => Quotation.fromJson({...quote(), ...changes}),
        throwsFormatException,
        reason: '$changes',
      );
    }
    expect(
      Quotation.fromJson({
        ...quote(),
        'price': '0',
        'tax_rate': '100',
        'lead_time_days': 36500,
      }).priceKey,
      '000000000000000000',
    );
    expect(
      Quotation.fromJson({
        ...quote(),
        'contact_snapshot': {
          'name': 'A',
          'phone': '0001',
          'wechat': null,
          'email': null,
        },
      }).toJson()['contact_id'],
      isNull,
    );
  });
  test('explicit clearing and date/instant canonical payloads', () {
    final original = Quotation.fromJson({...quote(), 'tax_rate': '13'});
    final cleared = Quotation.fromJson({...quote(), 'tax_rate': null});
    expect(() => cleared.validateEditFrom(original), throwsFormatException);
    cleared.validateEditFrom(original, allowExplicitClear: true);
    final instant = InquiryTime.parseInput('2026-01-01T00:15:00.1-14:00');
    expect(instant.toJson()['inquired_at'], '2026-01-01T14:15:00.100Z');
    expect(
      InquiryTime.fromJson(instant.toJson(), historical: false).toJson(),
      instant.toJson(),
    );
    expect(
      () => InquiryTime.fromJson({
        ...instant.toJson(),
        'inquired_at': '2026-01-01T14:15:00.1Z',
      }, historical: false),
      throwsFormatException,
    );
    expect(() => normalizeInstant('2026-01-01'), throwsFormatException);
  });
  test('clearing nested contact methods requires explicit confirmation', () {
    final snapshot = <String, Object?>{
      'name': 'A',
      'phone': '0001',
      'wechat': 'wx',
      'email': 'a@example.com',
    };
    final original = Quotation.fromJson({
      ...quote(),
      'contact_snapshot': snapshot,
    });
    for (final field in ['phone', 'wechat', 'email']) {
      final cleared = Quotation.fromJson({
        ...quote(),
        'contact_snapshot': {...snapshot, field: null},
      });
      expect(
        () => cleared.validateEditFrom(original),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'field',
            contains('contact_snapshot.$field'),
          ),
        ),
        reason: field,
      );
      cleared.validateEditFrom(original, allowExplicitClear: true);
    }
    Quotation.fromJson({
      ...quote(),
      'contact_snapshot': {...snapshot, 'phone': '0002'},
    }).validateEditFrom(original);
  });
  test(
    'integer business fields normalize integral numbers across VM and Web',
    () {
      final time = InquiryTime.parseInput('2026-01-01T08:00+08:00').toJson();
      expect(
        Quotation.fromJson({
          ...quote(),
          'lead_time_days': 1.0,
        }).toJson()['lead_time_days'],
        1,
      );
      expect(
        InquiryTime.fromJson({
          ...time,
          'inquiry_utc_offset_minutes': 480.0,
        }, historical: false).offsetMinutes,
        480,
      );
      for (final value in <Object?>[
        1.5,
        double.nan,
        double.infinity,
        -double.infinity,
        9007199254740992,
        '1',
        true,
      ]) {
        expect(
          () => Quotation.fromJson({...quote(), 'lead_time_days': value}),
          throwsFormatException,
        );
        expect(
          () => InquiryTime.fromJson({
            ...time,
            'inquiry_utc_offset_minutes': value,
          }, historical: false),
          throwsFormatException,
        );
      }
      expect(
        () => Quotation.fromJson({...quote(), 'price': 1.0}),
        throwsFormatException,
      );
    },
  );
}
