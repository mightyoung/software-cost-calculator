import {groups,groupOf,neighborhood,matchingNodes,validateSchema} from './graph-model.mjs';
import {hostPayload} from './host-model.mjs';
const $=id=>document.getElementById(id);
const media=matchMedia('(prefers-reduced-motion: reduce)');
let graph,data,catalog,selected='quotation',edgeSelected=null,all=false,dark=false,busy=false;
const embedded=Boolean(window.ONTOLOGY_ASSETS);
let counts={},hostQuiet=false,pendingQuiet=false,textScale=1,disposed=false,rendered=false,hostQueue=Promise.resolve();
window.addEventListener('pagehide',()=>{disposed=true;},{once:true});
const notify=(name,...args)=>window.flutter_inappwebview?.callHandler(name,...args);
const quiet=()=>hostQuiet || pendingQuiet || media.matches || $('quiet').checked;
const duration=()=>quiet()?false:{duration:240};
const colors=()=>dark?{surface:'#20201e',ink:'#ecece6',muted:'#aaa9a2',line:'#565650',accent:'#deded5'}:
  {surface:'#ffffff',ink:'#202b3b',muted:'#6a7688',line:'#bbc4d1',accent:'#315efb'};
const iconIds={supplier:'supplier',contact:'contact',product:'material',product_param:'match',quotation:'quotation',project:'project',project_item:'workspace',inquiry:'inquiry',spec_request:'review',spec_item:'match',spec_response:'review'};
function el(tag,text,className){const e=document.createElement(tag);if(text!==undefined)e.textContent=text;if(className)e.className=className;return e;}
function icon(id){const path=catalog.find(c=>c.id===iconIds[id])?.path || '';return 'data:image/svg+xml;charset=utf-8,'+encodeURIComponent(`<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24"><path d="${path}" fill="none" stroke="${colors().ink}" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/></svg>`);}
function nodeStyle(n){const p=colors();return {radius:7,fill:p.surface,stroke:groupOf(n.id).color,lineWidth:1.3,iconSrc:icon(n.id),iconWidth:21,iconHeight:21,iconX:-46*textScale,
  labelText:n.data.label,labelPlacement:'center',labelOffsetX:14,labelFontSize:13*textScale,labelFontWeight:500,labelFill:p.ink,labelFontFamily:'system-ui, PingFang SC, Microsoft YaHei, sans-serif',cursor:'pointer',size:[136*textScale,48*textScale]};}
