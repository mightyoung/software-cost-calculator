// Local design-review fixtures only. Never accesses a database or real hub.
// node services/supplier_hub/web/review-server.mjs [port]
import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';

const port = Number(process.argv[2] || 8782);
const supplier = {entity_type:'supplier',entity_id:'supplier-review',data:{name:'华东精密设备供应商 · 设计验收样本',rating:'preferred',rating_note:'优先用于通用机电物料；特殊工况请重新核对技术要求。',phone:'仅用于展示',notes:'这里的记录均为设计验收样本，不来自业务数据库。'}};
const product = {entity_type:'product',entity_id:'product-review',data:{name:'不锈钢离心泵',model:'CP-240-LONG-MODEL-REVIEW',brand:'设计样本',unit:'台'}};
const quotation = {entity_type:'quotation',entity_id:'quote-review',data:{supplier_id:supplier.entity_id,product_id:product.entity_id,price:'123456789012.123456',currency:'CNY',unit_snapshot:'台',tax_mode:'included',tax_rate:'13',min_qty:'2',quoted_on:'2026-09-29',valid_until:'2026-12-31'}};
const publications = [
  {origin:'review-center',publication_id:'review-supplier',revision:1,withdrawn:false,root:{entity_type:'supplier',entity_id:supplier.entity_id},records:[supplier]},
  {origin:'review-center',publication_id:'review-quote',revision:1,withdrawn:false,root:{entity_type:'quotation',entity_id:quotation.entity_id},records:[quotation,product,supplier]},
];
const summary = p => ({...p,title:p.root.entity_type==='supplier'?supplier.data.name:product.data.name,context:p.root.entity_type==='supplier'?supplier.data:{...quotation.data,supplier_name:supplier.data.name,product_model:product.data.model}});
const status = {center_id:'review-center',authentication_required:false,sync_enabled:true,sync_role:'export',sync_interval_seconds:30,resend_seconds:3600,max_files_per_tick:100,trusted_origin:null,remote_receipt_available:false,store:{publication_count:2,revision_count:2,received_packages:0,exported_versions:1,tasks:{directory_exchange:JSON.stringify({scanned:2,exported:1,imported:0,duplicates:0,failed:1,errors:['设计验收样本：目标目录暂不可用，请核对挂载状态后重试。']})}}};
const server = createServer(async (request,response) => {
  const url = new URL(request.url,'http://localhost');
  const send = (code,body,type='application/json') => {response.writeHead(code,{'Content-Type':`${type}; charset=utf-8`,'Cache-Control':'no-store'});response.end(type==='application/json'?JSON.stringify(body):body);};
  try {
    if(url.pathname==='/review') return send(200,'<!doctype html><title>390px / 140% 设计验收</title><p>仅设计样本 · 390px 视口 / 140% 文字</p><iframe title="手机布局验收" src="/admin/?scale=1.4" style="width:390px;height:900px;border:1px solid #aaa"></iframe>','text/html');
    if(url.pathname==='/admin'||url.pathname==='/admin/') {
      let html = await readFile(new URL('./index.html',import.meta.url),'utf8');
      if(url.searchParams.get('scale')==='1.4') html=html.replace('</head>','<style>html{font-size:140%}</style></head>');
      html=html.replace('<main id="main"','<p class="callout">设计验收样本 · 无真实业务数据；发布操作仅修改此临时进程内的样本。</p><main id="main"');
      return send(200,html,'text/html');
    }
    if(url.pathname==='/admin/app.js'||url.pathname==='/admin/styles.css') return send(200,await readFile(new URL(url.pathname.endsWith('.js')?'./app.js':'./styles.css',import.meta.url),'utf8'),url.pathname.endsWith('.js')?'text/javascript':'text/css');
    if(url.pathname==='/v1/status') return send(200,status);
    if(request.method==='GET'&&url.pathname==='/v1/publications') {
      const q=(url.searchParams.get('q')||'').toLowerCase();
      return send(200,{items:publications.filter(p=>p.root.entity_type===url.searchParams.get('kind')&&(url.searchParams.get('include_withdrawn')==='true'||!p.withdrawn)).map(summary).filter(p=>JSON.stringify(p).toLowerCase().includes(q))});
    }
    if(request.method==='GET'&&url.pathname.startsWith('/v1/publications/')) {
      const p=publications.find(p=>url.pathname.split('/')[4]===p.publication_id);
      if(!p)return send(404,{error:'fixture not found'});
      return send(200,url.pathname.endsWith('/history')?{items:[{revision:p.revision,withdrawn:p.withdrawn}]}:p);
    }
    if(request.method==='POST'&&url.pathname.startsWith('/v1/publications')) {
      let body='';for await(const chunk of request) body+=chunk;
      const draft=JSON.parse(body);
      if(!draft.root||!Array.isArray(draft.records))return send(422,{error:'invalid fixture draft'});
      if(url.pathname.endsWith('/preview'))return send(200,{draft,title:'设计验收发布预览',record_count:draft.records.length});
      const old=publications.find(p=>p.publication_id===draft.publication_id);
      if(old)Object.assign(old,draft);else publications.push({...draft,origin:'review-center'});
      return send(200,{origin:'review-center',publication_id:draft.publication_id,revision:draft.revision,duplicate:false});
    }
    return send(404,{error:'not found'});
  } catch {return send(400,{error:'invalid fixture request'});}
});
server.listen(port,'127.0.0.1',()=>console.log(`Design fixtures: http://127.0.0.1:${port}/admin/ | narrow review: http://127.0.0.1:${port}/review`));
