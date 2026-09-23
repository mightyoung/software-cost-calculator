"""Bounded XLSX writer on real OPFS SQLite in a disposable Chrome profile."""
import functools
import http.server
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import shutil
import tempfile
import threading
import time
import uuid
APP=Path(__file__).resolve().parents[1]
ROOT=APP.parents[1]
spec=importlib.util.spec_from_file_location('xlsx_chrome',ROOT/'prototypes/web_storage_gate/tool/browser_test.py')
transport=importlib.util.module_from_spec(spec)
spec.loader.exec_module(transport)
def main():
    output=APP/'.dart_tool/web-xlsx-writer-smoke'
    output.mkdir(parents=True,exist_ok=True)
    dart=os.environ['DART']
    for source,target in [('tool/drift_worker.dart','drift_worker.js'),('tool/web_xlsx_writer_smoke.dart','main.js')]:
        subprocess.run([dart,'compile','js','-O2',source,'-o',str(output/target)],cwd=APP,check=True)
    shutil.copyfile(APP/'web/sqlite3.wasm',output/'sqlite3.wasm')
    shutil.copyfile(APP/'web/supplier_platform.js',output/'supplier_platform.js')
    (output/'index.html').write_text('<!doctype html><script src="supplier_platform.js"></script><script src="main.js" defer></script>')
    server=http.server.ThreadingHTTPServer(('127.0.0.1',0),functools.partial(transport.Handler,directory=str(output)))
    threading.Thread(target=server.serve_forever,daemon=True).start()
    evidence=ROOT/'artifacts/development'
    url=f'http://127.0.0.1:{server.server_port}/index.html?run={uuid.uuid4()}'
    try:
        with tempfile.TemporaryDirectory(prefix='supplier-xlsx-writer-') as profile,(evidence/'xlsx-writer-chrome.log').open('w') as log:
            browser=transport.Browser(profile,log)
            try:
                browser.start();browser.navigate(url)
                browser.evaluate("window.pending=true;runSmoke().then(v=>{window.result=v;window.pending=false},e=>{window.error=String(e);window.pending=false});true",wait=False)
                deadline=time.monotonic()+120
                while browser.evaluate('window.pending') and time.monotonic()<deadline:
                    time.sleep(.2)
                state=browser.evaluate('({pending:window.pending,result:window.result,error:window.error,stage:window.smokeStage})')
                if state.get('pending') or state.get('error'):raise RuntimeError(json.dumps(state))
                first=json.loads(state['result'])
                browser.stop();browser.start();browser.navigate(url)
                reopened=json.loads(browser.evaluate('reopenSmoke()'))
                result={'status':'PASS','first':first,'reopened':reopened}
                (evidence/'xlsx-writer-web-smoke.json').write_text(json.dumps(result,indent=2))
                print(json.dumps(result,indent=2),flush=True)
            finally:browser.stop()
    finally:server.shutdown();server.server_close()
if __name__=='__main__':main()
