import 'package:flutter_test/flutter_test.dart';
import 'package:supplier_app/platform/platform_capabilities.dart';

void main() {
  test(
    'all target platforms default to blocked with no production writes',
    () async {
      for (final target in ['windows', 'android', 'web', 'unsupported']) {
        final report = await UnverifiedPlatformProbe(target).inspect();
        expect(report.productionWritesAllowed, isFalse);
        for (final capability in Capability.values) {
          expect(report.result(capability).status, ProbeStatus.blocked);
        }
      }
    },
  );

  test('one missing, failed or unsupported capability keeps gate closed', () {
    for (final absent in Capability.values) {
      for (final status in [null, ProbeStatus.blocked, ProbeStatus.fail]) {
        final evidence = {
          for (final capability in Capability.values)
            if (capability != absent)
              capability: const CapabilityEvidence(
                status: ProbeStatus.pass,
                detail: 'Synthetic gate-policy fixture only',
                artifact: 'fixture://not-platform-evidence',
              ),
        };
        if (status != null) {
          evidence[absent] = CapabilityEvidence(
            status: status,
            detail: 'Not verified',
          );
        }
        expect(
          PlatformCapabilities(
            target: 'test',
            evidence: evidence,
          ).productionWritesAllowed,
          isFalse,
        );
      }
    }
  });

  test('PASS without an evidence reference is never verified', () {
    expect(
      const CapabilityEvidence(
        status: ProbeStatus.pass,
        detail: 'API exists',
      ).verified,
      isFalse,
    );
  });

  test('gate report owns an immutable evidence snapshot', () {
    final evidence = <Capability, CapabilityEvidence>{};
    final report = PlatformCapabilities(target: 'test', evidence: evidence);
    evidence[Capability.restartPersistence] = const CapabilityEvidence(
      status: ProbeStatus.pass,
      detail: 'fixture',
      artifact: 'fixture://test',
    );
    expect(
      report.result(Capability.restartPersistence).status,
      ProbeStatus.blocked,
    );
    expect(() => report.evidence.clear(), throwsUnsupportedError);
  });
}
