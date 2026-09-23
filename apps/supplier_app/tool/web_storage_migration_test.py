"""Physical v2->v3 Web integration in disposable Chrome; no user profile."""
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
APP=Path(__file__).resolve().parents[1]
ROOT=APP.parents[1]
spec=importlib.util.spec_from_file_location('chrome',ROOT/'prototypes/web_storage_gate/tool/browser_test.py')
transport=importlib.util.module_from_spec(spec)
spec.loader.exec_module(transport)

def invoke(browser, operation):
    browser.evaluate(f"window.migrationDone=false;window.migrationError=null;migrationSmoke({json.dumps(operation)}).then(v=>{{window.migrationResult=v;window.migrationDone=true;}},e=>{{window.migrationError=String(e);window.migrationDone=true;}});true",wait=False)
    deadline=time.monotonic()+180
    while not browser.evaluate('window.migrationDone') and time.monotonic()<deadline: time.sleep(.2)
    state=browser.evaluate('({done:migrationDone,error:migrationError,result:window.migrationResult,detail:window.migrationErrorDetail,stage:window.migrationStage})')
    if not state.get('done') or state.get('error'): raise RuntimeError(state)
    return json.loads(state['result'])

def main():
    output=APP/'.dart_tool/web-storage-migration'
    output.mkdir(parents=True,exist_ok=True)
    dart=os.environ.get('DART') or shutil.which('dart')
    for source,target in [('tool/drift_worker.dart','drift_worker.js'),('tool/web_storage_migration_smoke.dart','main.js')]:
        subprocess.run([dart,'compile','js','-O2',source,'-o',str(output/target)],cwd=APP,check=True)
    for asset in ['supplier_platform.js','sqlite3.wasm']:shutil.copyfile(APP/'web'/asset,output/asset)
    (output/'index.html').write_text('<!doctype html><script src="supplier_platform.js"></script><script src="main.js" defer></script>')
    server=http.server.ThreadingHTTPServer(('127.0.0.1',0),functools.partial(transport.Handler,directory=str(output)))
    threading.Thread(target=server.serve_forever,daemon=True).start()
    evidence=ROOT/'artifacts/development/platform'
    evidence.mkdir(parents=True,exist_ok=True)
    url=f'http://127.0.0.1:{server.server_port}/?run=migrate-{uuid.uuid4()}'
    try:
      with tempfile.TemporaryDirectory(prefix='supplier-migration-') as profile,(evidence/'web-migration-chrome.log').open('w') as log:
        browser=transport.Browser(profile,log)
        try:
          browser.start();browser.navigate(url)
          browser.evaluate('''(()=>{const original=supplierPlatform;let fault='',counts={};window.setMigrationFault=n=>{fault=n;if(n)counts={injected:false,aborts:0};};window.migrationStats=()=>JSON.stringify(counts);window.supplierPlatform={...original,
            async privateArtifact(...args){if(fault==='private-create'){fault='';counts.injected=true;throw Error('injected private create');}return original.privateArtifact(...args);},
            async compareAndSetMetadata(ns,expected,changes){if(fault==='metadata'&&Object.keys(JSON.parse(changes)).some(k=>k.startsWith('storage-migration:'))){fault='';counts.injected=true;throw Error('injected journal failure');}return original.compareAndSetMetadata(ns,expected,changes);},
            async durableBackupSource(...args){const source=await original.durableBackupSource(...args);if(fault!=='corrupt-read')return source;fault='';counts.injected=true;return {...source,async read(start,end){const bytes=await source.read(start,end);if(start===0)bytes[0]=0;return bytes;}};},
            async durableBackupOutput(...args){const target=await original.durableBackupOutput(...args);return {...target,async abort(){counts.aborts=(counts.aborts||0)+1;await target.abort();}};}
          };return true;})()''')
          result={'browser':browser.call('Browser.getVersion'),'scenarios':invoke(browser,'suite')}
          browser.stop();browser.start();browser.navigate(url)
          result['process_restart']=invoke(browser,'reopen');result['status']='PASS'
          (evidence/'web-storage-migration.json').write_text(json.dumps(result,indent=2,ensure_ascii=False))
          print(json.dumps(result,indent=2),flush=True)
        finally:browser.stop()
    finally:server.shutdown();server.server_close()
if __name__=='__main__':main()
