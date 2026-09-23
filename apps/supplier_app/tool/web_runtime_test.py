"""Real production-port smoke in a dedicated disposable Chrome profile.

Requires DART (or dart on PATH), Python websocket-client, and local Chrome.
Reuses only the isolated browser transport from the historical test helper.
"""
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
spec = importlib.util.spec_from_file_location('isolated_chrome', ROOT / 'prototypes/web_storage_gate/tool/browser_test.py')
transport = importlib.util.module_from_spec(spec)
spec.loader.exec_module(transport)


def main():
    output = APP / '.dart_tool/web-runtime-smoke'
    output.mkdir(parents=True, exist_ok=True)
    dart = os.environ.get('DART') or shutil.which('dart')
    if not dart:
        raise RuntimeError('Set DART to the installed Dart executable')
    subprocess.run([dart, 'compile', 'js', '-O2', 'tool/drift_worker.dart', '-o', 'web/drift_worker.js'], cwd=APP, check=True)
    subprocess.run([dart, 'compile', 'js', 'tool/web_runtime_smoke.dart', '-o', str(output / 'main.js')], cwd=APP, check=True)
    for asset in ['supplier_platform.js', 'sqlite3.wasm', 'drift_worker.js']:
        shutil.copyfile(APP / 'web' / asset, output / asset)
    (output / 'index.html').write_text('<!doctype html><html><body><script src="supplier_platform.js"></script><script src="main.js" defer></script></body></html>')
    handler = functools.partial(transport.Handler, directory=str(output))
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    evidence = ROOT / 'artifacts/development'
    evidence.mkdir(parents=True, exist_ok=True)
    run = 'smoke-' + str(uuid.uuid4())
    url = f'http://127.0.0.1:{server.server_port}/index.html?run={run}'
    try:
        with tempfile.TemporaryDirectory(prefix='supplier-web-runtime-') as profile, (evidence / 'web-runtime-chrome.log').open('w') as log:
            browser = transport.Browser(profile, log)
            try:
                browser.start()
                browser.navigate(url)
                browser.evaluate('''window.smokeTrace=[];
                  const original=supplierPlatform;
                  window.supplierPlatform={...original};
                  for(const name of ['withLock','readMetadata','compareAndSetMetadata','privateArtifact']) {
                    window.supplierPlatform[name]=async(...args)=>{
                      smokeTrace.push([name,'start',String(args[0])]);
                      try {const result=await original[name](...args);smokeTrace.push([name,'done']);return result;}
                      catch(error){smokeTrace.push([name,'error',String(error)]);throw error;}
                    };
                  }
                  window.smokePending=true;
                  runSmoke().then(value=>{window.smokeResult=value;window.smokePending=false;}, error=>{window.smokeError=String(error);window.smokePending=false;});
                  true''', wait=False)
                deadline = time.monotonic() + 60
                last_stage = None
                while browser.evaluate('window.smokePending') and time.monotonic() < deadline:
                    current_stage = browser.evaluate('window.smokeStage')
                    if current_stage != last_stage:
                        print('Stage:', current_stage, flush=True)
                        last_stage = current_stage
                    time.sleep(.2)
                state = browser.evaluate('({pending:smokePending,result:window.smokeResult,error:window.smokeError,stage:window.smokeStage,trace:smokeTrace})')
                if state.get('pending') or state.get('error'):
                    raise RuntimeError(json.dumps(state, ensure_ascii=False))
                first = json.loads(state['result'])
                worker_samples = []
                for _ in range(5):
                    json.loads(browser.evaluate('reopenSmoke()'))
                    time.sleep(.2)
                    worker_samples.append([
                        {'type': target['type'], 'url': target['url']}
                        for target in browser.call('Target.getTargets')['targetInfos']
                        if target['type'] in ('worker', 'shared_worker')
                    ])
                print('Worker counts:', [len(sample) for sample in worker_samples], flush=True)
                # This collects the page heap only. Dedicated worker heaps are
                # separate; do not interpret this as a complete worker leak test.
                browser.call('HeapProfiler.collectGarbage')
                time.sleep(1)
                workers_after_gc = [
                    {'type': target['type'], 'url': target['url']}
                    for target in browser.call('Target.getTargets')['targetInfos']
                    if target['type'] in ('worker', 'shared_worker')
                ]
                print('Worker count after page GC:', len(workers_after_gc), flush=True)
                locks = browser.evaluate('''(async () => {
                  const name = new URLSearchParams(location.search).get('run');
                  const peer = window.open(location.href, '_blank');
                  if (!peer) throw Error('Peer tab blocked');
                  try {
                    for (let i=0; !peer.probeReady && i<200; i++) await new Promise(r=>setTimeout(r,25));
                    if (!peer.probeReady) throw Error('Peer did not load');
                    let pending, finished=false;
                    await supplierPlatform.withLock(name, async () => {
                      pending=peer.supplierPlatform.withLock(name, async()=>{finished=true;});
                      await new Promise(r=>setTimeout(r,150));
                      if (finished) throw Error('Peer bypassed application lock');
                    });
                    await pending;
                    return finished;
                  } finally { peer.close(); }
                })()''')
                assert locks is True
                browser.stop()
                browser.start()
                browser.navigate(url)
                reopened = json.loads(browser.evaluate('reopenSmoke()'))
                assert first['instance'] == reopened['instance'] and first['device'] == reopened['device']
                result = {'status': 'PASS', 'scope': 'isolated Chrome production Web ports, OPFS and IndexedDB', 'first': first, 'process_reopen': reopened, 'cross_tab_lock': locks, 'worker_samples_after_reopen': worker_samples, 'workers_after_page_gc': workers_after_gc}
                (evidence / 'web-runtime-smoke.json').write_text(json.dumps(result, ensure_ascii=False, indent=2))
                print(json.dumps(result, ensure_ascii=False, indent=2))
            finally:
                browser.stop()
    finally:
        server.shutdown()
        server.server_close()


if __name__ == '__main__':
    main()