function edgeStyle(){const p=colors();return {stroke:p.line,lineWidth:1,endArrow:true,endArrowSize:5,loopDist:24,loopPlacement:'top',labelFontFamily:'system-ui, PingFang SC, Microsoft YaHei, sans-serif',labelFontSize:11,labelFill:p.ink,labelBackground:true,labelBackgroundFill:dark?'#242421':'#fff',labelPadding:[3,6],labelAutoRotate:false};}
function drawDirectory(){
  $('catalog').replaceChildren();
  $('type-count').textContent=data.nodes.length;
  for(const group of groups){const section=el('section');section.append(el('h2',group.name));
    for(const n of data.nodes.filter(n=>group.ids.includes(n.id))){const b=el('button');b.dataset.type=n.id;b.setAttribute('aria-pressed',n.id===selected);const img=el('img');img.src=icon(n.id);img.alt='';const count=el('small',embedded?(counts[n.id]===undefined?'—':`${counts[n.id]} 条`):`${n.data.fieldCount} 字段`);count.title=embedded?'业务记录数量':'字段数量';b.append(img,el('span',n.data.label),count);b.onclick=()=>select(n.id);section.append(b);}
    $('catalog').append(section);
  }
}
function updateDetail(){
  const n=data.nodes.find(n=>n.id===selected), related=neighborhood(data,selected).edges;
  $('object').value=selected;
  $('detail').replaceChildren(el('h2',n.data.label),el('code',n.id),el('p',n.data.description));
  const meta=el('div',undefined,'metadata');meta.append(el('span',groupOf(n.id).name),el('span',`${n.data.fieldCount} 个字段`));$('detail').append(meta);
  if(embedded)meta.append(el('span',counts[n.id]===undefined?'记录数未提供':`${counts[n.id]} 条记录`));
  $('relation-count').textContent=`${related.length} 条`;
  $('relations').replaceChildren();
  $('properties').replaceChildren();
  for(const f of n.data.fields){
    const row=el('div',f.label,'property');row.append(el('span',f.required?'必填':'可选'),el('small',`${f.name} · ${f.kind}`));
    if(f.description)row.append(el('p',f.description,'field-description'));
    if(f.values && typeof f.values==='object'){
      const values=el('dl',undefined,'field-values');
      for(const [key,meaning] of Object.entries(f.values))values.append(el('dt',key),el('dd',String(meaning)));
      row.append(values);
    }
    const target=data.nodes.find(node=>node.id===f.target);
    if(target){const jump=el('button',`引用 ${target.data.label}`,'reference-target');jump.onclick=()=>select(target.id,{focus:true});row.append(jump);}
    $('properties').append(row);
  }
  for(const edge of related){const b=el('button',edge.data.meaning);b.dataset.edge=edge.id;b.setAttribute('aria-pressed',edge.id===edgeSelected);
    b.append(el('small',`${edge.data.many?'多对多':'多对一'}${edge.source===edge.target?' · 自引用':''} · ${edge.id}`));
    b.onclick=()=>{edgeSelected=edgeSelected===edge.id?null:edge.id;void paintSelection();updateDetail();};$('relations').append(b);}
  document.querySelectorAll('#catalog button').forEach(b=>b.setAttribute('aria-pressed',b.dataset.type===selected));
}
async function paintSelection(){
  if(disposed)return;
  const active=neighborhood(data,selected,all),p=colors();
  graph.updateNodeData(data.nodes.map(n=>({id:n.id,style:{...nodeStyle(n),opacity:active.nodes.has(n.id)?1:.35,
    lineWidth:n.id===selected?2.5:1.5,stroke:n.id===selected?p.accent:groupOf(n.id).color}})));
  graph.updateEdgeData(data.edges.map(e=>({id:e.id,style:{...edgeStyle(),
    opacity:active.edges.some(a=>a.id===e.id)?(edgeSelected && e.id!==edgeSelected ? .22 : .9):.09,
    stroke:e.id===edgeSelected?p.accent:p.muted,lineWidth:e.id===edgeSelected?2:1.2,
    labelText:e.id===edgeSelected?e.data.label:''}})));
  await graph.draw();
}
async function select(id,{focus=false}={}){if(disposed || !data.nodes.some(n=>n.id===id))return;selected=id;edgeSelected=null;updateDetail();if(embedded)void notify('ontologySelect',id);await paintSelection();if(focus && !disposed)await graph.focusElement(id,duration());}
async function fit(){await graph.fitView({when:'always',direction:'both'},duration());updateZoom();}
function updateZoom(){$('zoom').textContent=Math.round(graph.getZoom()*100)+'%';}
async function changeLayout(){if(busy)return;busy=true;$('layout').disabled=true;
  try{const type=$('layout').value;graph.setLayout(type==='concentric'?{type,preventOverlap:true,nodeSize:165,nodeSpacing:32,sortBy:'degree'}:{type,rankdir:'LR',nodesep:45,ranksep:100});await graph.layout();await fit();}
  finally{busy=false;$('layout').disabled=false;}
}
async function theme(){dark=!dark;document.documentElement.dataset.theme=dark?'dark':'light';$('theme').textContent=dark?'切换浅色':'切换深色';
  document.querySelectorAll('#catalog button img').forEach(img=>img.src=icon(img.parentElement.dataset.type));await paintSelection();}
