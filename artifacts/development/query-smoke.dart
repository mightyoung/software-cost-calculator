import 'package:drift/native.dart';
import 'package:drift/drift.dart';
import 'package:supplier_core/supplier_core.dart';
class Lock implements ApplicationWriteLock {
  @override Future<T> run<T>(Future<T> Function() action)=>action();
}
Future<void> main() async {
  final db=SupplierDatabase(NativeDatabase.memory(),instanceId:'compile-smoke');
  final coordinator=CommitCoordinator(database:db,writeLock:Lock(),readActiveVersion:db.currentVersion);
  final service=RecordService(coordinator,deviceId:'00000000-0000-4000-8000-999999999999');
  final id=await service.createEntity('supplier',{'name':'Smoke','aliases':<String>[],'address':null,'categories':<String>[],'notes':null});
  final row=await db.rows('SELECT name FROM supplier_projection WHERE entity_id=?',[Variable(id)]);
  if(row.single.read<String>('name')!='Smoke' || (await db.currentVersion()).generation!=1) throw StateError('Smoke failed');
  final plan=await db.rows('EXPLAIN QUERY PLAN SELECT entity_type,entity_id FROM graph_entity WHERE run_id=? AND (entity_type,entity_id)>(?,?) ORDER BY entity_type,entity_id LIMIT ?',[Variable('run'),Variable('supplier'),Variable('id'),Variable(2)]);
  for(final row in plan) {print(row.read<String>('detail'));}
  final neighbors=await db.rows('EXPLAIN QUERY PLAN SELECT entity_type,target_id entity_id FROM graph_redirect WHERE run_id=? AND entity_type=? AND source_id=? AND target_id>? UNION SELECT entity_type,source_id entity_id FROM graph_redirect WHERE run_id=? AND entity_type=? AND target_id=? AND source_id>? ORDER BY entity_type,entity_id LIMIT ?',[Variable('run'),Variable('supplier'),Variable('id'),Variable('after'),Variable('run'),Variable('supplier'),Variable('id'),Variable('after'),Variable(2)]);
  for(final row in neighbors) {print(row.read<String>('detail'));}
  final queries=QueryRepository(db);
  if((await queries.candidates('supplier',{'name':'smoke'})).single.id!=id) throw StateError('Candidate smoke failed');
  if((await queries.quotations({'view':'confirmed_lowest','as_of':'2026-09-17'})).items.isNotEmpty) throw StateError('Query smoke failed');
  print('Compiled core SQL create+projection+generation+query smoke passed');
  await db.close();
}
