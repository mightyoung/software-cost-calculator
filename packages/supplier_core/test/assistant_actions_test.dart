import 'dart:convert';
import 'dart:io';

import 'package:supplier_core/supplier_core.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

void main() {
  late Store store;
  late AiCancellation cancellation;
  var call = 0;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('assistant_actions');
    store = device('assistant');
    cancellation = AiCancellation();
    call = 0;
  });
  tearDown(() {
    store.close();
    tmp.deleteSync(recursive: true);
  });
  AssistantAppTools tools({
    AssistantPermission permission = AssistantPermission.confirmWrites,
    Future<bool> Function(AssistantActionPreview)? approve,
    void Function()? validateSession,
    void Function()? onChanged,
  }) => AssistantAppTools(
    store,
    permission: permission,
    sessionId: 'trusted-job',
    approve: approve ?? (_) async => true,
    validateSession: validateSession,
    onChanged: onChanged,
  );
  Future<Map<String, dynamic>> run(
    AssistantAppTools executor,
    String operation,
    Map<String, Object?> args, {
    String? callId,
  }) async =>
      jsonDecode(
            await executor.execute(
              operation,
              args,
              callId: callId ?? 'call-${call++}',
              cancellation: cancellation,
            ),
          )
          as Map<String, dynamic>;
  Map<String, Object?> values(Map<String, Object?> payload) => {...payload}
    ..remove('merged_into')
    ..remove('capture_mode')
    ..remove('attachment_ids');

  test('read-only executor refuses hidden write tools', () async {
    final executor = tools(permission: AssistantPermission.readOnly);
    expect(executor.tools, isEmpty);
    await expectLater(
      run(executor, 'create_record', {
        'type': 'supplier',
        'values': {'name': 'A'},
      }),
      throwsFormatException,
    );
    expect(store.db.select('SELECT * FROM supplier'), isEmpty);
  });
  test(
    'denial and cancellation leave records and receipts untouched',
    () async {
      final args = {
        'type': 'supplier',
        'values': {'name': 'A'},
      };
      expect(
        (await run(
          tools(approve: (_) async => false),
          'create_record',
          args,
        ))['status'],
        'denied',
      );
      await expectLater(
        run(
          tools(
            approve: (_) async {
              cancellation.cancel();
              return true;
            },
          ),
          'create_record',
          args,
        ),
        throwsA(isA<LlmException>()),
      );
      expect(store.db.select('SELECT * FROM supplier'), isEmpty);
      expect(
        store.db.select(
          "SELECT * FROM meta WHERE key LIKE 'assistant_action:%'",
        ),
        isEmpty,
      );
    },
  );
  test('immutable nested preview applies its exact snapshot', () async {
    final aliases = <Object?>['first'];
    final executor = tools(
      approve: (preview) async {
        expect(() => preview.after['name'] = 'bad', throwsUnsupportedError);
        expect(
          () => (preview.after['aliases'] as List).add('bad'),
          throwsUnsupportedError,
        );
        aliases.add('changed');
        return true;
      },
    );
    final result = await run(executor, 'create_record', {
      'type': 'supplier',
      'values': {'name': 'A', 'aliases': aliases},
    });
    expect(store.get('supplier', result['id'] as String)!.data['aliases'], [
      'first',
    ]);
  });
  test('all business record families support confirmed CRUD', () async {
    final executor = tools();
    final supplierId = store.save('supplier', supplier('Supplier'));
    final productId = store.save('product', product('Material'));
    final projectId = store.save('project', project('P'));
    final payloads = <String, Map<String, Object?>>{
      'supplier': values(supplier('New')),
      'product': values(product('New')),
      'project': project('New'),
      'contact': {'supplier_id': supplierId, 'name': 'Contact', 'phone': '123'},
      'project_item': item(projectId, 'labor', name: 'Labor'),
      'inquiry': {
        'project_id': projectId,
        'title': 'Inquiry',
        'status': 'open',
      },
      'quotation': values(quotation(supplierId, productId, projectId, '12.50')),
    };
    for (final entry in payloads.entries) {
      final created = await run(executor, 'create_record', {
        'type': entry.key,
        'values': entry.value,
      });
      final id = created['id'] as String;
      expect(created['status'], 'applied');
      await run(executor, 'update_record', {
        'type': entry.key,
        'id': id,
        'values': {'notes': 'Confirmed'},
      });
      expect(store.get(entry.key, id)!.data['notes'], 'Confirmed');
      await run(executor, 'delete_record', {'type': entry.key, 'id': id});
      expect(store.get(entry.key, id)!.deleted, isTrue);
      await run(executor, 'restore_record', {'type': entry.key, 'id': id});
      expect(store.get(entry.key, id)!.deleted, isFalse);
      expect(store.get(entry.key, id)!.version, 4);
    }
  });
  test(
    'changed target and added incoming reference invalidate approval',
    () async {
      final id = store.save('supplier', supplier('A'));
      await expectLater(
        run(
          tools(
            approve: (_) async {
              store.save('supplier', supplier('Outside'), id: id);
              return true;
            },
          ),
          'update_record',
          {
            'type': 'supplier',
            'id': id,
            'values': {'name': 'Assistant'},
          },
        ),
        throwsFormatException,
      );
      await expectLater(
        run(
          tools(
            approve: (_) async {
              store.save('contact', {
                'supplier_id': id,
                'name': 'New contact',
                'phone': '123',
                'wechat': null,
                'email': null,
                'notes': null,
              });
              return true;
            },
          ),
          'delete_record',
          {'type': 'supplier', 'id': id},
        ),
        throwsFormatException,
      );
      expect(store.get('supplier', id)!.deleted, isFalse);
      expect(store.get('supplier', id)!.data['name'], 'Outside');
    },
  );
  test(
    'changed referenced record and invalid session reject approval',
    () async {
      final id = store.save('supplier', supplier('A'));
      final args = {
        'type': 'contact',
        'values': {'supplier_id': id, 'name': 'Contact', 'phone': '123'},
      };
      await expectLater(
        run(
          tools(
            approve: (_) async {
              store.save('supplier', supplier('B'), id: id);
              return true;
            },
          ),
          'create_record',
          args,
        ),
        throwsFormatException,
      );
      var active = true;
      await expectLater(
        run(
          tools(
            validateSession: () {
              if (!active) throw StateError('Session closed');
            },
            approve: (_) async {
              active = false;
              return true;
            },
          ),
          'create_record',
          args,
        ),
        throwsStateError,
      );
      expect(store.db.select('SELECT * FROM contact'), isEmpty);
    },
  );
  test(
    'unknown arguments, protected fields and bad decimals never ask approval',
    () async {
      var approvals = 0;
      final executor = tools(
        approve: (_) async {
          approvals++;
          return true;
        },
      );
      for (final args in <Map<String, Object?>>[
        {
          'type': 'supplier',
          'values': {'name': 'A'},
          'confirmed': true,
        },
        {
          'type': 'supplier',
          'values': {'name': 'A', 'unknown': 1},
        },
        {
          'type': 'supplier',
          'values': {'name': 'A', 'merged_into': null},
        },
        {
          'type': 'quotation',
          'values': {'price': 1.1},
        },
        {
          'type': 'attachment',
          'values': {'name': 'A'},
        },
      ]) {
        await expectLater(
          run(executor, 'create_record', args),
          throwsFormatException,
        );
      }
      expect(approvals, 0);
    },
  );
  test('inquiry cannot include an item belonging to another project', () async {
    final p1 = store.save('project', project('P1'));
    final p2 = store.save('project', project('P2'));
    final line = store.save('project_item', item(p1, 'labor', name: 'Labor'));
    await expectLater(
      run(tools(), 'create_record', {
        'type': 'inquiry',
        'values': {
          'project_id': p2,
          'title': 'Bad',
          'status': 'open',
          'item_ids': [line],
        },
      }),
      throwsFormatException,
    );
  });
  test(
    'receipt survives reopen and observer error; different args and stale sessions fail',
    () async {
      var approvals = 0;
      final executor = tools(
        approve: (_) async {
          approvals++;
          return true;
        },
        onChanged: () => throw StateError('UI gone'),
      );
      final args = {
        'type': 'supplier',
        'values': {'name': 'A'},
      };
      final first = await run(
        executor,
        'create_record',
        args,
        callId: 'stable',
      );
      final path =
          store.db.select('PRAGMA database_list').first['file'] as String;
      store.close();
      store = Store.open(path, device: 'assistant');
      final replay = await run(
        tools(
          approve: (_) async {
            fail('Receipt must not ask again');
          },
        ),
        'create_record',
        args,
        callId: 'stable',
      );
      expect(jsonEncode(replay), jsonEncode(first));
      expect(replay['id'], first['id']);
      expect(store.db.select('SELECT * FROM supplier'), hasLength(1));
      expect(approvals, 1);
      await expectLater(
        run(tools(), 'create_record', {
          'type': 'supplier',
          'values': {'name': 'B'},
        }, callId: 'stable'),
        throwsFormatException,
      );
      await expectLater(
        run(
          tools(validateSession: () => throw StateError('Restored')),
          'create_record',
          args,
          callId: 'stable',
        ),
        throwsStateError,
      );
    },
  );
  test('session validation runs inside the commit transaction', () async {
    var checks = 0;
    await expectLater(
      run(
        tools(
          validateSession: () {
            checks++;
            if (checks == 3) {
              expect(store.db.autocommit, isFalse);
              throw StateError('Session invalidated');
            }
          },
        ),
        'create_record',
        {
          'type': 'supplier',
          'values': {'name': 'A'},
        },
      ),
      throwsStateError,
    );
    expect(checks, 3);
    expect(store.db.select('SELECT * FROM supplier'), isEmpty);
  });
  test('receipt persistence failure rolls back the business write', () async {
    store.db.execute(
      "CREATE TRIGGER reject_receipt BEFORE INSERT ON meta WHEN NEW.key LIKE 'assistant_action:%' BEGIN SELECT RAISE(ABORT, 'receipt failed'); END",
    );
    await expectLater(
      run(tools(), 'create_record', {
        'type': 'supplier',
        'values': {'name': 'A'},
      }),
      throwsA(isA<Exception>()),
    );
    expect(store.db.select('SELECT * FROM supplier'), isEmpty);
    expect(store.db.select('SELECT * FROM change_log'), isEmpty);
  });
  test(
    'quotation clearing needs approval and preserves unspecified fields',
    () async {
      final supplierId = store.save('supplier', supplier('Supplier'));
      final productId = store.save('product', product('Material'));
      final projectId = store.save('project', project('P'));
      final id = store.save('quotation', {
        ...quotation(supplierId, productId, projectId, '5'),
        'notes': 'Keep unless approved',
      });
      final args = {
        'type': 'quotation',
        'id': id,
        'values': {'notes': null},
      };
      await run(tools(approve: (_) async => false), 'update_record', args);
      expect(store.get('quotation', id)!.data['notes'], 'Keep unless approved');
      await run(
        tools(
          approve: (preview) async {
            expect(preview.changes['notes'], {
              'before': 'Keep unless approved',
              'after': null,
            });
            return true;
          },
        ),
        'update_record',
        args,
      );
      expect(store.get('quotation', id)!.data['notes'], isNull);
      expect(store.get('quotation', id)!.data['price'], '5');
    },
  );
  test(
    'cancellation by observer after commit preserves success and receipt',
    () async {
      final args = {
        'type': 'supplier',
        'values': {'name': 'A'},
      };
      final result = await run(
        tools(onChanged: () => cancellation.cancel()),
        'create_record',
        args,
        callId: 'committed',
      );
      expect(result['status'], 'applied');
      cancellation = AiCancellation();
      final replay = await run(
        tools(),
        'create_record',
        args,
        callId: 'committed',
      );
      expect(jsonEncode(replay), jsonEncode(result));
      expect(store.db.select('SELECT * FROM supplier'), hasLength(1));
    },
  );
  test('large inquiry writes return bounded byte-identical receipts', () async {
    final projectId = store.save('project', project('Large'));
    final ids = store.transaction(
      () => [
        for (var i = 0; i < 500; i++)
          store.save('project_item', item(projectId, 'labor', name: 'Line $i')),
      ],
    );
    final id = store.save('inquiry', {
      'project_id': projectId,
      'title': 'Large inquiry',
      'item_ids': ids,
      'supplier_ids': <String>[],
      'due_date': null,
      'status': 'open',
      'notes': null,
    });
    final executor = tools();
    for (final operation in [
      'update_record',
      'delete_record',
      'restore_record',
    ]) {
      final args = <String, Object?>{
        'type': 'inquiry',
        'id': id,
        if (operation == 'update_record')
          'values': {'title': 'Updated inquiry'},
      };
      final first = await executor.execute(
        operation,
        args,
        callId: operation,
        cancellation: cancellation,
      );
      final replay = await executor.execute(
        operation,
        args,
        callId: operation,
        cancellation: cancellation,
      );
      expect(replay, first);
      expect(first.length, lessThan(2000));
      final result = jsonDecode(first) as Map;
      expect(result['status'], 'applied');
      expect(result['record_complete'], isFalse);
      expect((result['record'] as Map).containsKey('item_ids'), isFalse);
    }
    expect(executor.appliedActions, hasLength(3));
    expect(store.get('inquiry', id)!.data['item_ids'], hasLength(500));
    expect(store.get('inquiry', id)!.version, 4);
  });
  test('applied action receipts are scoped to exact trusted session', () async {
    AssistantAppTools session(String id) => AssistantAppTools(
      store,
      permission: AssistantPermission.confirmWrites,
      sessionId: id,
      approve: (_) async => true,
    );
    final exact = session('job%_😀');
    final other = session('job%_😀-other');
    await run(exact, 'create_record', {
      'type': 'supplier',
      'values': {'name': 'Exact'},
    });
    await run(other, 'create_record', {
      'type': 'supplier',
      'values': {'name': 'Other'},
    });
    expect(exact.appliedActions, hasLength(1));
    expect((exact.appliedActions.single['record'] as Map)['name'], 'Exact');
    expect(
      () => exact.appliedActions.single['status'] = 'bad',
      throwsUnsupportedError,
    );
  });
  test(
    'domain validation failure commits neither action nor receipt',
    () async {
      await expectLater(
        run(tools(), 'create_record', {
          'type': 'contact',
          'values': {
            'name': 'Contact',
            'supplier_id': newUuid(),
            'phone': '123',
          },
        }),
        throwsFormatException,
      );
      expect(store.db.select('SELECT * FROM contact'), isEmpty);
      expect(
        store.db.select(
          "SELECT * FROM meta WHERE key LIKE 'assistant_action:%'",
        ),
        isEmpty,
      );
    },
  );
}
