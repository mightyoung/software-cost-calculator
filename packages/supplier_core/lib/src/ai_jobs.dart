import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import 'ai_runtime.dart';
import 'store.dart';

/// Bump when workflow semantics change beyond the serialized request contract.
const aiJobProtocol = 1;

class AiJob {
  AiJob._(Map<String, Object?> row)
    : id = row['id'] as String,
      task = AiTask.values.byName(row['task'] as String),
      input = jsonDecode(row['input'] as String) as Map<String, Object?>,
      epoch = row['epoch'] as String,
      status = row['status'] as String,
      updatedAt = row['updated_at'] as String,
      message = row['message'] as String?,
      stepCount = row['step_count'] as int;
  final String id, epoch, status, updatedAt;
  final String? message;
  final AiTask task;
  final Map<String, Object?> input;
  final int stepCount;
}

/// Local-only sibling database, never inside Store's VACUUM/export surface.
/// An OS lock prevents a second process from stealing a live task. A process
/// death releases that lock; opening then pauses orphaned running tasks.
class AiJobStore {
  AiJobStore._(this._db, this._lock, this._path);
  final Database _db;
  final RandomAccessFile _lock;
  final String _path;
  static final _openPaths = <String>{};
  final _active = <String, AiJobSession>{};
  var _closed = false;

  static AiJobStore open(String path) {
    final file = File(path);
    file.parent.createSync(recursive: true);
    final canonical =
        '${file.parent.resolveSymbolicLinksSync()}/${file.uri.pathSegments.last}';
    if (!_openPaths.add(canonical)) throw LlmException('AI任务库已由其他窗口打开');
    RandomAccessFile? lock;
    Database? db;
    try {
      lock = File('$canonical.lock').openSync(mode: FileMode.append);
      lock.lockSync(FileLock.exclusive);
      db = sqlite3.open(canonical);
      db.execute('PRAGMA busy_timeout=3000');
      db.execute('PRAGMA foreign_keys=ON');
      db.execute('PRAGMA journal_mode=WAL');
      db.execute('PRAGMA synchronous=FULL');
      final version = db.select('PRAGMA user_version').single.values.single;
      if (version != 0 && version != 1)
        throw LlmException('AI任务库版本不兼容，请使用原版本应用');
      db.execute(
        'CREATE TABLE IF NOT EXISTS state(key TEXT PRIMARY KEY,value TEXT NOT NULL)',
      );
      db.execute('INSERT OR IGNORE INTO state VALUES (?,?)', [
        'epoch',
        newUuid(),
      ]);
      db.execute(
        'CREATE TABLE IF NOT EXISTS jobs('
        'id TEXT PRIMARY KEY,task TEXT NOT NULL,input TEXT NOT NULL,epoch TEXT NOT NULL,'
        'protocol INTEGER NOT NULL,status TEXT NOT NULL,owner TEXT,updated_at TEXT NOT NULL,message TEXT)',
      );
      db.execute(
        'CREATE TABLE IF NOT EXISTS steps('
        'job_id TEXT NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,position INTEGER NOT NULL,'
        'request TEXT NOT NULL,response TEXT NOT NULL,PRIMARY KEY(job_id,position))',
      );
      db.execute('PRAGMA user_version=1');
      db.execute(
        "UPDATE jobs SET status='paused',owner=NULL,message='应用中断，可继续已保存的步骤' WHERE status='running'",
      );
      return AiJobStore._(db, lock, canonical);
    } catch (_) {
      db?.close();
      lock?.closeSync();
      _openPaths.remove(canonical);
      rethrow;
    }
  }

  void _checkOpen() {
    if (_closed) throw LlmException('AI任务库已关闭');
  }

  String get epoch {
    _checkOpen();
    return _db
            .select("SELECT value FROM state WHERE key='epoch'")
            .single['value']
        as String;
  }

  static String _now() => DateTime.now().toUtc().toIso8601String();

  List<AiJob> get jobs {
    _checkOpen();
    return [
      for (final row in _db.select(
        'SELECT jobs.*,(SELECT count(*) FROM steps WHERE job_id=jobs.id) AS step_count FROM jobs ORDER BY updated_at DESC,id',
      ))
        AiJob._(row),
    ];
  }

  AiJob get(String id) {
    _checkOpen();
    final rows = _db.select(
      'SELECT jobs.*,(SELECT count(*) FROM steps WHERE job_id=jobs.id) AS step_count FROM jobs WHERE id=?',
      [id],
    );
    if (rows.isEmpty) throw LlmException('任务已删除或不存在');
    return AiJob._(rows.single);
  }

  AiJob create(AiTask task, Map<String, Object?> input) {
    _checkOpen();
    _db.execute(
      "DELETE FROM jobs WHERE status='finished' AND id NOT IN (SELECT id FROM jobs WHERE status='finished' ORDER BY updated_at DESC LIMIT 50)",
    );
    if ((_db
                .select(
                  "SELECT count(*) AS n FROM jobs WHERE status!='finished'",
                )
                .single['n']
            as int) >=
        100) {
      throw LlmException('本机已保存100个未完成AI任务，请先继续或删除不再需要的任务');
    }
    final data = jsonEncode(input);
    if (utf8.encode(data).length > 32 * 1024 * 1024)
      throw LlmException('任务附件过大，请缩小输入');
    final id = newUuid();
    _db.execute('INSERT INTO jobs VALUES(?,?,?,?,?,?,?,?,?)', [
      id,
      task.name,
      data,
      epoch,
      aiJobProtocol,
      'paused',
      null,
      _now(),
      null,
    ]);
    return get(id);
  }

