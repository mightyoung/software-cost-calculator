"""Flutter release UI with injected File System Access handles, NOT native choosers.

Uses a fresh Chrome profile and a tiny real XLSX. Product code is unmodified.
Requires an existing build/web; never rebuilds while a benchmark is running.
"""
import base64
import functools
import hashlib
import http.server
import importlib.util
import io
import json
from pathlib import Path
import re
import subprocess
import tempfile
import threading
import time
import xml.sax.saxutils
import zipfile

APP = Path(__file__).resolve().parents[1]
ROOT = APP.parents[1]
spec = importlib.util.spec_from_file_location('exchange_ui', APP / 'tool/web_exchange_ui_test.py')
ui = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ui)


def workbook():
    rows = [
        ['supplier_name', 'product_name', 'price', 'unit_snapshot', 'quoted_on',
         'inquiry_date', 'inquiry_precision', 'project_name', 'inquirer_name'],
        ['界面验收供应商', '界面验收产品', '32.123456', '件', '2026-09-23',
         '2026-09-23', 'date', '界面验收采购', '李工'],
    ]
    sheet = ''.join('<row r="%s">%s</row>' % (i, ''.join(
        '<c r="%s%s" t="inlineStr"><is><t>%s</t></is></c>' %
        (chr(65+j), i, xml.sax.saxutils.escape(value))
        for j, value in enumerate(row))) for i, row in enumerate(rows, 1))
    data = io.BytesIO()
    with zipfile.ZipFile(data, 'w', zipfile.ZIP_DEFLATED) as archive:
        archive.writestr('[Content_Types].xml', '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/></Types>')
        archive.writestr('_rels/.rels', '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>')
        archive.writestr('xl/workbook.xml', '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="报价" sheetId="1" r:id="rId1"/></sheets></workbook>')
        archive.writestr('xl/_rels/workbook.xml.rels', '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/></Relationships>')
        archive.writestr('xl/worksheets/sheet1.xml', '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>'+sheet+'</sheetData></worksheet>')
    return data.getvalue()


def wait_text(browser, expected, timeout=60):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        current = ui.text(browser)
        if expected in current:
            return current
        if '操作未完成：' in current or '此行尚未确认：' in current:
            raise RuntimeError(current)
        time.sleep(.2)
    raise RuntimeError('UI timeout: '+expected+'; '+ui.text(browser))


def click(browser, label):
    # Scroll the actual Flutter viewport with wheel input, then use pointer input.
    for attempt in range(28):
        rect = browser.evaluate('''(() => {
          const nodes=[...document.querySelectorAll('flt-semantics')];
          const n=nodes.find(n=>n.getAttribute('aria-label')===%s)
            || nodes.find(n=>['button','tab'].includes(n.getAttribute('role')) && ((n.getAttribute('aria-label')||'').startsWith(%s+' Tab ') || (n.innerText||'').startsWith(%s+' Tab ')))
            || nodes.find(n=>n.innerText===%s && ['button','checkbox','tab'].includes(n.getAttribute('role')));
          if(!n) return null;
          const r=n.getBoundingClientRect();
          return {x:r.x+r.width/2,y:r.y+r.height/2,visible:r.height>0&&r.top>=0&&r.bottom<=innerHeight};
        })()''' % (json.dumps(label), json.dumps(label), json.dumps(label), json.dumps(label)))
        if rect and rect['visible']:
            for kind in ['mousePressed', 'mouseReleased']:
                browser.call('Input.dispatchMouseEvent', {'type':kind, 'x':rect['x'], 'y':rect['y'], 'button':'left', 'clickCount':1})
            time.sleep(.4)
            return
        browser.call('Input.dispatchMouseEvent', {'type':'mouseWheel','x':700,'y':500,'deltaX':0,'deltaY':-600 if attempt == 14 else 450})
        time.sleep(.15)
    nodes = browser.evaluate("[...document.querySelectorAll('flt-semantics')].map(n=>[n.getAttribute('role'),n.getAttribute('aria-label'),n.innerText]).filter(n=>n[1]||n[2]).slice(0,35)")
    raise RuntimeError('Missing/hidden UI control: '+label+'; '+ui.text(browser)+'; semantics='+repr(nodes))


