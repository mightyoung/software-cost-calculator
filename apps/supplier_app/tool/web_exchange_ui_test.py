"""Observe the real Flutter release UI and native File System Access chooser.

No production JavaScript is replaced. Evidence distinguishes an actual chooser
automation limitation from import adapter failures.
"""
import base64
import functools
import http.server
import importlib.util
import json
from pathlib import Path
import tempfile
import threading
import time

APP = Path(__file__).resolve().parents[1]
ROOT = APP.parents[1]
spec = importlib.util.spec_from_file_location('exchange_ui_transport', ROOT / 'prototypes/web_storage_gate/tool/browser_test.py')
transport = importlib.util.module_from_spec(spec)
spec.loader.exec_module(transport)


class ObservedBrowser(transport.Browser):
    def __init__(self, profile, log):
        super().__init__(profile, log)
        self.events = []

    def call(self, method, params=None):
        self.seq += 1
        self.ws.send(json.dumps({'id':self.seq,'method':method,'params':params or {}}))
        while True:
            message=json.loads(self.ws.recv())
            if message.get('method')=='Page.fileChooserOpened':
                self.events.append(message)
            if message.get('id')==self.seq:
                if 'error' in message:
                    raise RuntimeError(message)
                return message['result']


def text(browser):
    return browser.evaluate('document.body.innerText')


def click_label(browser, label):
    rect = browser.evaluate('''(() => {
      const nodes=[...document.querySelectorAll('flt-semantics')].filter(n=>['button','tab'].includes(n.getAttribute('role')));
      const node=nodes.find(n=>n.getAttribute('aria-label')===%s)
        || nodes.find(n=>n.innerText===%s);
      if(!node) return null;
      const r=node.getBoundingClientRect();return {x:r.x+r.width/2,y:r.y+r.height/2};
    })()''' % (json.dumps(label), json.dumps(label)))
    if not rect:
        raise RuntimeError('Missing UI control: '+label+'; '+text(browser))
    for kind in ['mousePressed', 'mouseReleased']:
        browser.call('Input.dispatchMouseEvent', {'type':kind, **rect, 'button':'left', 'clickCount':1})
    time.sleep(1)


def main():
    evidence = ROOT / 'artifacts/development'
    server = http.server.ThreadingHTTPServer(('127.0.0.1',0),functools.partial(transport.Handler,directory=str(APP/'build/web')))
    threading.Thread(target=server.serve_forever,daemon=True).start()
    result={'status':'RUNNING','scope':'real Flutter release UI; no picker replacement'}
    try:
        with tempfile.TemporaryDirectory(prefix='supplier-exchange-ui-') as profile, (evidence/'web-exchange-ui-chrome.log').open('w') as log:
            browser=ObservedBrowser(profile,log)
            try:
                browser.start()
                result['browser']=browser.call('Browser.getVersion')
                browser.call('Page.enable')
                browser.call('Page.setInterceptFileChooserDialog',{'enabled':True})
                browser.call('Page.navigate',{'url':f'http://127.0.0.1:{server.server_port}/'})
                for _ in range(300):
                    if browser.evaluate("Boolean(document.querySelector('flt-semantics-placeholder'))"):
                        break
                    time.sleep(.2)
                browser.evaluate("document.querySelector('flt-semantics-placeholder')?.click()")
                time.sleep(5)
                result['initial_text']=text(browser)
                result['semantics']=browser.evaluate("[...document.querySelectorAll('flt-semantics')].map(n=>({label:n.getAttribute('aria-label'),text:n.innerText,role:n.getAttribute('role')}))")
                click_label(browser,'文件与备份')
                result['exchange_text']=text(browser)
                click_label(browser,'导入业务 Excel')
                result['business_text']=text(browser)
                click_label(browser,'选择 Excel 文件')
                time.sleep(3)
                result['after_picker_text']=text(browser)
                result['file_chooser_events']=browser.events
                try:
                    result['handle_file_chooser']=browser.call('Page.handleFileChooser',{'action':'cancel'})
                except Exception as error:
                    result['handle_file_chooser_error']=str(error)
                result['input_elements']=browser.evaluate("[...document.querySelectorAll('input')].map(n=>({type:n.type,accept:n.accept}))")
                result['status']='BLOCKED' if '选择资料与工作表' in result['after_picker_text'] else 'OBSERVED'
                result['limitation']='Native File System Access showOpenFilePicker cannot be populated with DOM.setFileInputFiles; no HTML file input exists. No picker replacement was used.'
            except Exception as error:
                result['status']='BLOCKED'
                result['error']=str(error)
            finally:
                try:
                    result['final_text']=text(browser)
                    image=browser.call('Page.captureScreenshot',{'format':'png'})
                    (evidence/'web-exchange-ui.png').write_bytes(base64.b64decode(image['data']))
                finally:
                    browser.stop()
    finally:
        server.shutdown();server.server_close()
        (evidence/'web-exchange-ui.json').write_text(json.dumps(result,ensure_ascii=False,indent=2))
        print(json.dumps(result,ensure_ascii=False,indent=2))


if __name__=='__main__':
    main()
