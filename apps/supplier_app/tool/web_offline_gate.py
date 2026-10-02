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
import re
import shutil
import sys
from pathlib import Path
import tempfile
import threading
import time
import uuid

APP = Path(__file__).resolve().parents[1]
ROOT = APP.parents[1]
BUILD = Path(os.environ.get('OFFLINE_BUILD', APP / 'build/web'))
EVIDENCE = ROOT / 'artifacts/development'
RUN_ID = uuid.uuid4().hex


def report_output():
    name=os.environ.get('OFFLINE_REPORT',('web-offline-receipt-recovery.json' if '--receipt-recovery' in sys.argv
         else 'web-offline-upgrade.json') if '--upgrade' in sys.argv else 'web-offline-gate.json')
    return EVIDENCE/name


# Mark this invocation before loading the browser transport: missing optional
# host packages must not leave an earlier PASS visible as the latest result.
if __name__ == '__main__':
    output=report_output()
    output.parent.mkdir(parents=True,exist_ok=True)
    output.write_text(json.dumps({'status':'RUNNING','run_id':RUN_ID,'phase':'prerequisites'},indent=2))
try:
    spec = importlib.util.spec_from_file_location('offline_transport', ROOT / 'prototypes/web_storage_gate/tool/browser_test.py')
    transport = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(transport)
