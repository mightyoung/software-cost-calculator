#!/usr/bin/env python3
"""Run the formal import fixture with an explicit commit-time gate.

The Dart report remains the correctness authority. This wrapper records a
time-gate failure and interrupts the child when commit exceeds the target.
"""

import argparse
import json
import os
from pathlib import Path
import selectors
import signal
import subprocess
import sys
import time


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument('--dart', required=True)
    parser.add_argument('--count', type=int, required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--limit-seconds', type=float, default=600)
    parser.add_argument('--cache-kib', type=int)
    args = parser.parse_args()
    if (args.count < 1 or args.count > 100000 or args.limit_seconds <= 0 or
            (args.cache_kib is not None and not 1024 <= args.cache_kib <= 131072)):
        parser.error('Invalid count or time limit')
    if args.out.exists():
        parser.error('Output directory must be new')
    args.out.parent.mkdir(parents=True, exist_ok=True)
    report = args.out.with_name(args.out.name + '-time-gate.json')
    log = args.out.with_name(args.out.name + '-console.log')
    command = [args.dart, 'run', 'tool/full_chain_scale.dart',
               f'--count={args.count}', f'--out={args.out}', '--import-only=true']
    if args.cache_kib is not None:
        command.append(f'--cache-kib={args.cache_kib}')
    state = {'status': 'RUNNING', 'count': args.count,
             'limit_seconds': args.limit_seconds, 'command': command,
             'scope': 'Formal fixture staging plus CommitCoordinator commit only'}
    report.write_text(json.dumps(state, indent=2) + '\n')
    started = time.monotonic()
    commit_started = None
    saw_digest = False
    with log.open('w') as output:
        process = subprocess.Popen(command, stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT, text=True,
                                   bufsize=1, env=os.environ.copy())
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ)
            while process.poll() is None:
                commit_elapsed = (time.monotonic() - commit_started
                                  if commit_started is not None else None)
                if not saw_digest and (commit_elapsed is not None and
                                       commit_elapsed > args.limit_seconds):
                    process.send_signal(signal.SIGINT)
                    try:
                        process.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()
                    state['status'] = 'TIME_GATE_FAIL'
                    state['reason'] = 'formal_fixture_commit did not finish before limit'
                    break
                if selector.select(timeout=.25):
                    line = process.stdout.readline()
                    if line:
                        output.write(line)
                        output.flush()
                        if 'phase=formal_fixture_commit' in line and commit_started is None:
                            commit_started = time.monotonic()
                        if 'phase=source_digest' in line:
                            saw_digest = True
                            if commit_started is not None:
                                state['commit_elapsed_seconds_observed'] = time.monotonic() - commit_started
            for line in process.stdout:
                output.write(line)
        output.flush()
    state['elapsed_seconds'] = time.monotonic() - started
    state['child_exit_code'] = process.returncode
    if state['status'] == 'RUNNING':
        dart_report = args.out / 'report.json'
        if process.returncode == 0 and dart_report.exists():
            result = json.loads(dart_report.read_text())
            state['status'] = ('PASS' if result.get('status') == 'PASS' and
                               result['result']['timings_ms']['formal_fixture_commit']
                               <= args.limit_seconds * 1000 else 'FAIL')
            state['formal_fixture_commit_ms'] = result['result']['timings_ms']['formal_fixture_commit']
        else:
            state['status'] = 'FAIL'
            state['reason'] = 'Dart command failed before a successful report'
    report.write_text(json.dumps(state, indent=2) + '\n')
    print(report)
    return 0 if state['status'] == 'PASS' else 1


if __name__ == '__main__':
    sys.exit(main())
