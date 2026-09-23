import 'dart:io';
import 'package:storage_gate/storage_gate.dart';

Future<void> main(List<String> args) async {
  if (args.first == 'lock') {
    await ApplicationLock('${args[1]}/application.lock').run(() async {
      stdout.writeln('acquired');
      await stdout.flush();
      await stdin.first;
    });
    return;
  }
  final gate = StorageGate(args[1]);
  await gate.initialize();
  await gate.activate(
    await gate.active(),
    args[2],
    await fileDigest(args[2]),
    expectedGeneration: 7,
    fault: (stage) async {
      if (stage == args[3]) exit(73); // Abrupt process exit, no Dart cleanup.
    },
  );
  await gate.close();
}
