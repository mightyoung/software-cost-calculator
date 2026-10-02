"""Runner safety tests: no actual device allocation or mount is performed."""
import json
import pathlib
import plistlib
import tempfile
import unittest
from unittest.mock import patch

from tool import run_native_disk_full as runner


class RunnerSafetyTest(unittest.TestCase):
    def exercise(self, attached, device_info, harness_pass=True):
        commands = []
        with tempfile.TemporaryDirectory() as root:
            output = pathlib.Path(root) / 'new-run'

            def fake_run(*args):
                commands.append(args)
                if args == ('/sbin/mount',):
                    return f'/dev/disk99 on {output.resolve() / "ram-volume"} (hfs, local)\n'.encode()
                if args[1] == 'attach':
                    return attached.encode()
                if args[1] == 'info':
                    return plistlib.dumps({**device_info, 'MountPoint': str(output / 'ram-volume')})
                return b''

            def fake_dart(args):
                pathlib.Path(args[-1]).write_text(json.dumps({'status': 'PASS' if harness_pass else 'FAIL'}))
                return type('Result', (), {'returncode': 0 if harness_pass else 1})()

            with patch.object(runner.sys, 'platform', 'darwin'), patch.object(runner.sys, 'argv', ['runner', '--dart', '/fake/dart', '--out', str(output)]), patch.object(runner, 'run', fake_run), patch.object(runner.subprocess, 'run', fake_dart):
                code = runner.main()
            return code, json.loads((output / 'report.json').read_text()), commands

    def test_malformed_device_never_formats_or_mounts(self):
        code, report, commands = self.exercise('/dev/disk1\n/dev/disk2', {})
        self.assertEqual(code, 1)
        self.assertEqual(report['status'], 'FAIL')
        self.assertEqual(len(commands), 1)

    def test_physical_device_rejected_before_format(self):
        code, _, commands = self.exercise('/dev/disk99', {'TotalSize': 67108864, 'VirtualOrPhysical': 'Physical'})
        self.assertEqual(code, 1)
        self.assertFalse(any('newfs_hfs' in row[0] for row in commands))
        self.assertEqual(commands[-1], ('/usr/bin/hdiutil', 'detach', '/dev/disk99'))

    def test_success_and_failure_both_unmount_and_detach(self):
        for succeeds in [True, False]:
            with self.subTest(succeeds=succeeds):
                code, report, commands = self.exercise('/dev/disk99', {'TotalSize': 67108864, 'VirtualOrPhysical': 'Virtual'}, succeeds)
                self.assertEqual(code, 0 if succeeds else 1)
                self.assertEqual(report['cleanup'], 'PASS')
                self.assertEqual(commands[-2][0], '/sbin/umount')
                self.assertEqual(commands[-1], ('/usr/bin/hdiutil', 'detach', '/dev/disk99'))


if __name__ == '__main__':
    unittest.main()
