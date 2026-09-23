import 'package:supplier_core/supplier_core.dart';

/// Available before parsing starts, including the initial source fingerprint.
/// The UI acknowledges synchronously; readers stop at their next bounded chunk.
final class ImportCancellation {
  bool requested = false;
  Future<void> Function()? _cancelJob;

  void check() {
    if (requested) throw const DomainFailure('CANCELLED', '文件解析已取消');
  }

  Future<void> attach(Future<void> Function() cancelJob) async {
    _cancelJob = cancelJob;
    if (requested) await cancelJob();
    check();
  }

  Future<void> cancel() async {
    requested = true;
    await _cancelJob?.call();
  }

  InputSource wrap(InputSource source) => _CancellableSource(source, this);
}

final class _CancellableSource implements InputSource {
  _CancellableSource(this.source, this.cancellation);
  final InputSource source;
  final ImportCancellation cancellation;
  @override
  String get displayName => source.displayName;
  @override
  Future<int> length() async {
    cancellation.check();
    return source.length();
  }

  @override
  Stream<List<int>> openRange(int start, int endExclusive) async* {
    cancellation.check();
    await for (final bytes in source.openRange(start, endExclusive)) {
      cancellation.check();
      yield bytes;
    }
    cancellation.check();
  }
}
