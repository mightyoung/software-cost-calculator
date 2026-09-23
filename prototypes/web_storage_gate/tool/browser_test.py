"""NONPRODUCT integration test using only a temporary, dedicated Chrome profile.
Requires Python websocket-client and local macOS Chrome. Never attaches to user Chrome.
"""
import base64
import functools
import hashlib
import http.server
import json
import os
import pathlib
import signal
import subprocess
import tempfile
import threading
import time
import urllib.request

import websocket

BASE = pathlib.Path(__file__).resolve().parents[1]


class Handler(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header('Cross-Origin-Opener-Policy', 'same-origin')
        self.send_header('Cross-Origin-Embedder-Policy', 'require-corp')
        super().end_headers()

    def log_message(self, *args):
        pass


class Browser:
    def __init__(self, profile, log):
        self.profile = profile
        self.log = log
        self.process = None
        self.ws = None
        self.seq = 0

    def start(self):
        # Avoid treating a previous browser's port file as a running endpoint.
        portfile = pathlib.Path(self.profile) / 'DevToolsActivePort'
        portfile.unlink(missing_ok=True)
        self.process = subprocess.Popen([
            '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
            '--headless=new', '--no-first-run', '--no-default-browser-check',
            '--disable-popup-blocking', '--remote-debugging-port=0',
            '--remote-allow-origins=http://localhost',
            '--user-data-dir=' + self.profile, 'about:blank',
        ], stdout=self.log, stderr=self.log, start_new_session=True)
        for _ in range(200):
            if portfile.exists():
                break
            if self.process.poll() is not None:
                raise RuntimeError('Chrome failed; see evidence/chrome.log')
            time.sleep(.1)
        self.port = portfile.read_text().splitlines()[0]
        tabs = self.targets()
        self.ws = websocket.create_connection(
            next(t['webSocketDebuggerUrl'] for t in tabs if t['type'] == 'page'),
            origin='http://localhost', timeout=60)
        return self.process.pid

    def targets(self):
        with urllib.request.urlopen('http://127.0.0.1:' + self.port + '/json') as response:
            return json.load(response)

    def call(self, method, params=None):
        self.seq += 1
        self.ws.send(json.dumps(dict(id=self.seq, method=method, params=params or {})))
        while True:
            result = json.loads(self.ws.recv())
            if result.get('id') == self.seq:
                if 'error' in result:
                    raise RuntimeError(result)
                return result['result']

    def evaluate(self, expression, wait=True):
        result = self.call('Runtime.evaluate', dict(
            expression=expression, awaitPromise=wait, returnByValue=True))
        if 'exceptionDetails' in result:
            raise RuntimeError(result)
        return result.get('result', {}).get('value')

    def ready(self):
        for _ in range(200):
            if self.evaluate('Boolean(window.probeReady)'):
                return
            time.sleep(.1)
        raise RuntimeError('Dart probe never ready')

    def navigate(self, url):
        self.call('Page.navigate', dict(url=url))
        self.ready()

    def stop(self, force=False):
        process = self.process
        if process is None:
            return None
        if force:
            # Only the new session/process group explicitly created by this runner.
            assert os.getpgid(process.pid) == process.pid
            os.killpg(process.pid, signal.SIGKILL)
        elif process.poll() is None:
            try:
                self.call('Browser.close')
            except (websocket.WebSocketConnectionClosedException, json.JSONDecodeError):
                pass  # Chrome can close the socket before replying to Browser.close.
        process.wait(timeout=15)
        if self.ws:
            self.ws.close()
            self.ws = None
        exit_code = process.returncode
        self.process = None
        return dict(pid=process.pid, exitCode=exit_code,
                    method='SIGKILL isolated process group' if force else 'CDP Browser.close')


def export_readback(browser, run, result):
    actual = hashlib.sha256()
    for offset in range(0, result['bytes'], 65536):
        expression = f"""(async()=>{{
          const root=await navigator.storage.getDirectory();
          const h=await root.getFileHandle('nonproduct-t1-export-{run}');
          const f=await h.getFile();
          const b=new Uint8Array(await f.slice({offset},{offset+65536}).arrayBuffer());
          return btoa(String.fromCharCode(...b));
        }})()"""
        actual.update(base64.b64decode(browser.evaluate(expression)))
    expected = hashlib.sha256()
    for first in range(1, 1026, 64):
        page = [dict(id=i, payload=str(i).zfill(256))
                for i in range(first, min(first + 64, 1026))]
        expected.update((json.dumps(page, separators=(',', ':')) + '\n').encode())
    assert actual.hexdigest() == expected.hexdigest() == result['snapshot']['sha256']
    return actual.hexdigest()


def main():
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(
        Handler, directory=str(BASE / 'web')))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    evidence = dict(status='RUNNING', stages={})
    try:
        with tempfile.TemporaryDirectory(prefix='nonproduct-t1-chrome-') as profile:
            with open(BASE / 'evidence/chrome.log', 'w') as log:
                browser = Browser(profile, log)
                try:
                    initial_pid = browser.start()
                    run = str(time.time_ns())
                    url = f'http://127.0.0.1:{server.server_port}/?run={run}'
                    browser.navigate(url)
                    result = browser.evaluate('runTests().catch(e => ({failure:String(e), stack:e?.stack, stage:window.stage}))')
                    if 'failure' in result:
                        raise RuntimeError(result)
                    pages = [dict(id=t['id'], type=t['type'], url=t['url'])
                             for t in browser.targets() if t['type'] == 'page' and run in t['url']]
                    assert len(pages) == 2 and any('peer=1' in t['url'] for t in pages)
                    result['topLevelTargets'] = pages
                    result['exportReadbackSha256'] = export_readback(browser, run, result)
                    evidence['result'] = result
                    browser.call('Page.reload')
                    time.sleep(.5)
                    browser.ready()
                    evidence['reload'] = browser.evaluate('checkReload()')
                    evidence['stages']['normalExit'] = browser.stop()
                    assert evidence['stages']['normalExit']['exitCode'] == 0

                    restarted_pid = browser.start()
                    assert restarted_pid != initial_pid
                    browser.navigate(url)
                    evidence['normalRestart'] = browser.evaluate('checkReload()')
                    evidence['normalRestart']['pid'] = restarted_pid
                    evidence['normalRestart']['exportReadbackSha256'] = export_readback(browser, run, result)
                    # A new write after restart proves locks/connections were reacquired.
                    browser.evaluate('commit({instance:"new",epoch:2})')
                    evidence['beforeCrash'] = browser.evaluate('checkReload(5)')
                    browser.evaluate('beginCrashWrite().catch(e => {window.crashError=String(e);}); void 0', wait=False)
                    for _ in range(200):
                        if browser.evaluate('Boolean(window.crashBarrierReached)'):
                            break
                        error = browser.evaluate('window.crashError')
                        if error:
                            raise RuntimeError(error)
                        time.sleep(.05)
                    else:
                        raise RuntimeError('Crash write did not reach SQL barrier')
                    evidence['stages']['crashBarrier'] = 'SQL UPDATE rows and generation executed; transaction not committed'
                    evidence['stages']['forcedExit'] = browser.stop(force=True)
                    assert evidence['stages']['forcedExit']['exitCode'] == -signal.SIGKILL

                    recovered_pid = browser.start()
                    assert recovered_pid != restarted_pid
                    browser.navigate(url)
                    evidence['forcedRecovery'] = browser.evaluate('checkReload(5)')
                    evidence['forcedRecovery']['pid'] = recovered_pid
                    evidence['forcedRecovery']['integrity'] = json.loads(browser.evaluate('probeIntegrity()'))
                    assert evidence['forcedRecovery']['integrity'] == {'integrity_check': 'ok'}
                    # Rolled-back unfinished generation 6 must not survive. A fresh commit works.
                    browser.evaluate('commit({instance:"new",epoch:2})')
                    evidence['afterRecoveryCommit'] = browser.evaluate('checkReload(6)')
                    evidence['stages']['finalExit'] = browser.stop()
                    evidence['status'] = 'PASS'
                finally:
                    if browser.process is not None and browser.process.poll() is None:
                        browser.stop(force=True)
    except Exception as error:
        evidence['status'] = 'FAIL'
        evidence['failure'] = repr(error)
        raise
    finally:
        server.shutdown()
        evidence['utc'] = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
        evidence['hashes'] = {str(p.relative_to(BASE)): hashlib.sha256(p.read_bytes()).hexdigest()
                              for p in [BASE / 'web/sqlite3.wasm', BASE / 'web/drift_worker.js',
                                        BASE / 'web/main.dart', BASE / 'web/harness.js',
                                        BASE / 'tool/browser_test.py', BASE / 'pubspec.lock']}
        (BASE / 'evidence/browser-results.json').write_text(json.dumps(evidence, indent=2) + '\n')
        print(json.dumps(evidence, indent=2))


if __name__ == '__main__':
    main()
