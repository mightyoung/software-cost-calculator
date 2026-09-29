import 'dart:async';
import 'dart:io';
import 'package:supplier_core/supplier_core.dart';

Future<void> main(List<String> args) async {
  final jobs = AiJobStore.open(args.single);
  final job = jobs.create(AiTask.conversation, {'question': 'crash'});
  final session = jobs.start(job.id);
  session.record({'step': 1}, {'content': 'durable'});
  stdout.writeln(job.id);
  await stdout.flush();
  // An unresolved Future alone does not keep the Dart event loop alive.
  Timer.periodic(const Duration(seconds: 1), (_) {});
  await Completer<void>().future;
}
