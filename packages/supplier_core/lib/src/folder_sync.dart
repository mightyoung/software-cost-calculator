import 'dart:convert';
import 'dart:io';

import 'exchange.dart';
import 'store.dart';

/// Outcome of one pass over a shared folder. [seen] is what the caller
/// keeps for the next pass (file name -> modified time and size).
class FolderSync {
  FolderSync(this.imported, this.failed, this.seen);
  final List<String> imported;
  final Map<String, String> failed;
  final Map<String, String> seen;
}

const _own = '(own)';

/// Name of the file in the shared folder that announces a new version.
const updateManifest = '版本.json';

class UpdateNotice {
  UpdateNotice(this.version, this.notes, this.file);
  final String version;
  final String? notes, file;
}

extension FolderSyncing on Store {
  /// Syncs through a folder every device can reach (network share, NAS or
  /// a cloud-drive folder). Each device writes only its own file, so the
  /// drive never sees two writers of one file. Other devices' files are
  /// imported first, so the file written afterwards carries everything
  /// this device knows and new data spreads in one round. A file is read
  /// again only when its time or size changed; unreadable files (damaged,
  /// still uploading) are reported and retried next time.
  // ponytail: every device keeps a full snapshot in the folder (N x database
  // size); switch to per-device change files if the folder gets too large.
  FolderSync syncWithFolder(
    String dir, {
    required String ownName,
    required Map<String, String> seen,
  }) {
    final next = Map.of(seen);
    final imported = <String>[];
    final failed = <String, String>{};
    final files =
        Directory(dir)
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.siq'))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    for (final f in files) {
      final name = f.uri.pathSegments.last;
      if (name == ownName) continue;
      final stat = f.statSync();
      final mark = '${stat.modified.toUtc().toIso8601String()}|${stat.size}';
      if (seen[name] == mark) continue;
      try {
        importFrom(f.path);
        imported.add(name);
        next[name] = mark;
      } on Object catch (e) {
        failed[name] = e is FormatException ? e.message : '$e';
      }
    }
    // Rewrite our file only when this device's data changed: a fresh time
    // stamp would make every other device read it again.
    final r = db.select('SELECT max(at) AS at, count(*) AS n FROM change_log');
    final state = '${r.first['at']}|${r.first['n']}';
    if (next[_own] != state || !File('$dir/$ownName').existsSync()) {
      exportTo('$dir/$ownName');
      next[_own] = state;
    }
    return FolderSync(imported, failed, next);
  }
}

/// A newer version announced in [dir], or null. Versions compare by their
/// numeric parts ("1.0.12" > "1.0.5").
UpdateNotice? readUpdate(String dir, {required String current}) {
  final file = File('$dir/$updateManifest');
  if (!file.existsSync()) return null;
  try {
    final m = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
    final version = m['version'] as String;
    if (compareVersions(version, current) <= 0) return null;
    return UpdateNotice(version, m['notes'] as String?, m['file'] as String?);
  } on Object {
    return null; // a malformed announcement is ignored, not fatal
  }
}

int compareVersions(String a, String b) {
  List<int> parts(String v) => [
    for (final p in v.split(RegExp(r'[.+-]'))) int.tryParse(p) ?? 0,
  ];
  final x = parts(a), y = parts(b);
  for (var i = 0; i < x.length || i < y.length; i++) {
    final d = (i < x.length ? x[i] : 0).compareTo(i < y.length ? y[i] : 0);
    if (d != 0) return d;
  }
  return 0;
}
