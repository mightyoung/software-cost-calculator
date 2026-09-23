"""Independent stdlib reference for this restricted, integer-only JCS fixture.

UTF-16 BE key ordering implements RFC8785; no Dart implementation is imported.
Run from any directory. Existing fixture bytes are verified unless --write is set.
"""
import hashlib
import json
from pathlib import Path
import sys


def canonical(value):
    if isinstance(value, dict):
        return '{' + ','.join(canonical(k) + ':' + canonical(value[k])
                              for k in sorted(value, key=lambda k: k.encode('utf-16-be'))) + '}'
    if isinstance(value, list):
        return '[' + ','.join(map(canonical, value)) + ']'
    if isinstance(value, float):
        raise ValueError('No floating point in persisted domain')
    return json.dumps(value, ensure_ascii=False, separators=(',', ':'))


envelope = {
    'protocol': 2, 'entity_type': 'supplier',
    'entity_id': '11111111-1111-4111-8111-111111111111',
    'parents': [], 'kind': 'put',
    'payload': {'name': '供应商 é', 'aliases': [], 'address': None,
                'categories': [], 'notes': 'line\n"quoted"'},
    'authored_at': '2026-09-16T08:00:00.000Z',
    'origin_device_id': '22222222-2222-4222-8222-222222222222',
}
encoded = canonical(envelope)
fixture = {'canonical': encoded, 'sha256': hashlib.sha256(encoded.encode()).hexdigest()}
path = Path(__file__).with_name('supplier-root.json')
if '--write' in sys.argv:
    path.write_text(json.dumps(fixture, ensure_ascii=False, indent=2) + '\n')
else:
    assert json.loads(path.read_text()) == fixture
print(fixture['sha256'])

quotation = {
    'supplier_id': '11111111-1111-4111-8111-111111111111',
    'product_id': '22222222-2222-4222-8222-222222222222',
    'price': '12.340001', 'currency': 'CNY', 'tax_mode': 'included',
    'unit_snapshot': '件', 'min_qty': '1', 'quoted_on': '2026-09-16',
    'contact_id': None, 'contact_snapshot': None, 'tax_rate': '13',
    'lead_time_days': None, 'valid_until': None, 'notes': None,
    'project_name': '配电改造', 'project_number': '000123-A',
    'inquiry_location': None, 'inquirer_name': '张三',
    'inquiry_precision': 'date', 'inquiry_date': '2026-09-16',
    'inquired_at': None, 'inquiry_utc_offset_minutes': None,
    'capture_mode': 'standard',
}
quote_cases = {
    'date': quotation,
    'instant': {**quotation, 'inquiry_precision': 'instant',
                'inquiry_date': '2026-01-01', 'inquired_at': '2025-12-31T16:15:00.100Z',
                'inquiry_utc_offset_minutes': 480},
    'historical': {**quotation, 'capture_mode': 'historical',
                   'project_name': None, 'project_number': None, 'inquirer_name': None,
                   'quoted_on': None, 'inquiry_precision': 'unknown', 'inquiry_date': None},
}

def vector(value):
    encoded = canonical(value)
    return {'value': value, 'canonical': encoded,
            'sha256': hashlib.sha256(encoded.encode('utf-8')).hexdigest()}


def freeze(name, value):
    path = Path(__file__).with_name(name)
    if '--write' in sys.argv:
        path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')
    else:
        assert json.loads(path.read_text()) == value, name
    print(name, 'verified')


freeze('quotation-vectors.json', {
    name: vector({**envelope, 'entity_type': 'quotation', 'payload': payload})
    for name, payload in quote_cases.items()
})
source = {
    'version': 1,
    'fields': {'notes': {'presence': 'blank', 'value': None},
               'project_number': {'presence': 'value', 'value': '000123-A'},
               'inquiry_location': {'presence': 'missing', 'value': None}},
    'input_identity': {'supplier': '原供应商', 'record_id': envelope['entity_id']},
    'mapping_semantics': {'notes': 'text', 'project_number': 'identifier_text'},
    'batch_defaults': {'inquirer_name': '张三'}, 'capture_mode': 'historical',
}
source_vector = vector(source)
operation = {
    'version': 1, 'source_fingerprint': source_vector['sha256'], 'intent': 'modify',
    'original_bindings': {'supplier_id': envelope['entity_id']},
    'operations': {'notes': {'kind': 'keep', 'value': None},
                   'inquiry_location': {'kind': 'clear', 'value': None},
                   'project_number': {'kind': 'set', 'value': '000123-A'}},
    'confirmed_quantity': 1,
}
freeze('fingerprint-vectors.json', {'source': source_vector, 'operation': vector(operation)})
