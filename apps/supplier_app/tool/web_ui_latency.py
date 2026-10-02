"""A15 small-fixture UI latency, existing packaged release; no platform certification.

Run only on an otherwise idle host. Uses isolated Chrome and injected file handles.
The clock starts on the browser pointerdown event, not a Python sleep or RPC timer.
"""
import argparse
import base64
import functools
import hashlib
import http.server
import importlib.util
import io
import json
import math
from pathlib import Path
import platform
import tempfile
import threading
import time
import uuid
import zipfile

APP = Path(__file__).resolve().parents[1]
ROOT = APP.parents[1]


def summarize(samples, threshold):
    if len(samples) != 20 or any(not math.isfinite(x) or x < 0 for x in samples):
        raise ValueError('Exactly 20 finite nonnegative warmed observations required')
    return {'samples_ms': samples, 'p95_ms': sorted(samples)[18],
            'max_ms': max(samples), 'threshold_ms': threshold,
            'status': 'PASS' if max(samples) <= threshold else 'FAIL'}


def large_workbook(tiny, count):
    with zipfile.ZipFile(io.BytesIO(tiny)) as source:
        xml = source.read('xl/worksheets/sheet1.xml').decode()
        row = xml[xml.index('<row r="2"'):xml.index('</sheetData>')]
        # Repeated business rows are intentional: parse cancellation happens
        # before row decisions or any business commit.
        rows = ''.join(row.replace('r="2"', f'r="{i}"').replace('2" t=', f'{i}" t=')
                       for i in range(2, count + 2))
        output = io.BytesIO()
        with zipfile.ZipFile(output, 'w', zipfile.ZIP_DEFLATED) as target:
            for name in source.namelist():
                target.writestr(name, xml.replace(row, rows) if name.endswith('sheet1.xml') else source.read(name))
    return output.getvalue()


def pointer(browser, rect):
    for kind in ['mousePressed', 'mouseReleased']:
        browser.call('Input.dispatchMouseEvent', {'type': kind, **rect,
                     'button': 'left', 'clickCount': 1})


def measure(browser, label, condition):
    rect = browser.evaluate('''(() => {
      const n=[...document.querySelectorAll('flt-semantics')].find(n=>
        ['button','tab'].includes(n.getAttribute('role')) &&
        (n.getAttribute('aria-label')===%s || n.innerText===%s));
      if(!n || n.getAttribute('aria-disabled')==='true')return null;
      const r=n.getBoundingClientRect();
      if(r.top<0||r.bottom>innerHeight||r.width===0)return null;
      return {x:r.x+r.width/2,y:r.y+r.height/2};})()''' % (json.dumps(label), json.dumps(label)))
    if not rect:
        raise RuntimeError('Missing enabled visible timed control: ' + label)
    browser.evaluate('''(() => {
      const ready=()=>Boolean(%s);
      if(ready())throw Error('Completion condition already true before action');
      window.latencyResult=null;
      let start=null, pending=false, finished=false;
      const cleanup=()=>{observer.disconnect();clearTimeout(timer);
        document.removeEventListener('pointerdown',begin,true)};
      const check=()=>{if(start===null||pending||finished||!ready())return;
        pending=true;requestAnimationFrame(()=>requestAnimationFrame(()=>{
          pending=false;if(!ready())return;finished=true;
          window.latencyResult={ms:performance.now()-start};cleanup();}));};
      const begin=()=>{start=performance.now();check()};
      const observer=new MutationObserver(check);
      observer.observe(document.body,{subtree:true,childList:true,attributes:true,characterData:true});
      document.addEventListener('pointerdown',begin,{capture:true,once:true});
      const timer=setTimeout(()=>{finished=true;window.latencyResult={error:'completion timeout',started:start!==null};cleanup()},15000);
      return true;})()''' % condition)
    pointer(browser, rect)
    result = browser.evaluate('''new Promise(resolve=>{const poll=()=>{
      if(window.latencyResult)resolve(window.latencyResult);else setTimeout(poll,10)};poll()})''')
    if 'error' in result:
        result['body'] = browser.evaluate('document.body.innerText')
        raise RuntimeError(str(result))
    return result['ms']


