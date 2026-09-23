"""Production Web restore in a disposable Chrome profile; explicit crash fixtures.

This runner is independent of the shared runtime smoke and keeps its worker build
in its own output directory. Crash states are durable boundary fixtures, followed
by host or full browser restart, not instruction-level forced termination.
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
spec = importlib.util.spec_from_file_location('restore_chrome', ROOT / 'prototypes/web_storage_gate/tool/browser_test.py')
transport = importlib.util.module_from_spec(spec)
spec.loader.exec_module(transport)


def invoke(browser, operation):
    browser.evaluate(f'''window.restorePending=true;window.restoreError=null;window.restoreFailureDetail=null;
      restoreSmoke({json.dumps(operation)}).then(v=>{{window.restoreResult=v;window.restorePending=false;}},
      e=>{{window.restoreError=String(e);window.restorePending=false;}});true''', wait=False)
    deadline = time.monotonic() + 180
    previous = None
    while browser.evaluate('window.restorePending') and time.monotonic() < deadline:
        current = browser.evaluate('window.smokeStage')
        if current != previous:
            print(operation, current, flush=True)
            previous = current
        time.sleep(.2)
    state = browser.evaluate('({pending:restorePending,error:restoreError,result:window.restoreResult,stage:window.smokeStage,detail:window.restoreFailureDetail})')
    if state.get('pending') or state.get('error'):
        raise RuntimeError(json.dumps(state, ensure_ascii=False))
    return json.loads(state['result'])


def main():
    output = APP / '.dart_tool/web-restore-smoke'
    output.mkdir(parents=True, exist_ok=True)
    dart = os.environ.get('DART') or shutil.which('dart')
    if not dart:
        raise RuntimeError('Set DART')
    for source, target in [('tool/drift_worker.dart', 'drift_worker.js'), ('tool/web_restore_smoke.dart', 'main.js')]:
        subprocess.run([dart, 'compile', 'js', '-O2', source, '-o', str(output / target)], cwd=APP, check=True)
    for asset in ['supplier_platform.js', 'sqlite3.wasm']:
        shutil.copyfile(APP / 'web' / asset, output / asset)
    (output / 'index.html').write_text('<!doctype html><html><body><script src="supplier_platform.js"></script><script src="main.js" defer></script></body></html>')
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(transport.Handler, directory=str(output)))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    evidence = ROOT / 'artifacts/development'
    evidence.mkdir(parents=True, exist_ok=True)
    url = f'http://127.0.0.1:{server.server_port}/index.html?run=restore-{uuid.uuid4()}'
    try:
        with tempfile.TemporaryDirectory(prefix='supplier-web-restore-') as profile, (evidence / 'web-restore-chrome.log').open('w') as log:
            browser = transport.Browser(profile, log)
            try:
                browser.start()
                browser_version = browser.call('Browser.getVersion')
                browser.navigate(url)
                browser.evaluate(r"""(() => {
                  const platform = supplierPlatform;
                  window.quotaErrors=[];window.observeQuota=false;
                  async function observe(promise, stage) {
                    try {return await promise;} catch(error) {
                      if(window.observeQuota)window.quotaErrors.push({stage,name:error.name,message:String(error)});
                      throw error;
                    }
                  }
                  let fault='', stats={};
                  window.setRestoreFault = name => {
                    fault=name;
                    if(name) stats={injected:false,aborts:0,publishes:0};
                  };
                  window.restoreFaultStats = () => JSON.stringify(stats);
                  let inputChoice='original';
                  window.setInputChoice=name=>{inputChoice=name;};
                  const bytes=new Uint8Array(131073);bytes[131072]=42;
                  window.supplierPlatform = {...platform,
                    async compareAndSetMetadata(namespace, expected, changes) {
                      await platform.compareAndSetMetadata(namespace,expected,changes);
                      if(fault==='ack-after-accept' && JSON.parse(changes).activation?.state==='accepted') {
                        fault='';stats.injected=true;
                        throw new DOMException('Injected lost acceptance acknowledgement','AbortError');
                      }
                    },
                    async pickInput() {
                      const changed=bytes.slice();
                      if(inputChoice==='different')changed[131072]=43;
                      const file=new File([changed],inputChoice==='renamed'?'renamed.xlsx':'original.xlsx');
                      const source=await platform.sourceFromHandle({getFile:async()=>file});
                      const lost=inputChoice==='lost';
                      return {...source, async read(start,end) {
                        if(lost && start>=65536)throw new DOMException('Injected lost file access','NotReadableError');
                        return source.read(start,end);
                      }};
                    },
                    async privateArtifact(...args) {
                      if(fault==='private-create') {
                        stats.injected=true;fault='';
                        throw new DOMException('Injected private artifact quota error', 'QuotaExceededError');
                      }
                      return observe(platform.privateArtifact(...args),'private-artifact-create');
                    },
                    async durableBackupOutput(...args) {
                      const target=await observe(platform.durableBackupOutput(...args),'durable-output-create');
                      return {...target,
                        async write(bytes) {
                          if(fault==='durable-write') {
                            stats.injected=true;fault='';
                            throw new DOMException('Injected output quota error','QuotaExceededError');
                          }
                          await observe(target.write(bytes),'durable-output-write');
                        },
                        async publish() {
                          if(fault==='durable-publish') {
                            stats.injected=true;fault='';
                            throw new DOMException('Injected output close error','NotAllowedError');
                          }
                          await observe(target.publish(),'durable-output-close'); stats.publishes++; 
                        },
                        async abort() { await target.abort();stats.aborts++; },
                      };
                    },
                  };
                  const put=IDBObjectStore.prototype.put;
                  IDBObjectStore.prototype.put=function(value,key) {
                    if((fault==='idb-arm' && value?.state==='armed') ||
                       (fault==='idb-switch' && value?.state==='switched') ||
                       (fault==='idb-accept' && value?.state==='accepted')) {
                      fault='';stats.injected=true;
                      this.transaction.abort();
                      return;
                    }
                    return put.apply(this,arguments);
                  };
                  return true;
                })()""")
                capacity = invoke(browser, 'capacity')
                invoke(browser, 'quota_prepare')
                origin = f'http://127.0.0.1:{server.server_port}'
                quota_before = browser.call('Storage.getUsageAndQuota', {'origin': origin})
                # Chromium treats zero as unlimited in some OPFS quota paths.
                browser.call('Storage.overrideQuotaForOrigin', {'origin': origin, 'quotaSize': 1})
                try:
                    quota_limit = browser.call('Storage.getUsageAndQuota', {'origin': origin})
                    assert quota_limit['overrideActive'] and quota_limit['quota'] == 1
                    browser.evaluate('window.observeQuota=true;true')
                    quota_failure = invoke(browser, 'quota_activate')
                    quota_errors = browser.evaluate('window.quotaErrors')
                    print('actual quota failure', json.dumps(quota_failure), quota_errors, flush=True)
                    assert any(e['name'] == 'QuotaExceededError' for e in quota_errors), quota_errors
                finally:
                    browser.evaluate('window.observeQuota=false;true')
                    browser.call('Storage.overrideQuotaForOrigin', {'origin': origin})
                    quota_reset = browser.call('Storage.getUsageAndQuota', {'origin': origin})
                    assert not quota_reset['overrideActive']
                quota_verified = invoke(browser, 'quota_verify')
                actual_quota = {'browser': browser_version, 'before': quota_before, 'limited': quota_limit, 'reset': quota_reset,
                                'failure': quota_failure, 'errors': quota_errors, 'reopened': quota_verified}
                source_reselection = invoke(browser, 'source_reselection')
                io_faults = invoke(browser, 'io_faults')
                prepared = invoke(browser, 'normal_prepare')
                peer = browser.evaluate('''(async()=>{
                  window.restorePeer=window.open(location.href,'_blank');
                  for(let i=0;!restorePeer.probeReady&&i<200;i++) await new Promise(r=>setTimeout(r,25));
                  if(!restorePeer.probeReady)throw Error('Peer failed to load');
                  return JSON.parse(await restorePeer.restoreSmoke('hold'));
                })()''')
                assert peer['held']
                accepted = invoke(browser, 'activate:' + prepared['candidate'])
                fenced = browser.evaluate("(async()=>{const r=JSON.parse(await restorePeer.restoreSmoke('fenced'));restorePeer.close();return r;})()")
                assert fenced['fenced']
                boundaries = invoke(browser, 'boundaries')
                stale = invoke(browser, 'stale')
                invalid = invoke(browser, 'invalid')
                crash = invoke(browser, 'crash_prepare')
                browser.stop()
                browser.start()
                browser.navigate(url)
                recovered = invoke(browser, 'crash_recover')
                accepted_reopen = invoke(browser, 'reopen_accepted')
                assert accepted_reopen['device'] == prepared['device']
                assert accepted_reopen['instance'] == accepted['instance']
                assert accepted_reopen['names'] == ['after-accepted', 'snapshot']
                result = {'status': 'PASS', 'scope': 'isolated Chrome OPFS + IDB production restore; durable crash boundary fixtures',
                          'capacity': capacity, 'actual_quota': actual_quota, 'source_reselection': source_reselection, 'io_faults': io_faults, 'accepted': accepted, 'cross_tab_old_host': fenced, 'boundaries': boundaries,
                          'stale': stale, 'invalid': invalid, 'process_restart': recovered, 'accepted_after_restart': accepted_reopen,
                          'crash_candidate': crash['candidate']}
                (evidence / 'web-restore-smoke.json').write_text(json.dumps(result, ensure_ascii=False, indent=2))
                print(json.dumps(result, ensure_ascii=False, indent=2), flush=True)
            finally:
                browser.stop()
    finally:
        server.shutdown()
        server.server_close()


if __name__ == '__main__':
    main()
