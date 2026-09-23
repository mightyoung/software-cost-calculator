"""Real isolated Chrome + OPFS exchange adapters; system chooser is bypassed."""
import functools
import http.server
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import time
import uuid

APP = Path(__file__).resolve().parents[1]
ROOT = APP.parents[1]
spec = importlib.util.spec_from_file_location('exchange_chrome', ROOT / 'prototypes/web_storage_gate/tool/browser_test.py')
transport = importlib.util.module_from_spec(spec)
spec.loader.exec_module(transport)


def invoke(browser, operation):
    browser.evaluate(f'window.pending=true;window.failure=null;exchangeSmoke({json.dumps(operation)}).then(v=>{{window.result=v;window.pending=false}},e=>{{window.failure=String(e.error)+" "+String(e.stack);window.pending=false}});true', wait=False)
    deadline = time.monotonic() + 180
    previous = None
    while browser.evaluate('window.pending') and time.monotonic() < deadline:
        current = browser.evaluate('window.exchangeStage')
        if current != previous:
            print(operation, current, flush=True)
            previous = current
        time.sleep(.2)
    state = browser.evaluate('({pending:window.pending,failure:window.failure,result:window.result})')
    if state['pending'] or state['failure']:
        raise RuntimeError(state)
    result = json.loads(state['result'])
    if 'failure' in result:
        raise RuntimeError(result)
    return result


def _run(evidence, run_id):
    output = APP / '.dart_tool/web-exchange-smoke'
    output.mkdir(parents=True, exist_ok=True)
    dart = os.environ.get('DART') or shutil.which('dart')
    for source, name in [('tool/drift_worker.dart', 'drift_worker.js'), ('tool/web_exchange_smoke.dart', 'main.js')]:
        subprocess.run([dart, 'compile', 'js', '-O2', source, '-o', str(output / name)], cwd=APP, check=True)
    for name in ['supplier_platform.js', 'sqlite3.wasm']:
        shutil.copyfile(APP / 'web' / name, output / name)
    (output / 'index.html').write_text('<!doctype html><script src="supplier_platform.js"></script><script src="main.js" defer></script>')
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(transport.Handler, directory=str(output)))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    url = f'http://127.0.0.1:{server.server_port}/?run=exchange-{uuid.uuid4()}'
    try:
        with tempfile.TemporaryDirectory(prefix='supplier-exchange-chrome-') as profile, (evidence / 'web-exchange-chrome.log').open('w') as log:
            browser = transport.Browser(profile, log)
            try:
                browser.start()
                version = browser.call('Browser.getVersion')
                browser.navigate(url)
                prepared = invoke(browser, 'prepare')
                stopped = browser.stop()
                browser.start()
                browser.navigate(url)
                reopened = invoke(browser, 'reopen')
                result = {'status': 'PASS', 'run_id': run_id, 'browser': version, 'prepare': prepared, 'browser_process_restart': stopped, 'reopen': reopened, 'limitations': ['System file chooser and Flutter widget click path not exercised; production adapters receive real OPFS-backed XLSX/ZIP files.']}
                (evidence / 'web-exchange-smoke.json').write_text(json.dumps(result, ensure_ascii=False, indent=2))
                print(json.dumps(result, ensure_ascii=False, indent=2), flush=True)
            finally:
                browser.stop()
    finally:
        server.shutdown()
        server.server_close()


def main():
    evidence = Path(os.environ.get('SUPPLIER_EXCHANGE_EVIDENCE_DIR', ROOT / 'artifacts/development'))
    evidence.mkdir(parents=True, exist_ok=True)
    report = evidence / 'web-exchange-smoke.json'
    run_id = str(uuid.uuid4())
    report.write_text(json.dumps({'status': 'RUNNING', 'run_id': run_id}, indent=2))
    try:
        _run(evidence, run_id)
    except BaseException as error:
        report.write_text(json.dumps({'status': 'FAIL', 'run_id': run_id, 'error': repr(error)}, indent=2))
        raise


if __name__ == '__main__':
    main()