def fill(browser, value):
    selector = 'input[aria-label="搜索报价"]'
    rect = browser.evaluate('''(()=>{const n=document.querySelector(%s);if(!n)return null;
      const r=n.getBoundingClientRect();return {x:r.x+r.width/2,y:r.y+r.height/2}})()''' % json.dumps(selector))
    if not rect:
        raise RuntimeError('Search input missing')
    pointer(browser, rect)
    field = browser.call('Runtime.evaluate', {'expression': 'document.querySelector('+json.dumps(selector)+')'})['result']['objectId']
    for _ in range(100):
        if any(x['type'] == 'input' for x in browser.call('DOMDebugger.getEventListeners', {'objectId': field})['listeners']):
            break
        time.sleep(.02)
    else:
        raise RuntimeError('Flutter input listener absent')
    browser.evaluate('document.querySelector('+json.dumps(selector)+').select()')
    browser.call('Input.insertText', {'text': value})


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--rows', type=int, default=10000)
    parser.add_argument('--output', type=Path, default=ROOT/'artifacts/development/web-ui-latency.json')
    args = parser.parse_args()
    report = {'status': 'RUNNING', 'run_id': uuid.uuid4().hex,
              'scope': 'Small seeded query and 10000-row parse UI; not full A15',
              'limitations': ['Injected file handles; system picker excluded.',
                              'One quotation query fixture; 100k first-screen performance unverified.',
                              'Semantics plus two animation frames is a paint opportunity, not pixel proof.',
                              'Progress measures visible parsing/cancel control as busy feedback; unlabeled Flutter progress bar has no DOM role. No quantified completed work.',
                              'Cancel feedback measures acknowledgement; worker exit and total memory unmeasured.',
                              'Android and Windows DEFERRED.'], 'metrics': {}}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2))
    server = None
    try:
        spec = importlib.util.spec_from_file_location('injected_ui', APP/'tool/web_exchange_ui_injected_test.py')
        ui = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(ui)
        build = APP/'build/web'
        report['release'] = json.loads((build/'supplier_offline_manifest.json').read_text())
        report['host'] = platform.platform()
        tiny = ui.workbook()
        large = large_workbook(tiny, args.rows)
        report['parse_fixture'] = {'rows': args.rows, 'bytes': len(large), 'sha256': hashlib.sha256(large).hexdigest()}
        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(ui.ui.transport.Handler, directory=str(build)))
        threading.Thread(target=server.serve_forever, daemon=True).start()
        with tempfile.TemporaryDirectory(prefix='supplier-latency-') as profile, args.output.with_suffix('.chrome.log').open('w') as log:
            browser = ui.ui.ObservedBrowser(profile, log)
            try:
                browser.start()
                report['browser'] = browser.call('Browser.getVersion')
                ui.ready(browser, f'http://127.0.0.1:{server.server_port}/')
                browser.evaluate('''window.latencyFile=new File([Uint8Array.from(atob(%s),c=>c.charCodeAt(0))],'latency.xlsx');
                  window.showOpenFilePicker=async()=>[{kind:'file',name:window.latencyFile.name,getFile:async()=>window.latencyFile}];true''' % json.dumps(base64.b64encode(tiny).decode()))
                for label in ['导入导出/备份', '导入业务 Excel', '选择 Excel 文件', '解析选中工作表']:
                    ui.click(browser, label)
                ui.wait_text(browser, '选择列映射')
                for label in ['确认映射并查看转换预览', '核对并选择操作', '明确新建供应商', '明确新建产品']:
                    ui.click(browser, label)
                if '已核对并接受上述格式转换' in ui.ui.text(browser):
                    ui.click(browser, '已核对并接受上述格式转换')
                ui.click(browser, '确认本行决定')
                ui.click(browser, '查看最终汇总')
                ui.wait_text(browser, '确认产生 1 条报价结果')
                ui.click(browser, '确认汇总并提交导入')
                ui.wait_text(browser, '成功回执：')
                ui.click(browser, 'Back')
                ui.click(browser, '查询与比价')
                query = []
                for i in range(24):
                    missing = i % 2 == 0
                    fill(browser, '不存在的报价XYZ' if missing else '界面验收产品')
                    condition = ('document.body.innerText.includes("没有符合条件的记录")' if missing else
                                 'document.body.innerText.includes("32.123456") && !document.body.innerText.includes("没有符合条件的记录")')
                    value = measure(browser, '搜索', condition)
                    if i >= 4:
                        query.append(value)
                report['metrics']['query_first_screen'] = summarize(query, 1000)
                browser.evaluate('window.latencyFile=new File([Uint8Array.from(atob(%s),c=>c.charCodeAt(0))],"latency-large.xlsx");true' % json.dumps(base64.b64encode(large).decode()))
                ui.click(browser, '导入导出/备份')
                progress, cancel = [], []
                for i in range(23):
                    ui.click(browser, '导入业务 Excel')
                    ui.click(browser, '选择 Excel 文件')
                    ui.wait_text(browser, 'latency-large.xlsx')
                    # Flutter's unlabeled indeterminate LinearProgressIndicator
                    # is painted on CanvasKit without a progressbar DOM node.
                    # The cancel control exists only while _busy && _parsing,
                    # so observe this accessible, visible parsing feedback.
                    parsing_control = '''[...document.querySelectorAll('flt-semantics[role="button"]')].some(n=>
                        (n.getAttribute('aria-label')==='取消解析'||n.innerText==='取消解析') &&
                        n.getBoundingClientRect().height>0)'''
                    first = measure(browser, '解析选中工作表', parsing_control)
                    feedback = measure(browser, '取消解析', 'document.body.innerText.includes("已请求取消解析") || document.body.innerText.includes("任务已取消") || document.body.innerText.includes("CANCELLED: 文件解析已取消")')
                    if i >= 3:
                        progress.append(first)
                        cancel.append(feedback)
                    # Do not overlap parser lifetimes across samples. This
                    # cleanup wait is excluded from acknowledgement latency.
                    for _ in range(300):
                        if not browser.evaluate(parsing_control):
                            break
                        time.sleep(.1)
                    else:
                        raise RuntimeError('Parser did not finish cleanup within 30 seconds')
                    ui.click(browser, 'Back')
                report['metrics']['parse_first_progress'] = summarize(progress, 1000)
                report['metrics']['parse_cancel_feedback'] = summarize(cancel, 2000)
                report['status'] = 'PASS' if all(m['status'] == 'PASS' for m in report['metrics'].values()) else 'FAIL'
                report['a15_overall'] = 'PARTIAL'
            finally:
                browser.stop()
    except BaseException as error:
        report['status'] = 'FAIL'
        report['error'] = str(error)
        raise
    finally:
        if server:
            server.shutdown()
            server.server_close()
        args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2))
        print(args.output)


if __name__ == '__main__':
    main()
