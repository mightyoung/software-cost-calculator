import test from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import {readFile} from 'node:fs/promises';
const html=await readFile(new URL('../../../apps/supplier_app/assets/ontology_graph/index.html',import.meta.url),'utf8');
const source=html.slice(html.lastIndexOf('<script>')+8,html.lastIndexOf('</script>'));
const schema=JSON.parse(await readFile(new URL('./schema.json',import.meta.url),'utf8'));
const payload=()=>({version:1,schema,counts:{supplier:7},selected:'quotation',dark:false,reducedMotion:false,textScale:1});
function fixture({delayed=false}={}){
  const nodes=new Map(),events=new Map(),graphEvents=new Map(),calls=[],metrics={renders:0,draws:0,zoomStops:0,destroyed:0,edges:[],width:900,height:600,zoom:1,focused:[],sizes:[],fits:0,zoomAnimations:[],focusAnimations:[]};
  let resizeCallback;
  const element=()=>({dataset:{},style:{setProperty(){}},classList:{add(){}},value:'',checked:false,clientWidth:900,
    children:[],append(...c){this.children.push(...c);},replaceChildren(...c){this.children=c;},setAttribute(){},addEventListener(){},getBoundingClientRect:()=>({width:metrics.width,height:metrics.height})});
  const document={getElementById(id){if(!nodes.has(id))nodes.set(id,element());return nodes.get(id);},createElement:element,querySelectorAll:()=>[],documentElement:element(),body:element()};
  class Graph{
    on(name,handler){graphEvents.set(name,handler);} off(){} async render(){metrics.renders++;} async draw(){metrics.draws++;await metrics.drawGate;}
    getZoom(){return metrics.zoom;} async zoomTo(zoom,animation){metrics.zoomStops++;metrics.zoom=zoom;metrics.zoomAnimations.push(animation);if(animation)await metrics.zoomGate;} async focusElement(id,animation){metrics.focused.push(id);metrics.focusAnimations.push(animation);}
    async fitView(){metrics.fits++;}
    updateNodeData(){} updateEdgeData(edges){metrics.edges=edges;} setSize(w,h){metrics.sizes.push([w,h]);} setData(){} destroy(){metrics.destroyed++;}
  }
  const window={G6:{Graph},addEventListener(name,fn){const list=events.get(name)||[];list.push(fn);events.set(name,list);},removeEventListener(name,fn){events.set(name,(events.get(name)||[]).filter(f=>f!==fn));}};
  const attach=()=>{window.flutter_inappwebview={async callHandler(name,...args){calls.push([name,...args]);if(name==='ontologyReady')return payload();}};};
  if(!delayed)attach();
  const context={window,document,G6:window.G6,matchMedia:()=>({matches:false,addEventListener(){},removeEventListener(){}}),structuredClone,
    ResizeObserver:class{constructor(callback){resizeCallback=callback;}observe(){}disconnect(){}},requestAnimationFrame:callback=>{callback();return 1;},cancelAnimationFrame(){},console:{error(){}},encodeURIComponent};
  vm.runInNewContext(source,context);
  return {window,document,calls,metrics,attach,resize(width,height){metrics.width=width;metrics.height=height;resizeCallback();},graphEvent:(name,event)=>graphEvents.get(name)(event),dispatch:name=>(events.get(name)||[]).slice().forEach(f=>f())};
}
test('packaged runtime waits for native bridge and reports completion after rendering',async()=>{
  const f=fixture({delayed:true});assert.equal(f.calls.length,0);
  f.attach();f.dispatch('flutterInAppWebViewPlatformReady');await f.window.ontologyHost.update(payload());
  assert.equal(f.calls.filter(c=>c[0]==='ontologyReady').length,1);
  assert.equal(f.calls.filter(c=>c[0]==='ontologyRendered').length,1);
  assert.equal(f.metrics.renders,1);
});
test('host updates retain graph layout and do not echo native selections',async()=>{
  const f=fixture();await f.window.ontologyHost.update(payload());
  await Promise.all([
    f.window.ontologyHost.update({...payload(),selected:'supplier',counts:{supplier:123},dark:true}),
    f.window.ontologyHost.update({...payload(),selected:'product',reducedMotion:true,textScale:1.4}),
  ]);
  assert.equal(f.metrics.renders,1);assert.equal(f.document.getElementById('object').value,'product');
  assert.ok(f.metrics.zoomStops>=1);assert.ok(!f.calls.some(c=>c[0]==='ontologySelect'));
  f.document.getElementById('object').value='supplier';
  await f.document.getElementById('object').onchange();
  assert.deepEqual(f.calls.filter(c=>c[0]==='ontologySelect'),[['ontologySelect','supplier']]);
});
test('invalid update reports an error, preserves selected object, and teardown ignores further updates',async()=>{
  const f=fixture();await f.window.ontologyHost.update(payload());
  await f.window.ontologyHost.update({...payload(),selected:'missing'});
  assert.ok(f.calls.some(c=>c[0]==='ontologyError'));
  assert.equal(f.document.getElementById('object').value,'quotation');
  f.dispatch('pagehide');await f.window.ontologyHost.update({...payload(),selected:'supplier'});
  assert.equal(f.metrics.destroyed,1);assert.equal(f.document.getElementById('object').value,'quotation');
});
test('edge selection survives echoed native object and appearance updates but clears on object change or removal',async()=>{
  const f=fixture();await f.window.ontologyHost.update(payload());
  const edge=schema.edges.find(e=>e.source!=='quotation' && e.target!=='quotation');
  f.graphEvent('edge:click',{target:{id:edge.id}});
  assert.equal(f.document.getElementById('object').value,edge.source);
  const echoed={...payload(),selected:edge.source,counts:{supplier:99},dark:true};
  await f.window.ontologyHost.update(echoed);
  assert.equal(f.metrics.edges.find(e=>e.id===edge.id).style.labelText,edge.data.label);
  await f.window.ontologyHost.update({...echoed,selected:'quotation'});
  assert.equal(f.metrics.edges.find(e=>e.id===edge.id).style.labelText,'');
  f.graphEvent('edge:click',{target:{id:edge.id}});
  await f.window.ontologyHost.update({...echoed,schema:{...schema,edges:schema.edges.filter(e=>e.id!==edge.id)}});
  assert.ok(f.metrics.edges.every(e=>e.style.labelText===''));
});
test('reduced motion stops viewport animation immediately while a preceding draw is pending',async()=>{
  const f=fixture();await f.window.ontologyHost.update(payload());
  let release;f.metrics.drawGate=new Promise(resolve=>{release=resolve;});
  const first=f.window.ontologyHost.update({...payload(),dark:true});
  await new Promise(setImmediate);
  const before=f.metrics.zoomStops;
  const next=f.window.ontologyHost.update({...payload(),reducedMotion:true});
  assert.equal(f.metrics.zoomStops,before+1);
  release();await Promise.all([first,next]);
});
test('narrow resize fits the complete model without forcing a crop or recalculating layout',async()=>{
  const f=fixture();await f.window.ontologyHost.update({...payload(),selected:'supplier'});
  f.metrics.zoom=.4;f.resize(390,470);await new Promise(setImmediate);
  assert.equal(f.metrics.zoom,.4);assert.equal(f.metrics.fits,1);assert.equal(f.metrics.focused.length,0);
  assert.deepEqual(f.metrics.sizes.at(-1),[390,470]);assert.equal(f.metrics.renders,1);
  const focusCount=f.metrics.focused.length;f.resize(385,460);await new Promise(setImmediate);
  assert.equal(f.metrics.focused.length,focusCount);
  assert.equal(f.metrics.fits,1);
});
test('explicit focus restores readable zoom after full fit and preserves closer zoom',async()=>{
  const f=fixture();await f.window.ontologyHost.update({...payload(),textScale:1.4,reducedMotion:true});
  f.metrics.zoom=.25;
  await f.document.getElementById('focus').onclick();
  assert.equal(f.metrics.zoom,.85);assert.equal(f.metrics.focused.at(-1),'quotation');
  assert.equal(f.metrics.zoomAnimations.at(-1),false);assert.equal(f.metrics.focusAnimations.at(-1),false);
  assert.equal(f.document.getElementById('zoom').textContent,'85%');
  f.metrics.zoom=1.6;const zoomCalls=f.metrics.zoomStops;
  await f.document.getElementById('focus').onclick();
  assert.equal(f.metrics.zoom,1.6);assert.equal(f.metrics.zoomStops,zoomCalls);
  f.metrics.zoom=.25;f.document.getElementById('object').value='supplier';
  await f.document.getElementById('object').onchange();
  assert.equal(f.metrics.zoom,.85);assert.equal(f.metrics.focused.at(-1),'supplier');
});
test('reduced motion interrupts focus zoom and prevents its following pan animation',async()=>{
  const f=fixture();await f.window.ontologyHost.update(payload());
  let release;f.metrics.zoomGate=new Promise(resolve=>{release=resolve;});f.metrics.zoom=.25;
  const focus=f.document.getElementById('focus').onclick();
  await new Promise(setImmediate);
  const update=f.window.ontologyHost.update({...payload(),reducedMotion:true});
  assert.equal(f.metrics.zoomAnimations.at(-1),false);
  release();await Promise.all([focus,update]);
  assert.equal(f.metrics.focusAnimations.at(-1),false);
});
test('property details retain descriptions, enum meaning and navigable reference targets',async()=>{
  const f=fixture();const expanded=structuredClone(schema);
  expanded.nodes.find(n=>n.id==='quotation').data.fields=[{name:'supplier_id',label:'供应商',kind:'引用',required:true,
    description:'报价所属供应商',values:{active:'合作中',paused:'暂停'},target:'supplier'}];
  await f.window.ontologyHost.update({...payload(),schema:expanded});
  const row=f.document.getElementById('properties').children[0];
  assert.equal(row.children.find(c=>c.className==='field-description').textContent,'报价所属供应商');
  const values=row.children.find(c=>c.className==='field-values');
  assert.deepEqual(values.children.map(c=>c.textContent),['active','合作中','paused','暂停']);
  await row.children.find(c=>c.className==='reference-target').onclick();
  assert.equal(f.document.getElementById('object').value,'supplier');
  assert.deepEqual(f.calls.filter(c=>c[0]==='ontologySelect'),[['ontologySelect','supplier']]);
});
