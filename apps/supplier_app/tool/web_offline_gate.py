"""A14 bounded release-build observations; no build or product changes.

Uses disposable Chrome profiles and the existing isolated CDP transport.
The worker mutation is deliberately protocol-compatible: it tests byte pinning,
not compatibility with a particular historical Drift version.
"""
import functools
import base64
import hashlib
import http.server
import importlib.util
import json
import os
import shutil
import sys
from pathlib import Path
import tempfile
import threading
import time

APP = Path(__file__).resolve().parents[1]
ROOT = APP.parents[1]
BUILD = APP / 'build/web'
EVIDENCE = ROOT / 'artifacts/development'
spec = importlib.util.spec_from_file_location('offline_transport', ROOT / 'prototypes/web_storage_gate/tool/browser_test.py')
transport = importlib.util.module_from_spec(spec)
spec.loader.exec_module(transport)


class Handler(transport.Handler):
    mutation = None
    observations = []

    def do_GET(self):
        asset = self.path.split('?')[0].lstrip('/')
        self.observations.append(asset)
        payload = None
        if asset == 'drift_worker.js' and self.mutation == 'worker-bytes':
            payload = (BUILD / asset).read_bytes() + b'\n/* A14 compatible different worker bytes */\n'
        elif asset == 'sqlite3.wasm' and self.mutation == 'invalid-wasm':
            payload = b'A14 intentionally invalid WASM resource'
        if payload is None:
            return super().do_GET()
        self.send_response(200)
        self.send_header('Content-Type', 'application/wasm' if asset.endswith('.wasm') else 'application/javascript')
        self.send_header('Content-Length', str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


def observe(browser, seconds=30):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        browser.evaluate("document.querySelector('flt-semantics-placeholder')?.click()")
        body = browser.evaluate('document.body?.innerText || ""')
        if any(label in body for label in ['供应商', '无法', '失败', '未能', '应用资源未准备完成']):
            break
        time.sleep(.25)
    return browser.evaluate('''(async()=>({
      url:location.href, text:document.body?.innerText || '',
      controller:navigator.serviceWorker?.controller?.scriptURL || null,
      registrations:navigator.serviceWorker ? await navigator.serviceWorker.getRegistrations().then(x=>x.map(r=>({scope:r.scope,active:r.active?.scriptURL}))) : [],
      caches:typeof caches==='undefined' ? [] : await caches.keys(),
      resources:performance.getEntriesByType('resource').map(r=>({name:r.name,transferSize:r.transferSize}))
    }))()''')


def main():
    EVIDENCE.mkdir(parents=True, exist_ok=True)
    result = {'status':'RUNNING', 'scope':'Current Flutter release UI, isolated Chrome; no Android/Windows; no business fixture imported',
              'hashes':{name:hashlib.sha256((BUILD/name).read_bytes()).hexdigest() for name in ['index.html','main.dart.js','flutter_bootstrap.js','flutter_service_worker.js','drift_worker.js','sqlite3.wasm']},
              'cases':{}}
    server = http.server.ThreadingHTTPServer(('127.0.0.1',0),functools.partial(Handler,directory=str(BUILD)))
    threading.Thread(target=server.serve_forever,daemon=True).start()
    url = f'http://127.0.0.1:{server.server_port}/'
    try:
        for case in ['offline-restart','worker-bytes','invalid-wasm']:
            Handler.mutation = None if case == 'offline-restart' else case
            Handler.observations = []
            record = {}
            result['cases'][case] = record
            with tempfile.TemporaryDirectory(prefix='supplier-web-offline-') as profile, (EVIDENCE/f'web-offline-{case}-chrome.log').open('w') as log:
                browser = transport.Browser(profile,log)
                try:
                    record['pid']=browser.start()
                    record['browser']=browser.call('Browser.getVersion')
                    browser.call('Network.enable')
                    browser.call('Page.navigate',{'url':url})
                    time.sleep(2)
                    record['online']=observe(browser)
                    # Allow registration/cleanup to settle before evaluating cache state.
                    time.sleep(3)
                    record['settled']=observe(browser,seconds=1)
                    if case == 'offline-restart':
                        record['close']=browser.stop()
                        record['restart_pid']=browser.start()
                        browser.call('Network.enable')
                        browser.call('Network.emulateNetworkConditions',{'offline':True,'latency':0,'downloadThroughput':0,'uploadThroughput':0})
                        record['navigation']=browser.call('Page.navigate',{'url':url})
                        time.sleep(2)
                        record['offline']=observe(browser,seconds=8)
                        record['status']='PASS' if '供应商' in record['offline']['text'] and record['offline']['url']==url else 'FAIL'
                        # HTTP cache is disposable. A managed offline application
                        # cache must survive clearing only the HTTP cache.
                        browser.call('Network.clearBrowserCache')
                        browser.call('Page.navigate',{'url':url})
                        time.sleep(2)
                        record['offline_without_http_cache']=observe(browser,seconds=8)
                        time.sleep(2)
                        screenshot=browser.call('Page.captureScreenshot',{'format':'png'})
                        (EVIDENCE/'web-offline-chinese.png').write_bytes(base64.b64decode(screenshot['data']))
                        record['managed_cache_status']='PASS' if '供应商' in record['offline_without_http_cache']['text'] and record['offline_without_http_cache']['url']==url else 'FAIL'
                        if record['managed_cache_status']=='FAIL':
                            record['status']='FAIL'
                    elif case == 'worker-bytes':
                        record['modified_sha256']=hashlib.sha256((BUILD/'drift_worker.js').read_bytes()+b'\n/* A14 compatible different worker bytes */\n').hexdigest()
                        record['status']='OBSERVED'
                        record['limitation']='Compatible worker-byte mutation only; no claim that incompatible Drift versions were accepted.'
                    else:
                        record['status']='OBSERVED'
                    if case != 'offline-restart' and (BUILD/'supplier_offline_manifest.json').exists():
                        record['status']='PASS' if '应用资源未准备完成' in record['settled']['text'] else 'FAIL'
                        record['assertion']='Modified asset is rejected before Dart/database initialization'
                    record['server_requests']=Handler.observations[:]
                except Exception as error:
                    record['status']='BLOCKED'
                    record['error']=str(error)
                finally:
                    browser.stop()
            print(case,record['status'],flush=True)
        statuses=[c['status'] for c in result['cases'].values()]
        result['status']='PASS' if all(s=='PASS' for s in statuses) else 'FAIL' if 'FAIL' in statuses else 'PARTIAL'
    finally:
        server.shutdown()
        server.server_close()
        output = EVIDENCE/os.environ.get('OFFLINE_REPORT','web-offline-gate.json')
        output.write_text(json.dumps(result,ensure_ascii=False,indent=2))
        print(str(output),flush=True)


def release_state(browser):
    return browser.evaluate('''(async()=>{
      const registration=await navigator.serviceWorker.getRegistration();
      const channel=new MessageChannel();
      const release=await new Promise((resolve,reject)=>{
        const timer=setTimeout(()=>reject(Error('handshake timeout')),5000);
        channel.port1.onmessage=e=>{clearTimeout(timer);channel.port1.close();resolve(e.data.release)};
        navigator.serviceWorker.controller.postMessage({type:'supplier-release'},[channel.port2]);
      });
      const bytes=await (await fetch('drift_worker.js')).arrayBuffer();
      const hash=[...new Uint8Array(await crypto.subtle.digest('SHA-256',bytes))].map(x=>x.toString(16).padStart(2,'0')).join('');
      return {release,workerHash:hash,waiting:registration.waiting?.state || null,caches:await caches.keys()};
    })()''')


def upgrade_main():
    import build_web_offline
    result={'status':'RUNNING','scope':'same-origin old/new tabs and rejected then valid update; compatible worker change'}
    with tempfile.TemporaryDirectory(prefix='supplier-web-upgrade-') as work:
        directory=Path(work)
        old=directory/'old'; new=directory/'new'
        shutil.copytree(BUILD,old); shutil.copytree(BUILD,new)
        with (new/'drift_worker.js').open('a') as f:
            f.write('\n/* A14 next release compatible worker */\n')
        result['old_release']=json.loads((old/'supplier_offline_manifest.json').read_text())['release']
        result['new_release']=build_web_offline.package(new)
        served={'directory':old,'corrupt':False,'offline':False}

        class UpgradeHandler(transport.Handler):
            def translate_path(self,path):
                self.directory=str(served['directory'])
                return super().translate_path(path)

            def do_GET(self):
                if served['offline']:
                    self.connection.close()
                    return
                if served['corrupt'] and self.path.split('?')[0]=='/drift_worker.js':
                    payload=b'/* unexpected worker version */'
                    self.send_response(200); self.send_header('Content-Length',str(len(payload))); self.end_headers(); self.wfile.write(payload)
                else:
                    super().do_GET()

        server=http.server.ThreadingHTTPServer(('127.0.0.1',0),UpgradeHandler)
        threading.Thread(target=server.serve_forever,daemon=True).start()
        url=f'http://127.0.0.1:{server.server_port}/'
        with (EVIDENCE/'web-offline-upgrade-chrome.log').open('w') as log:
            browser=transport.Browser(str(directory/'profile'),log)
            try:
                browser.start(); browser.call('Page.navigate',{'url':url}); time.sleep(2)
                result['initial_ui']=observe(browser)
                result['initial']=release_state(browser)
                browser.call('Network.enable')
                browser.evaluate("(async()=>{for(const name of await caches.keys())if(name.startsWith('supplier-offline-'))await (await caches.open(name)).delete(new URL('drift_worker.js',location.href));return true})()")
                served['offline']=True
                browser.call('Network.emulateNetworkConditions',{'offline':True,'latency':0,'downloadThroughput':0,'uploadThroughput':0})
                result['evicted_offline_status']=browser.evaluate("fetch('drift_worker.js').then(r=>r.status)")
                assert result['evicted_offline_status']==503
                served.update(offline=False,corrupt=True)
                browser.call('Network.emulateNetworkConditions',{'offline':False,'latency':0,'downloadThroughput':-1,'uploadThroughput':-1})
                result['evicted_wrong_version_status']=browser.evaluate("fetch('drift_worker.js').then(r=>r.status)")
                assert result['evicted_wrong_version_status']==503
                served['corrupt']=False
                result['evicted_online_repair']=release_state(browser)
                assert result['evicted_online_repair']['workerHash']==result['initial']['workerHash']
                browser.evaluate('''(async()=>{
                  const root=await navigator.storage.getDirectory();
                  const file=await root.getFileHandle('a14-upgrade-preservation',{create:true});
                  const stream=await file.createWritable();await stream.write('A14 persistent marker');await stream.close();
                  const other=await caches.open('supplier-offline-other-deployment-sentinel');
                  await other.put('/other-deployment/marker',new Response('keep unrelated cache'));
                  return true;
                })()''')
                served.update(directory=new,corrupt=True)
                result['rejected_update']=browser.evaluate('''(async()=>{
                  const r=await navigator.serviceWorker.getRegistration();await r.update();
                  const w=r.installing;
                  if(w) await new Promise(resolve=>{w.addEventListener('statechange',()=>{if(['installed','redundant'].includes(w.state))resolve()});if(['installed','redundant'].includes(w.state))resolve()});
                  return {state:w?.state,waiting:r.waiting?.state || null};
                })()''')
                result['after_rejected']=release_state(browser)
                assert result['rejected_update']['state']=='redundant',result['rejected_update']
                assert result['after_rejected']['release']==result['old_release']
                served['corrupt']=False
                browser.evaluate('''(async()=>{
                  const r=await navigator.serviceWorker.getRegistration();await r.update();
                  for(let i=0;!r.waiting && i<300;i++) await new Promise(resolve=>setTimeout(resolve,100));
                  if(!r.waiting)throw Error('No waiting verified update');return true;
                })()''')
                result['old_tab_with_waiting_update']=release_state(browser)
                assert result['old_tab_with_waiting_update']['release']==result['old_release']
                old_ws=browser.ws
                target=browser.call('Target.createTarget',{'url':url})['targetId']
                for _ in range(100):
                    tab=next((t for t in browser.targets() if t['id']==target),None)
                    if tab: break
                    time.sleep(.1)
                browser.ws=transport.websocket.create_connection(tab['webSocketDebuggerUrl'],origin='http://localhost',timeout=60)
                time.sleep(2)
                result['second_tab_ui']=observe(browser)
                result['second_tab']=release_state(browser)
                assert result['second_tab']['release']==result['old_release']
                assert result['second_tab']['workerHash']==result['initial']['workerHash']
                browser.call('Target.closeTarget',{'targetId':target})
                browser.ws.close(); browser.ws=old_ws
                result['close']=browser.stop()
                browser.start(); browser.call('Page.navigate',{'url':url}); time.sleep(2)
                result['after_all_clients_closed_ui']=observe(browser)
                result['after_all_clients_closed']=release_state(browser)
                assert result['after_all_clients_closed']['release']==result['new_release']
                assert result['after_all_clients_closed']['workerHash']==hashlib.sha256((new/'drift_worker.js').read_bytes()).hexdigest()
                cached=result['after_all_clients_closed']['caches']
                assert 'supplier-offline-other-deployment-sentinel' in cached
                assert len(cached)==2 and any(c.endswith(result['new_release']) for c in cached)
                result['preserved_opfs_marker']=browser.evaluate("(async()=>{const root=await navigator.storage.getDirectory();return await (await (await root.getFileHandle('a14-upgrade-preservation')).getFile()).text()})()")
                assert result['preserved_opfs_marker']=='A14 persistent marker'
                result['status']='PASS'
            except Exception as error:
                result['status']='FAIL'; result['error']=str(error)
            finally:
                browser.stop(); server.shutdown(); server.server_close()
                (EVIDENCE/'web-offline-upgrade.json').write_text(json.dumps(result,ensure_ascii=False,indent=2))
                print('upgrade',result['status'],result.get('error',''),flush=True)


if __name__ == '__main__':
    upgrade_main() if '--upgrade' in sys.argv else main()
