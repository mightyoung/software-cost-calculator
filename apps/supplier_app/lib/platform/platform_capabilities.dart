/// A capability is verified only by a real target-platform experiment.
/// API presence and shell tests are diagnostic information, never PASS evidence.
enum Capability {
  restartPersistence('重启持久化'),
  exclusiveWriter('跨进程／跨标签写锁'),
  rangedRead('有界文件分段读取'),
  streamingWrite('有界流式写入与关闭确认'),
  consistentSnapshot('一致且有界的数据库快照'),
  atomicActivePointer('崩溃安全的活动库指针'),
  engineIdentity('SQLite 引擎／Worker／WASM 版本');

  const Capability(this.label);
  final String label;
}

enum ProbeStatus { pass, fail, blocked }

class CapabilityEvidence {
  const CapabilityEvidence({
    required this.status,
    required this.detail,
    this.artifact,
  });

  final ProbeStatus status;
  final String detail;
  final String? artifact;

  bool get verified =>
      status == ProbeStatus.pass &&
      detail.trim().isNotEmpty &&
      artifact != null &&
      artifact!.trim().isNotEmpty;
}

class PlatformCapabilities {
  PlatformCapabilities({
    required this.target,
    Map<Capability, CapabilityEvidence> evidence = const {},
  }) : evidence = Map.unmodifiable(evidence);

  final String target;
  final Map<Capability, CapabilityEvidence> evidence;

  CapabilityEvidence result(Capability capability) =>
      evidence[capability] ??
      const CapabilityEvidence(
        status: ProbeStatus.blocked,
        detail: '尚无真实目标平台证据，业务写入保持关闭。',
      );

  bool get productionWritesAllowed =>
      Capability.values.every((capability) => result(capability).verified);
}

abstract interface class PlatformProbe {
  Future<PlatformCapabilities> inspect();
}

/// Deliberately does not infer durable storage from the operating system name.
/// Replace each BLOCKED result only with an independently verified adapter probe.
class UnverifiedPlatformProbe implements PlatformProbe {
  const UnverifiedPlatformProbe(this.target);
  final String target;

  @override
  Future<PlatformCapabilities> inspect() async =>
      PlatformCapabilities(target: target);
}
