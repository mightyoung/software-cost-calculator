import 'package:supplier_app/platform/import_cancellation.dart';
import 'package:supplier_core/supplier_core.dart';

/// Cancels at the first real source read, after a durable task was allocated.
final class CancellingSource implements InputSource {
  CancellingSource(this.source, this.cancellation);
  final InputSource source;
  final ImportCancellation cancellation;
  @override
  String get displayName => source.displayName;
  @override
  Future<int> length() => source.length();
  @override
  Stream<List<int>> openRange(int start, int endExclusive) async* {
    await cancellation.cancel();
    yield* source.openRange(start, endExclusive);
  }
}
