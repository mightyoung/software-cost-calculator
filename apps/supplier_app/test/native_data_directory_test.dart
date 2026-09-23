import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:supplier_app/app/workspace.dart';
import 'package:supplier_app/platform/workspace_factory_native.dart';

void main() {
  test('explicit directory takes precedence over the Android plugin', () async {
    final directory = await resolveNativeDataDirectory(
      configured: '/deployment/library',
      operatingSystem: 'android',
      environment: const {},
      applicationSupportDirectory: () => throw StateError('must not be called'),
    );
    expect(directory.path, '/deployment/library');
  });

  test(
    'Android uses application support without desktop environment',
    () async {
      var calls = 0;
      final directory = await resolveNativeDataDirectory(
        operatingSystem: 'android',
        environment: const {},
        applicationSupportDirectory: () async {
          calls++;
          return Directory('/data/user/0/example.supplier/files');
        },
      );
      expect(directory.path, '/data/user/0/example.supplier/files');
      expect(calls, 1);
    },
  );

  test('Android plugin failure propagates without fallback', () async {
    final failure = StateError('native directory unavailable');
    await expectLater(
      resolveNativeDataDirectory(
        operatingSystem: 'android',
        applicationSupportDirectory: () async => throw failure,
      ),
      throwsA(same(failure)),
    );
  });

  test('Android rejects a relative provider directory', () async {
    await expectLater(
      resolveNativeDataDirectory(
        operatingSystem: 'android',
        applicationSupportDirectory: () async => Directory(''),
      ),
      throwsA(isA<WorkspaceUnavailable>()),
    );
  });

  for (final scenario in [
    (
      'macos',
      {'HOME': '/users/operator'},
      '/users/operator/Library/Application Support/SupplierInquiry',
    ),
    (
      'windows',
      {'LOCALAPPDATA': 'C:/Users/operator/AppData/Local'},
      'C:/Users/operator/AppData/Local/SupplierInquiry',
    ),
    (
      'linux',
      {'HOME': '/home/operator'},
      '/home/operator/.local/share/supplier-inquiry',
    ),
    (
      'linux',
      {'HOME': '/home/operator', 'XDG_DATA_HOME': '/data'},
      '/data/supplier-inquiry',
    ),
  ]) {
    test('desktop directory policy is preserved: ${scenario.$3}', () async {
      final directory = await resolveNativeDataDirectory(
        operatingSystem: scenario.$1,
        environment: scenario.$2,
        applicationSupportDirectory: () =>
            throw StateError('must not be called'),
      );
      expect(directory.path, scenario.$3);
    });
  }

  test('unsupported platform fails instead of choosing current directory', () {
    expect(
      resolveNativeDataDirectory(operatingSystem: 'unknown', environment: {}),
      throwsA(isA<WorkspaceUnavailable>()),
    );
  });
}
