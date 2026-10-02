#!/usr/bin/env python3
"""Real ENOSPC on a newly allocated 64 MiB RAM disk; never formats user disks.

Usage: python3 tool/run_native_disk_full.py --dart /path/to/dart --out /path/to/new-output
Run from apps/supplier_app. macOS native evidence only, not Android/Windows.
"""
import argparse
import json
import pathlib
import plistlib
import re
import subprocess
import sys
import uuid


def run(*args):
    return subprocess.run(args, check=True, capture_output=True).stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dart', required=True)
    parser.add_argument('--out', required=True)
    args = parser.parse_args()
    if sys.platform != 'darwin':
        parser.error('macOS only')
    output = pathlib.Path(args.out).resolve()
    output.mkdir(parents=True, exist_ok=False)
    mount = output / 'ram-volume'
    mount.mkdir()
    report = output / 'report.json'
    state = {'status': 'RUNNING', 'run_id': str(uuid.uuid4())}
    report.write_text(json.dumps(state, indent=2))
    device = None
    mounted = False
    try:
        # Parse only the device returned by this exact allocation. No caller can
        # provide a device argument and no existing disk is selected by index.
        attached = run('/usr/bin/hdiutil', 'attach', '-nomount', 'ram://131072').decode().strip()
        if not re.fullmatch(r'/dev/disk[0-9]+', attached):
            raise RuntimeError(f'Unexpected RAM allocation response: {attached!r}')
        device = attached
        info = plistlib.loads(run('/usr/sbin/diskutil', 'info', '-plist', device))
        if info.get('TotalSize') != 67108864 or info.get('VirtualOrPhysical') != 'Virtual':
            raise RuntimeError('Allocated device is not the expected 64 MiB virtual disk')
        run('/sbin/newfs_hfs', '-v', 'SupplierI05', device)
        run('/sbin/mount', '-t', 'hfs', device, str(mount))
        mounted = True
        # Raw mount(8) does not always populate diskutil's MountPoint field.
        # Verify the kernel mount table names this exact new virtual device and
        # this exact directory before writing to it.
        mounted_lines = run('/sbin/mount').decode().splitlines()
        matching = [line for line in mounted_lines if line.startswith(f'{device} on {mount} (')]
        state['mount_table_match'] = matching
        if len(matching) != 1 or 'hfs' not in matching[0].lower():
            raise RuntimeError('Mounted volume identity mismatch')
        nonce = str(uuid.uuid4())
        (mount / 'runner-nonce').write_text(nonce)
        result = subprocess.run([args.dart, 'run', 'tool/native_disk_full.dart', str(mount), nonce, str(report)])
        state = json.loads(report.read_text())
        state['device'] = device
        state['returncode'] = result.returncode
        if result.returncode or state.get('status') != 'PASS':
            raise RuntimeError('Native ENOSPC harness did not pass')
    except BaseException as error:
        state['status'] = 'FAIL'
        state['runner_error'] = str(error)
    finally:
        try:
            if mounted:
                run('/sbin/umount', str(mount))
            if device:
                run('/usr/bin/hdiutil', 'detach', device)
            state['cleanup'] = 'PASS'
        except BaseException as error:
            state['status'] = 'FAIL'
            state['cleanup'] = str(error)
        report.write_text(json.dumps(state, indent=2))
    print(report)
    return 0 if state['status'] == 'PASS' else 1


if __name__ == '__main__':
    sys.exit(main())