except BaseException as error:
    if __name__ == '__main__':
        output.write_text(json.dumps({'status':'FAIL','run_id':RUN_ID,'error':str(error)},indent=2))
    raise


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
    result = {'status':'RUNNING', 'run_id':RUN_ID, 'scope':'Current Flutter release UI, isolated Chrome; no Android/Windows; no business fixture imported',
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
    if result['status'] != 'PASS':
        raise SystemExit(1)


def release_state(browser):
    return browser.evaluate('''(async()=>{
      const registration=await navigator.serviceWorker.getRegistration();
      const channel=new MessageChannel();
      const release=await new Promise((resolve,reject)=>{
        const timer=setTimeout(()=>reject(Error('handshake timeout')),5000);
        channel.port1.onmessage=e=>{clearTimeout(timer);channel.port1.close();resolve(e.data.release)};
        navigator.serviceWorker.controller.postMessage({type:'supplier-release'},[channel.port2]);
      });
      const hashes={};
      for(const path of ['index.html','flutter_bootstrap.js','main.dart.js','supplier_platform.js','drift_worker.js','sqlite3.wasm','canvaskit/chromium/canvaskit.wasm']) {
        const bytes=await (await fetch(path)).arrayBuffer();
        hashes[path]=[...new Uint8Array(await crypto.subtle.digest('SHA-256',bytes))].map(x=>x.toString(16).padStart(2,'0')).join('');
      }
      return {release,workerHash:hashes['drift_worker.js'],hashes,waiting:registration.waiting?.state || null,caches:await caches.keys()};
    })()''')


def backup_state(browser):
    return browser.evaluate('''(async()=>{
      const root=await navigator.storage.getDirectory(),result={};
      for await(const [name,directory] of root.entries()) {
        if(directory.kind!=='directory'||!name.endsWith('-backups'))continue;
        for await(const [fileName,handle] of directory.entries()) {
          if(handle.kind!=='file')continue;
          const file=await handle.getFile();
          result[name+'/'+fileName]={bytes:file.size,sha256:[...new Uint8Array(await crypto.subtle.digest('SHA-256',await file.arrayBuffer()))].map(x=>x.toString(16).padStart(2,'0')).join('')};
        }
      }
      return result;
    })()''')


def seed_business(browser):
    import web_exchange_ui_injected_test as ui
    fixture=base64.b64encode(ui.workbook()).decode()
    browser.evaluate('''window.showOpenFilePicker=async()=>[{getFile:async()=>new File([Uint8Array.from(atob(%s),c=>c.charCodeAt(0))],'a14-business.xlsx')}];true''' % json.dumps(fixture))
    first='导入导出/备份' if '导入导出/备份' in ui.ui.text(browser) else '文件与备份'
    for label in [first,'导入业务 Excel','选择 Excel 文件']:
        ui.click(browser,label)
    ui.wait_text(browser,'a14-business.xlsx')
    ui.click(browser,'解析选中工作表');ui.wait_text(browser,'选择列映射')
    ui.click(browser,'确认映射并查看转换预览');ui.wait_text(browser,'逐行核对')
    for label in ['核对并选择操作','明确新建供应商','明确新建产品']:
        ui.click(browser,label)
    if '已核对并接受上述格式转换' in ui.ui.text(browser):ui.click(browser,'已核对并接受上述格式转换')
    ui.click(browser,'确认本行决定');time.sleep(1.5)
    ui.click(browser,'查看最终汇总');time.sleep(1)
    if '逐行核对' in ui.ui.text(browser):ui.click(browser,'查看最终汇总')
    ui.wait_text(browser,'确认产生 1 条报价结果')
    ui.click(browser,'确认汇总并提交导入')
    receipt=ui.wait_text(browser,'成功回执：')
    backups=backup_state(browser)
    record={'receipt':re.search(r'成功回执：([^\s]+)',receipt).group(1),'text':receipt,'backups':backups}
    if '--receipt-recovery' in sys.argv:
        ui.click(browser,'Back');ui.click(browser,'查看文件任务记录')
        # Flutter renders SelectableText in a canvas-backed textarea. Its
        # completed-state label is exposed to accessibility, but the content
        # only enters textarea.value after an actual pointer selection.
        deadline=time.monotonic()+60
        history=''
        while time.monotonic()<deadline:
            rect=browser.evaluate('''(() => {const n=document.querySelector('textarea[aria-label="已完成"]');if(!n)return null;const r=n.getBoundingClientRect();return {x:r.x+r.width/2,y:r.y+r.height/2}})()''')
            if rect:
                for kind in ['mousePressed','mouseReleased']:
                    browser.call('Input.dispatchMouseEvent',{'type':kind,**rect,'button':'left','clickCount':1})
                history=browser.evaluate('document.querySelector(\'textarea[aria-label="已完成"]\')?.value || ""')
                if '任务 ' in history: break
            time.sleep(.2)
        job_match=re.search(r'任务 ([^\s]+)',history)
        if not job_match:
            raise RuntimeError('Missing job number in persisted history: '+history)
        record.update(job_id=job_match.group(1),history=history)
    return record


def resume_receipt(browser,job):
    import web_exchange_ui_injected_test as ui
    first='导入导出/备份' if '导入导出/备份' in ui.ui.text(browser) else '文件与备份'
    ui.click(browser,first);ui.click(browser,'导入业务 Excel')
    rect=browser.evaluate('''(() => {const n=document.querySelector('input[aria-label="恢复任务编号"]');if(!n)return null;const r=n.getBoundingClientRect();return {x:r.x+r.width/2,y:r.y+r.height/2}})()''')
    if not rect: raise RuntimeError('Missing restore task number input')
    for kind in ['mousePressed','mouseReleased']:
        browser.call('Input.dispatchMouseEvent',{'type':kind,**rect,'button':'left','clickCount':1})
    # A focused DOM input can accept bytes before Flutter attaches its input
    # listener. Wait for the engine listener, then type into the controller.
    field=browser.call('Runtime.evaluate',{'expression':'document.querySelector(\'input[aria-label="恢复任务编号"]\')','returnByValue':False})['result']['objectId']
    deadline=time.monotonic()+10
    while time.monotonic()<deadline:
        listeners=browser.call('DOMDebugger.getEventListeners',{'objectId':field})['listeners']
        if any(item['type']=='input' for item in listeners): break
        time.sleep(.05)
    else: raise RuntimeError('Flutter restore task input did not become ready')
    browser.call('Input.insertText',{'text':job['job_id']})
    if browser.evaluate('document.querySelector(\'input[aria-label="恢复任务编号"]\')?.value')!=job['job_id']:
        raise RuntimeError('Restore task number was not entered')
    ui.click(browser,'恢复导入任务')
    return ui.wait_text(browser,'恢复原回执：'+job['receipt'])


def upgrade_main():
    import build_web_offline
    result={'status':'RUNNING','run_id':RUN_ID,'scope':'same-origin old/new tabs and rejected then valid update; compatible worker change'}
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
                browser.call('Emulation.setDeviceMetricsOverride',{'width':1440,'height':1100,'deviceScaleFactor':1,'mobile':False})
                result['initial_ui']=observe(browser)
                assert '查询与比价' in result['initial_ui']['text']
                result['business_import']=seed_business(browser)
                assert result['business_import']['backups'], 'No pre-import backup'
                browser.call('Page.navigate',{'url':url});time.sleep(2)
                import web_exchange_ui_injected_test as ui
                observe(browser)
                result['business_before_upgrade']=ui.wait_text(browser,'界面验收产品')
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
                result['second_tab_business']=ui.wait_text(browser,'界面验收产品')
                result['second_tab']=release_state(browser)
                assert result['second_tab']['release']==result['old_release']
                assert result['second_tab']['workerHash']==result['initial']['workerHash']
                assert result['second_tab']['hashes']==result['initial']['hashes']
                browser.call('Target.closeTarget',{'targetId':target})
                browser.ws.close(); browser.ws=old_ws
                result['close']=browser.stop()
                browser.start(); browser.call('Page.navigate',{'url':url}); time.sleep(2)
                result['after_all_clients_closed_ui']=observe(browser)
                result['business_after_upgrade']=ui.wait_text(browser,'界面验收产品')
                result['after_all_clients_closed']=release_state(browser)
                assert result['after_all_clients_closed']['release']==result['new_release']
                assert result['after_all_clients_closed']['workerHash']==hashlib.sha256((new/'drift_worker.js').read_bytes()).hexdigest()
                expected=json.loads((new/'supplier_offline_manifest.json').read_text())['assets']
                assert all(expected[path]==digest for path,digest in result['after_all_clients_closed']['hashes'].items())
                cached=result['after_all_clients_closed']['caches']
                assert 'supplier-offline-other-deployment-sentinel' in cached
                assert len(cached)==2 and any(c.endswith(result['new_release']) for c in cached)
                result['preserved_opfs_marker']=browser.evaluate("(async()=>{const root=await navigator.storage.getDirectory();return await (await (await root.getFileHandle('a14-upgrade-preservation')).getFile()).text()})()")
                assert result['preserved_opfs_marker']=='A14 persistent marker'
                result['backups_after_upgrade']=backup_state(browser)
                assert result['backups_after_upgrade']==result['business_import']['backups']
                if '--receipt-recovery' in sys.argv:
                    result['receipt_after_upgrade']=resume_receipt(browser,result['business_import'])
                browser.call('Network.enable');browser.call('Network.clearBrowserCache')
                browser.call('Network.emulateNetworkConditions',{'offline':True,'latency':0,'downloadThroughput':0,'uploadThroughput':0})
                browser.call('Page.navigate',{'url':url});time.sleep(2);observe(browser)
                result['business_offline']=ui.wait_text(browser,'界面验收产品')
                screenshot=browser.call('Page.captureScreenshot',{'format':'png'})
                (EVIDENCE/'web-offline-business-chinese.png').write_bytes(base64.b64decode(screenshot['data']))
                result['backups_offline']=backup_state(browser)
                assert result['backups_offline']==result['business_import']['backups']
                if '--receipt-recovery' in sys.argv:
                    result['receipt_offline']=resume_receipt(browser,result['business_import'])
                else:
                    result['receipt_recovery']='NOT_VERIFIED: see web-offline-receipt-gap.json; record and backup persistence are asserted separately'
                result['status']='PASS'
            except Exception as error:
                result['status']='FAIL'; result['error']=str(error)
            finally:
                browser.stop(); server.shutdown(); server.server_close()
                report_name=os.environ.get('OFFLINE_REPORT','web-offline-receipt-recovery.json' if '--receipt-recovery' in sys.argv else 'web-offline-upgrade.json')
                (EVIDENCE/report_name).write_text(json.dumps(result,ensure_ascii=False,indent=2))
                print('upgrade',result['status'],result.get('error',''),flush=True)
    if result['status'] != 'PASS':
        raise SystemExit(1)


if __name__ == '__main__':
    output=report_output()
    try:
        upgrade_main() if '--upgrade' in sys.argv else main()
    except BaseException as error:
        current=json.loads(output.read_text())
        if current.get('run_id')==RUN_ID and current.get('status')=='RUNNING':
            output.write_text(json.dumps({'status':'FAIL','run_id':RUN_ID,'error':str(error)},indent=2))
        raise