  AiJobSession start(String id, {AiCancellation? cancellation}) {
    final job = get(id);
    if (job.epoch != epoch || job.status == 'stale')
      throw LlmException('资料库已恢复，此任务已失效，请使用原文新建任务');
    if (job.status == 'finished') throw LlmException('此任务已经完成，不能重复继续');
    if (job.status == 'running') throw LlmException('此任务正在运行，请勿重复启动');
    final protocol = _db.select('SELECT protocol FROM jobs WHERE id=?', [
      id,
    ]).single['protocol'];
    if (protocol != aiJobProtocol) {
      throw LlmException('任务流程版本已变化，请使用原文新建任务');
    }
    final session = AiJobSession._(
      this,
      id,
      job.epoch,
      newUuid(),
      cancellation ?? AiCancellation(),
    );
    _db.execute(
      "UPDATE jobs SET status='running',owner=?,updated_at=?,message=NULL WHERE id=?",
      [session._owner, _now(), id],
    );
    _active[id] = session;
    return session;
  }

  void validate(String id) {
    final job = get(id);
    if (job.epoch != epoch || job.status == 'stale')
      throw LlmException('资料库已恢复，旧AI结果不可应用');
    if (job.status != 'ready') throw LlmException('任务尚未完成或已经确认，请重新检查任务状态');
  }

  void finish(String id) {
    validate(id);
    _db.execute("UPDATE jobs SET status='finished',updated_at=? WHERE id=?", [
      _now(),
      id,
    ]);
  }

  void discard(String id) {
    _checkOpen();
    _db.execute('DELETE FROM jobs WHERE id=?', [id]);
    _active.remove(id)?.cancellation.cancel('任务已删除');
  }

  void invalidateAll() {
    _checkOpen();
    _db.execute('BEGIN IMMEDIATE');
    try {
      _db.execute("UPDATE state SET value=? WHERE key='epoch'", [newUuid()]);
      _db.execute(
        "UPDATE jobs SET status='stale',owner=NULL,message='整库恢复使旧任务失效',updated_at=? WHERE status!='finished'",
        [_now()],
      );
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
    for (final session in _active.values.toList()) {
      session.cancellation.cancel('资料库正在恢复，AI任务已暂停并失效');
    }
    _active.clear();
  }

  void close() {
    if (_closed) return;
    for (final session in _active.values.toList()) {
      session.pause('应用已关闭，可继续已保存的步骤');
      session.cancellation.cancel();
    }
    _closed = true;
    _db.close();
    _lock.closeSync();
    _openPaths.remove(_path);
  }
}

class AiJobSession implements AiCheckpoint {
  AiJobSession._(
    this._store,
    this.id,
    this._epoch,
    this._owner,
    this.cancellation,
  );
  final AiJobStore _store;
  final String id, _epoch, _owner;
  final AiCancellation cancellation;
  int _position = 0;
  int replayedCalls = 0;
  bool _ended = false;

  void check() {
    _store._checkOpen();
    cancellation.check();
    final rows = _store._db.select(
      'SELECT epoch,owner,status FROM jobs WHERE id=?',
      [id],
    );
    if (_ended ||
        rows.isEmpty ||
        rows.single['epoch'] != _store.epoch ||
        rows.single['epoch'] != _epoch ||
        rows.single['owner'] != _owner ||
        rows.single['status'] != 'running') {
      throw LlmException('AI任务已结束、删除或失效，迟到结果未应用');
    }
  }

  @override
  Map<String, Object?>? restore(Map<String, Object?> request) {
    check();
    final rows = _store._db.select(
      'SELECT request,response FROM steps WHERE job_id=? AND position=?',
      [id, _position],
    );
    if (rows.isEmpty) return null;
    if (rows.single['request'] != jsonEncode(request)) {
      // New candidate data, prompts, model or tool results invalidate the suffix.
      _store._db.execute('DELETE FROM steps WHERE job_id=? AND position>=?', [
        id,
        _position,
      ]);
      return null;
    }
    final value =
        jsonDecode(rows.single['response'] as String) as Map<String, Object?>;
    _position++;
    replayedCalls++;
    return value;
  }

  @override
  void record(Map<String, Object?> request, Map<String, Object?> message) {
    check();
    final requestText = jsonEncode(request), responseText = jsonEncode(message);
    if (requestText.length > 200000 || responseText.length > 128000) {
      throw LlmException('AI检查点超过单步容量，结果未保存');
    }
    _store._db.execute('BEGIN IMMEDIATE');
    try {
      check();
      _store._db.execute('INSERT OR REPLACE INTO steps VALUES(?,?,?,?)', [
        id,
        _position,
        requestText,
        responseText,
      ]);
      _store._db.execute('UPDATE jobs SET updated_at=? WHERE id=?', [
        AiJobStore._now(),
        id,
      ]);
      _store._db.execute('COMMIT');
      _position++;
    } catch (_) {
      _store._db.execute('ROLLBACK');
      rethrow;
    }
  }

  @override
  void rejectLast() {
    check();
    if (_position == 0) return;
    _position--;
    _store._db.execute('DELETE FROM steps WHERE job_id=? AND position>=?', [
      id,
      _position,
    ]);
  }

  void ready() {
    check();
    // A newer workflow may finish earlier than the saved replay suffix.
    _store._db.execute('DELETE FROM steps WHERE job_id=? AND position>=?', [
      id,
      _position,
    ]);
    _end('ready', null);
  }

  void pause([String? message]) => _end('paused', message);
  void _end(String status, String? message) {
    if (_ended || _store._closed) return;
    _store._db.execute(
      'UPDATE jobs SET status=?,owner=NULL,message=?,updated_at=? WHERE id=? AND owner=? AND epoch=?',
      [status, message, AiJobStore._now(), id, _owner, _epoch],
    );
    _ended = true;
    if (identical(_store._active[id], this)) _store._active.remove(id);
  }
}