function search(){const q=$('search').value;const results=matchingNodes(data,q);$('results').hidden=!q.trim();$('results').replaceChildren();
  if(q.trim()&&!results.length)$('results').append(el('span','没有匹配对象，请尝试“物料”或 product'));
  for(const n of results){const b=el('button',`${n.data.label} · ${n.id}`);b.onclick=()=>select(n.id,{focus:true});$('results').append(b);}
}
async function start(){
  if(!window.G6)throw new Error('本地图引擎未安装，请在小样目录执行 npm ci。');
  if(embedded){
    document.body.classList.add('embedded');
    const initial=await new Promise((resolve,reject)=>{
      let requested=false;
      const request=()=>{if(requested || !window.flutter_inappwebview?.callHandler)return;requested=true;
        window.removeEventListener('flutterInAppWebViewPlatformReady',request);
        Promise.resolve(notify('ontologyReady')).then(resolve,reject);};
      window.addEventListener('flutterInAppWebViewPlatformReady',request);request();
    });
    if(disposed)return;applyHostState(hostPayload(initial));catalog=window.ONTOLOGY_ASSETS.catalog;
  }else{[data,catalog]=await Promise.all([fetch('./schema.json').then(r=>r.json()),fetch('../icons/catalog.json').then(r=>r.json())]);validateSchema(data);}
  for(const n of data.nodes){const o=el('option',n.data.label);o.value=n.id;$('object').append(o);}
  drawDirectory();updateDetail();
  for(const group of groups){const item=el('span',undefined,'legend-item'),dot=el('i',undefined,'dot');dot.style.background=group.color;item.append(dot,el('span',group.name));$('legend').append(item);}
  $('summary').textContent=`${data.nodes.length} 类对象 · ${data.edges.length} 条引用`;
  graph=new G6.Graph({container:$('graph'),autoFit:'view',padding:65,animation:false,data:structuredClone(data),
    node:{type:'rect',style:n=>({...nodeStyle(n),...n.style})},edge:{style:e=>({...edgeStyle(),...e.style})},transforms:['process-parallel-edges'],
    layout:{type:'concentric',preventOverlap:true,nodeSize:165,nodeSpacing:32,sortBy:'degree'},
    behaviors:['drag-canvas','zoom-canvas','drag-element']});
  graph.on('node:click',event=>select(event.target.id));
  graph.on('edge:click',event=>{edgeSelected=event.target.id;const edge=data.edges.find(e=>e.id===edgeSelected);if(edge && edge.source!==selected && edge.target!==selected){selected=edge.source;if(embedded)void notify('ontologySelect',selected);}updateDetail();void paintSelection();});
  await graph.render();if(disposed){graph.destroy();return;}await paintSelection();
  if($('graph').clientWidth<600 && graph.getZoom()<.75){await graph.zoomTo(.75,false);await graph.focusElement(selected,false);}
  $('loading').hidden=true;updateZoom();
  rendered=true;if(embedded)void notify('ontologyRendered');
  graph.on('aftertransform',updateZoom);
  $('object').onchange=()=>select($('object').value);
  $('theme').onclick=theme;$('fit').onclick=fit;$('focus').onclick=()=>graph.focusElement(selected,duration());
  const stopFlight=()=>{void graph.zoomTo(graph.getZoom(),false);};
  const motionChanged=()=>{if(quiet())stopFlight();};
  $('quiet').onchange=motionChanged;media.addEventListener('change',motionChanged);
  $('graph').addEventListener('pointerdown',stopFlight);
  $('zoom-in').onclick=async()=>{await graph.zoomTo(Math.min(2.5,graph.getZoom()*1.2),duration());updateZoom();};
  $('zoom-out').onclick=async()=>{await graph.zoomTo(Math.max(.2,graph.getZoom()/1.2),duration());updateZoom();};
  $('all').onclick=()=>{all=!all;$('all').setAttribute('aria-pressed',String(all));$('all').textContent=all?'一跳关系':'全部关系';void paintSelection();};
  $('layout').onchange=changeLayout;$('search').oninput=search;$('search').onkeydown=e=>{if(e.key==='Enter'){const first=matchingNodes(data,$('search').value)[0];if(first)void select(first.id,{focus:true});}};
  for(const name of ['relations','properties'])$(name+'-tab').onclick=()=>{
    for(const panel of ['relations','properties']){$(panel+'-tab').setAttribute('aria-selected',String(panel===name));$(panel+'-panel').hidden=panel!==name;}
  };
  let resizeFrame,previousWidth=$('graph').clientWidth;
  const observer=new ResizeObserver(()=>{cancelAnimationFrame(resizeFrame);resizeFrame=requestAnimationFrame(async()=>{
    if(disposed)return;
    const r=$('graph').getBoundingClientRect();if(r.width<=0 || r.height<=0)return;
    const narrowed=r.width<previousWidth*.8 || (previousWidth>=600 && r.width<600);previousWidth=r.width;
    graph.setSize(r.width,r.height);
    try{
      // Keep the selected object in view when a sidebar or narrow viewport takes space.
      // This changes only the camera: user node positions and the layout stay intact.
      if(narrowed){if(r.width<600 && graph.getZoom()<.75)await graph.zoomTo(.75,false);if(!disposed)await graph.focusElement(selected,false);}
      if(!disposed)updateZoom();
    }catch(error){fail(error);}
  });});observer.observe($('graph'));
  window.addEventListener('pagehide',()=>{disposed=true;observer.disconnect();media.removeEventListener('change',motionChanged);cancelAnimationFrame(resizeFrame);graph.off('aftertransform',updateZoom);graph.destroy();},{once:true});
}
function applyHostState(p){data=p.schema;counts=p.counts;selected=p.selected;dark=p.dark;hostQuiet=p.reducedMotion;textScale=p.textScale;document.documentElement.dataset.theme=dark?'dark':'light';document.documentElement.style.setProperty('--text-scale',textScale);}
function fail(error){if(disposed)return;$('loading').hidden=false;$('loading').classList.add('error');$('loading').textContent='关系图载入失败：'+error.message;console.error(error);if(embedded)void notify('ontologyError',String(error.message));}
const startup=start().catch(fail);
window.ontologyHost={update(value){
  let p;
  try{p=hostPayload(value);}catch(error){fail(error);return Promise.resolve();}
  // Motion preference takes effect immediately, even while an earlier update is drawing.
  pendingQuiet=p.reducedMotion;
  if(p.reducedMotion && rendered && !disposed)void graph.zoomTo(graph.getZoom(),false).catch(fail);
  hostQueue=hostQueue.then(async()=>{await startup;if(disposed || !rendered)return;
    const schemaChanged=JSON.stringify(data)!==JSON.stringify(p.schema);
    const keepEdge=selected===p.selected && p.schema.edges.some(e=>e.id===edgeSelected && (e.source===p.selected || e.target===p.selected));
    applyHostState(p);if(!keepEdge)edgeSelected=null;drawDirectory();
    if(schemaChanged){$('object').replaceChildren();for(const n of data.nodes){const o=el('option',n.data.label);o.value=n.id;$('object').append(o);}graph.setData(structuredClone(data));await graph.render();}
    if(disposed)return;updateDetail();await paintSelection();search();
  }).catch(fail);return hostQueue;
}};
