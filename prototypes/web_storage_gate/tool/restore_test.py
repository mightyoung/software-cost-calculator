"""NONPRODUCT real candidate/pointer crash matrix. One isolated profile per scenario."""
import functools
import hashlib
import http.server
import json
import signal
import tempfile
import threading
import time
from browser_test import BASE, Browser, Handler


def main():
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(Handler, directory=str(BASE/'web')))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    results = dict(status='RUNNING', scenarios=[])
    try:
        for point in ['wrong-range-candidate', 'before-pointer', 'inside-pointer', 'after-pointer', 'success-new-write', 'rollback-success', 'rollback-inside-pointer', 'rollback-after-pointer']:
            scenario = dict(point=point)
            results['scenarios'].append(scenario)
            with tempfile.TemporaryDirectory(prefix='nonproduct-t1-restore-') as profile:
                with open(BASE/f'evidence/restore-{point}.chrome.log', 'w') as log:
                    browser = Browser(profile, log)
                    try:
                        browser.start()
                        run = str(time.time_ns())
                        url = f'http://127.0.0.1:{server.server_port}/restore.html?run={run}'
                        browser.navigate(url)
                        scenario['prepared'] = browser.evaluate('restoreInit()')
                        if point == 'wrong-range-candidate':
                            scenario['negative']=browser.evaluate('restoreWrongRangeTests()')
                            scenario['status']='PASS'
                            browser.stop()
                            continue
                        if point == 'rollback-success':
                            scenario['rollback']=browser.evaluate('restoreFailureRollbackTests()')
                            pages=[t for t in browser.targets() if t['type']=='page' and run in t['url']]
                            assert len(pages)==3
                            scenario['pageTargets']=[t['id'] for t in pages]
                            scenario['exit']=browser.stop(force=True)
                        elif point == 'success-new-write':
                            scenario['success'] = browser.evaluate('restoreSuccessTests()')
                            pages = [t for t in browser.targets() if t['type']=='page' and run in t['url']]
                            assert len(pages)==2
                            scenario['pageTargets'] = [t['id'] for t in pages]
                            scenario['exit'] = browser.stop(force=True)
                        else:
                            function='restoreFailureRollbackTests' if point.startswith('rollback-') else 'activateRestore'
                            browser.evaluate(function+'('+json.dumps(point)+').catch(e=>{window.restoreError=String(e)});void 0', wait=False)
                            for _ in range(300):
                                barrier=browser.evaluate('window.restoreBarrier')
                                if barrier==point and ('inside-pointer' not in point or browser.evaluate('window.pointerTxnTicks')>10):
                                    break
                                error=browser.evaluate('window.restoreError')
                                if error: raise RuntimeError(error)
                                time.sleep(.05)
                            else: raise RuntimeError('Restore barrier timeout: '+point)
                            scenario['barrier'] = barrier
                            if 'inside-pointer' in point: scenario['idbPendingRequestCount']=browser.evaluate('window.pointerTxnTicks')
                            if point.startswith('rollback-'):
                                scenario['failureBeforeRollback']=browser.evaluate('window.rollbackFailureEvidence')
                            scenario['exit'] = browser.stop(force=True)
                        assert scenario['exit']['exitCode']==-signal.SIGKILL
                        scenario['restartedPid']=browser.start()
                        assert scenario['restartedPid']!=scenario['exit']['pid']
                        browser.navigate(url)
                        if point.startswith('rollback-'):
                            scenario['reopened']=browser.evaluate('checkRollbackRecovery()')
                            expected='candidate' if point=='rollback-inside-pointer' else 'old'
                            assert scenario['reopened']['pointer']['instance']==expected
                            if expected=='candidate':
                                scenario['resumedRollback']=browser.evaluate('attemptAutomaticRollback()')
                                scenario['afterResume']=browser.evaluate('checkRollbackRecovery()')
                                assert scenario['afterResume']['pointer']=={'instance':'old','epoch':3}
                            scenario['status']='PASS'
                            browser.stop()
                            continue
                        scenario['reopened']=browser.evaluate('checkRestored()')
                        expected='old' if point in ['before-pointer','inside-pointer'] else 'candidate'
                        expected_gen=1 if expected=='old' else 43 if point=='success-new-write' else 42
                        assert scenario['reopened']['pointer']['instance']==expected
                        assert scenario['reopened']['facts']['generation']==expected_gen
                        if point=='success-new-write':
                            denied=browser.evaluate('attemptAutomaticRollback().then(()=>false,e=>String(e).includes("NEW_WRITES_PREVENT_ROLLBACK"))')
                            assert denied
                            scenario['rollbackStillDeniedAfterRestart']=denied
                            scenario['retained']=browser.evaluate('checkRestored()')
                        scenario['status']='PASS'
                        browser.stop()
                    finally:
                        if browser.process is not None and browser.process.poll() is None: browser.stop(force=True)
        results['status']='PASS'
    except Exception as error:
        results['status']='FAIL';results['failure']=repr(error)
        raise
    finally:
        server.shutdown()
        results['utc']=time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime())
        paths=['web/restore.dart.js','web/main.dart.js','web/restore.dart','web/restore_harness.js','web/restore.html','web/main.dart','web/harness.js',
               'tool/restore_test.py','tool/browser_test.py','web/sqlite3.wasm','web/drift_worker.js','pubspec.lock']
        results['build'] = json.loads((BASE/'evidence/build-manifest.json').read_text())
        for asset, digest in results['build']['assets'].items():
            assert hashlib.sha256((BASE/asset).read_bytes()).hexdigest()==digest, asset
        results['executedEntryPoint']='web/restore.dart.js'
        results['hashes']={p:hashlib.sha256((BASE/p).read_bytes()).hexdigest() for p in paths}
        (BASE/'evidence/restore-results.json').write_text(json.dumps(results,indent=2)+'\n')
        print(json.dumps(results,indent=2))


if __name__=='__main__': main()