def ready(browser, url):
    browser.call('Emulation.setDeviceMetricsOverride', {'width':1440,'height':1100,'deviceScaleFactor':1,'mobile':False})
    browser.call('Page.navigate', {'url':url})
    for _ in range(300):
        if browser.evaluate("Boolean(document.querySelector('flt-semantics-placeholder'))"):
            browser.evaluate("document.querySelector('flt-semantics-placeholder').click()")
            break
        time.sleep(.2)
    wait_text(browser, '导入导出/备份')


def main():
    evidence = ROOT / 'artifacts/development'
    evidence.mkdir(parents=True, exist_ok=True)
    prefix = evidence / 'web-exchange-ui-injected'
    report = {'status':'RUNNING','scope':'Flutter release UI with injected open/save handles',
              'native_system_picker_verified':False, 'steps':[]}
    browser = None
    server = None
    try:
        if not (APP/'build/web/index.html').exists():
            report['status'] = 'BLOCKED'
            raise RuntimeError('Existing Flutter release build/web missing; build deferred during native benchmark.')
        fixture = workbook()
        prefix.with_suffix('.xlsx').write_bytes(fixture)
        report['fixture_sha256'] = hashlib.sha256(fixture).hexdigest()
        injection = '''window.uiInjectedSaves=[];window.uiInjectedOpens=[];
          window.uiInjectedFile=new File([Uint8Array.from(atob(%s),c=>c.charCodeAt(0))],'ui-business.xlsx');
          window.showOpenFilePicker=async()=>{const f=window.uiInjectedFile;window.uiInjectedOpens.push({name:f.name,size:f.size});return [{kind:'file',name:f.name,getFile:async()=>f}];};
          window.showSaveFilePicker=async(options)=>({kind:'file',name:options.suggestedName,
            createWritable:async()=>{let chunks=[];return {write:async(v)=>{chunks.push(v)},
              close:async()=>{window.uiInjectedSaves.push(new File(chunks,options.suggestedName));},
              abort:async()=>{chunks=[];}};}});
        ''' % json.dumps(base64.b64encode(fixture).decode())
        server = http.server.ThreadingHTTPServer(('127.0.0.1',0),functools.partial(ui.transport.Handler,directory=str(APP/'build/web')))
        threading.Thread(target=server.serve_forever,daemon=True).start()
        url = f'http://127.0.0.1:{server.server_port}/'
        with tempfile.TemporaryDirectory(prefix='supplier-ui-injected-') as profile, prefix.with_suffix('.chrome.log').open('w') as log:
            browser = ui.ObservedBrowser(profile, log)
            try:
                browser.start()
                report['browser'] = browser.call('Browser.getVersion')
                browser.call('Page.addScriptToEvaluateOnNewDocument', {'source':injection})
                ready(browser, url)
                browser.evaluate(injection+'true')
                for label in ['导入导出/备份','导入业务 Excel','选择 Excel 文件']:
                    click(browser,label)
                report['picker_state'] = browser.evaluate('({injected:!!window.uiInjectedFile,open_calls:window.uiInjectedOpens||null,handler:String(window.showOpenFilePicker).slice(0,90)})')
                report['chooser_events'] = browser.events
                if not report['picker_state']['open_calls']:
                    raise RuntimeError('Injected picker was not called: '+repr(report['picker_state'])+'; chooser='+repr(browser.events))
                wait_text(browser,'ui-business.xlsx')
                click(browser,'解析选中工作表')
                wait_text(browser,'选择列映射')
                click(browser,'确认映射并查看转换预览')
                wait_text(browser,'逐行核对')
                click(browser,'核对并选择操作')
                click(browser,'明确新建供应商')
                click(browser,'明确新建产品')
                if '已核对并接受上述格式转换' in ui.text(browser):
                    click(browser,'已核对并接受上述格式转换')
                click(browser,'确认本行决定')
                time.sleep(1.5)
                click(browser,'查看最终汇总')
                time.sleep(1)
                if '逐行核对' in ui.text(browser):
                    click(browser,'查看最终汇总')
                wait_text(browser,'确认产生 1 条报价结果')
                click(browser,'确认汇总并提交导入')
                done = wait_text(browser,'成功回执：')
                report['business_text'] = done
                report['receipt'] = re.search(r'成功回执：([^\s]+)',done).group(1)
                job = re.search(r'任务编号：([^\s]+)',done)
                report['job_id'] = job.group(1) if job else None
                report['steps'].append('business UI mapping, row decision and commit')
                click(browser,'Back')
                click(browser,'打开完整同步')
                click(browser,'生成同步包')
                report['export_text'] = wait_text(browser,'完整同步包已自验并写入所选文件')
                browser.evaluate('window.uiInjectedFile=window.uiInjectedSaves.at(-1);true')
                click(browser,'选择并预览')
                wait_text(browser,'确认完整同步')
                click(browser,'备份并提交')
                report['bundle_text'] = wait_text(browser,'完整同步已一次提交')
                report['steps'].append('bundle UI export, preview and commit')
                report['injected_open_calls'] = browser.evaluate('window.uiInjectedOpens')
                report['saved_files'] = browser.evaluate('window.uiInjectedSaves.map(f=>({name:f.name,size:f.size}))')
                report['browser_restart'] = browser.stop()
                browser.start()
                ready(browser,url)
                click(browser,'导入导出/备份')
                click(browser,'查看文件任务记录')
                time.sleep(2)
                report['durable_history_text'] = ui.text(browser) + '\n' + browser.evaluate("[...document.querySelectorAll('flt-semantics')].map(n=>[n.getAttribute('aria-label'),n.innerText].filter(Boolean).join(' ')).join('\\n')")
                history_png = base64.b64decode(browser.call('Page.captureScreenshot',{'format':'png'})['data'])
                prefix.with_suffix('.png').write_bytes(history_png)
                ocr = subprocess.run(['tesseract',str(prefix.with_suffix('.png')),'stdout','-l','chi_sim'],capture_output=True,text=True,check=True)
                report['task_history_ocr'] = ocr.stdout
                if len(re.findall(r'基线 generation [01]',ocr.stdout)) < 2:
                    raise RuntimeError('Expected two completed task cards in restarted browser screenshot')
                report['durable_opfs_files'] = browser.evaluate('''(async()=>{const files=[];
                  async function walk(dir,prefix){for await(const [name,h] of dir.entries()){
                    if(h.kind==='directory') await walk(h,prefix+name+'/');
                    else {const f=await h.getFile();files.push({path:prefix+name,size:f.size});}}}
                  await walk(await navigator.storage.getDirectory(),'');return files;})()''')
                report['backup_files'] = [f for f in report['durable_opfs_files'] if '-backups/' in f['path'] and f['size']>0]
                if len(report['backup_files']) < 2:
                    raise RuntimeError('Expected durable business and bundle backup files after browser restart')
                if report['job_id'] and report['job_id'] not in report['durable_history_text']:
                    raise RuntimeError('Committed business task missing after browser restart')
                report['status'] = 'PASS'
                report['limitations'] = ['Open/save handles injected; native chooser not verified.', 'Backup files persist; semantic backup verification belongs to formal adapter test.']
            finally:
                if browser.ws:
                    try:
                        report['final_text'] = ui.text(browser)
                        png=browser.call('Page.captureScreenshot',{'format':'png'})
                        prefix.with_suffix('.png').write_bytes(base64.b64decode(png['data']))
                    except Exception as error:
                        report['capture_error']=str(error)
                browser.stop()
    except Exception as error:
        if report['status'] != 'BLOCKED':
            report['status']='FAIL'
        report['error']=str(error)
        if browser and browser.ws:
            try:
                report['semantics_debug']=browser.evaluate('''[...document.querySelectorAll('flt-semantics')].map(n=>({role:n.getAttribute('role'),label:n.getAttribute('aria-label'),text:n.innerText,rect:(()=>{const r=n.getBoundingClientRect();return [r.x,r.y,r.width,r.height]})()})).filter(n=>n.label||n.text).slice(0,80)''')
            except Exception:
                pass
    finally:
        if server:
            server.shutdown();server.server_close()
        prefix.with_suffix('.json').write_text(json.dumps(report,ensure_ascii=False,indent=2))
        print(json.dumps({k:report[k] for k in ['status','scope','steps','error'] if k in report},ensure_ascii=False))
    return 0 if report['status']=='PASS' else 1


if __name__=='__main__':
    raise SystemExit(main())
