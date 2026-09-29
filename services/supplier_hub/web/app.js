const PAGE = {
  home: ['工作台', '供应商经验与历史报价，在团队间复用。'],
  suppliers: ['供应商', '查看已共享的供应商资料，结合评价说明判断适用性。'],
  quotes: ['历史报价', '保留原始金额与询价条件，为下一次采购提供参考。'],
  publish: ['发布资料', '选取客户端导出的资料，核对内容后明确发布。'],
  sync: ['同步与交换', '全部已发布资料按配置单向进入内网。'],
  settings: ['服务设置', '查看当前运行配置与连接方式。'],
};
const TYPE = { supplier: '供应商', quotation: '报价', product: '物料', contact: '联系人', project: '项目', project_item: '项目清单', inquiry: '询价' };
const LABEL = {
  name:'名称',code:'编号',model:'型号',brand:'品牌',unit:'单位',category:'分类',tags:'标签',notes:'备注',website:'网站',address:'地址',rating:'评价',rating_note:'评价说明',status:'状态',phone:'电话',email:'邮箱',position:'职务',department:'部门',company:'公司',description:'说明',spec:'规格',specification:'规格说明',material:'材质',price:'原始单价',currency:'币种',tax_mode:'税价口径',tax_rate:'税率',unit_snapshot:'计价单位',min_qty:'起订量',quoted_on:'报价日期',valid_until:'有效期至',capture_mode:'记录方式',price_basis:'价格口径',inquiry_location:'询价地点',inquirer_name:'询价人',inquiry_date:'询价日期',contact_snapshot:'联系人快照',delivery_days:'交货天数',payment_terms:'付款条件',lead_time:'交期',freight:'运费',quantity:'数量',qty:'数量',budget:'预算',tiers:'阶梯报价',supplier_id:'供应商',product_id:'物料',project_id:'项目',project_item_id:'项目清单',inquiry_id:'询价',contact_id:'联系人',supplier_ids:'参与供应商',item_ids:'询价清单',attachment_ids:'附件',location:'地点',due_date:'截止日期',attributes:'关键属性',title:'标题',number:'编号',amount:'金额',tax_included:'含税',is_primary:'主要联系人',price_snapshot:'价格快照',currency_snapshot:'币种快照',tax_mode_snapshot:'税价口径快照',tax_rate_snapshot:'税率快照',project_name:'项目名称',project_code:'项目编号',inquiry_method:'询价方式',source:'来源',contact_name:'联系人',contact_phone:'联系电话',contact_email:'联系邮箱',role:'角色',basis_note:'价格说明',tax_note:'税价说明',reason:'说明',remark:'备注',url:'链接',value:'值',key:'属性',min_quantity:'最低数量',max_quantity:'最高数量',taxed:'含税',untaxed:'未税',unknown:'未注明'
};
Object.assign(LABEL, {aliases:'别名',categories:'经营分类',merged_into:'合并至',wechat:'微信',unit_conversions:'单位换算',spec_class:'参数模板',requirement:'技术要求',type:'类型',level:'级别',customer:'客户',contract_no:'合同编号',contract_amount:'合同金额',leader:'负责人',start_date:'开始日期',end_date:'结束日期',markup_rate:'加价率',inquiry_precision:'询价时间精度',inquired_at:'询价时间',inquiry_utc_offset_minutes:'时区偏移（分钟）',includes:'费用包含项',warranty_months:'质保月数',lead_time_days:'交货天数',extra_cost:'额外费用',deal_price:'成交单价',awarded_on:'成交日期',award_note:'成交说明',price_tiers:'阶梯报价',quotation_id:'参考报价',unit_cost:'成本单价',unit_price:'销售单价',supplier_name:'供应商',product_model:'型号',product_brand:'品牌'});
const ENUM = { inclusive:'含税', exclusive:'未税', included:'含税', excluded:'未税', tax_included:'含税', tax_excluded:'未税', unknown:'未注明', direct:'直接询价', historical:'历史资料', standard:'完整询价', manual:'手工记录', phone:'电话', wechat:'微信', email:'邮件', formal:'正式报价', reference:'参考报价', verbal:'口头报价', unit:'单位价格', total:'总价', estimated:'估算', confirmed:'已确认', draft:'草稿', active:'有效', inactive:'停用', closed:'已结束', open:'进行中', preferred:'优选',caution:'谨慎合作',disabled:'停用',freight:'运费',installation:'安装',commissioning:'调试',training:'培训',date:'日期',minute:'分钟',day:'日期',exact:'准确时间'};
const ENUM_FIELDS = new Set(['tax_mode','tax_mode_snapshot','capture_mode','price_basis','rating','status','includes','inquiry_precision']);
export function displayField(value, field) { return ENUM_FIELDS.has(field) ? (ENUM[value] || String(value)) : String(value); }
export function resolveReference(records, field, id, ownerType) {
  const type = field === 'merged_into' ? ownerType : {supplier_id:'supplier',supplier_ids:'supplier',product_id:'product',project_id:'project',project_item_id:'project_item',item_ids:'project_item',quotation_id:'quotation',inquiry_id:'inquiry',contact_id:'contact'}[field];
  return records.find(record => record.entity_type === type && record.entity_id === id);
}
export function exactPrice(context) {
  return context.price == null ? '未注明' : `${context.currency || '未注明币种'} ${context.price}${context.unit_snapshot ? ` / ${context.unit_snapshot}` : ''}`;
}
export function toDraft(publication) {
  const { publication_id, revision, withdrawn, root, records } = publication;
  return structuredClone({ publication_id, revision, withdrawn, root, records });
}
export function changedVisibility(publication, centerId, latestRevision) {
  if (publication.origin !== centerId || publication.revision !== latestRevision || publication.revision >= 2147483647) throw new Error('只能修改本中心当前版本的发布状态。');
  const draft = toDraft(publication);
  draft.revision += 1;
  draft.withdrawn = !draft.withdrawn;
  return draft;
}
export function parseReport(value) {
  if (!value) return null;
  try { const report = JSON.parse(value); return report && typeof report === 'object' && !Array.isArray(report) ? report : { errors: [String(value)] }; }
  catch { return { errors: [String(value)] }; }
}

if (typeof document !== 'undefined') startAdmin();

function startAdmin() {
  const $ = (selector) => document.querySelector(selector);
  // Appearance remains page-local, just like the connection controls.
  $('#appearance').addEventListener('change', event => {
    const theme = event.target.value;
    if (theme === 'light' || theme === 'dark') document.documentElement.dataset.theme = theme;
    else delete document.documentElement.dataset.theme;
  });
  const main = $('#main');
  const detail = $('#detail-dialog');
  const connect = $('#connection-dialog');
  const state = { page:'home', token:'', epoch:0, pageRun:0, detailRun:0, fileRun:0, status:null, connected:false, controllers:new Set(), filters:{suppliers:{q:'',offset:0,withdrawn:false},quotes:{q:'',offset:0,withdrawn:false}}, draft:null, publishBusy:false, lastReceipt:null };

  // Business data is always text. No HTML parsing, persistent credentials or remote URLs.
  function el(tag, attrs = {}, ...children) {
    const node = document.createElement(tag);
    for (const [key,value] of Object.entries(attrs)) {
      if (key === 'class') node.className = value;
      else if (key.startsWith('on')) node.addEventListener(key.slice(2), value);
      else if (key === 'checked' || key === 'disabled' || key === 'hidden') node[key] = value;
      else node.setAttribute(key, String(value));
    }
    for (const child of children.flat()) if (child != null) node.append(child instanceof Node ? child : document.createTextNode(String(child)));
    return node;
  }
  const button = (text, action, kind='secondary') => el('button', {type:'button',class:kind,onclick:action}, text);
  const text = (value) => value == null || value === '' ? '未注明' : String(value);
  const translated = (value) => ENUM[value] || text(value);
  const source = (origin) => origin === state.status?.center_id ? '本中心' : '外部中心';
  function notice(message, kind='') { const node=$('#notice'); node.textContent=message; node.className=kind; node.hidden=!message; }
  function clearSession() {
    state.epoch++; state.pageRun++; state.detailRun++; state.fileRun++;
    for (const controller of state.controllers) controller.abort();
    state.controllers.clear(); state.token=''; state.status=null; state.connected=false; state.draft=null; state.publishBusy=false; state.lastReceipt=null;
    state.filters={suppliers:{q:'',offset:0,withdrawn:false},quotes:{q:'',offset:0,withdrawn:false}};
    $('#api-token').value=''; $('#detail-content').replaceChildren(); if(detail.open) detail.close();
    main.replaceChildren(); notice(''); $('#connection-state').textContent='未连接';
  }
  function disconnected() {
    main.replaceChildren(el('section',{class:'panel empty-state'},el('h2',{},'连接公司资料中心'),el('p',{},'连接后即可检索共享资料、发布选定内容及查看交换状态。'),button('连接中心',openConnection,'primary')));
  }
  function openConnection() { $('#connection-error').hidden=true; if(!connect.open) connect.showModal(); $('#api-token').focus(); }
  function showError(node, error, retry) {
    if (error.name === 'AbortError') return;
    node.replaceChildren(el('div',{class:'empty-state',role:'alert'},el('h2',{},'暂时无法加载'),el('p',{},error.message),retry ? button('重试',retry) : null));
  }
  async function request(path, options={}) {
    const epoch=state.epoch, controller=new AbortController(); state.controllers.add(controller);
    const timeout=setTimeout(()=>controller.abort(),15000);
    try {
      const response=await fetch(path,{...options,signal:controller.signal,cache:'no-store',credentials:'omit',headers:{...(state.token?{Authorization:`Bearer ${state.token}`} : {}),...(options.body?{'Content-Type':'application/json'}:{})}});
      if(epoch!==state.epoch) throw new DOMException('连接已变更','AbortError');
      if(response.status===401){clearSession();disconnected();openConnection();throw new Error('访问令牌无效或已变更，请重新连接。');}
      if(!response.ok){
        const messages={409:'资料已被其他人更新，或此发布版本内容发生冲突。请刷新后重新核对。',413:'文件超过 1 MiB 限制，请在客户端减少选取范围。',422:'资料格式或关联记录不完整，请检查客户端导出文件。',404:'这份资料不存在或已不可用。',503:'中心暂时繁忙，请稍后重试。'};
        throw new Error(messages[response.status] || `请求失败（${response.status}），请稍后重试。`);
      }
      const data=await response.json();
      if(epoch!==state.epoch) throw new DOMException('连接已变更','AbortError');
      return data;
    } catch(error) {
      if(error.name==='TypeError') throw new Error('无法连接服务，请检查网络和服务运行状态。');
      if(error.name==='AbortError' && epoch===state.epoch) throw new Error('请求超时，请刷新后重试。');
      throw error;
    } finally {clearTimeout(timeout);state.controllers.delete(controller);}
  }
  function diagnostic(publication) {
    return el('details',{},el('summary',{},'诊断信息与原始资料'),el('pre',{},JSON.stringify(publication,null,2)));
  }
  function recordName(record) { return record.data.name || record.data.title || TYPE[record.entity_type] || '关联资料'; }
  function readable(value, records, field='', ownerType='') {
    if(value == null || value==='') return '未注明';
    if(typeof value==='boolean') return value?'是':'否';
    if(Array.isArray(value)) return value.length ? value.map(item=>readable(item,records,field,ownerType)).join('；') : '无';
    if(typeof value==='object') return Object.entries(value).map(([key,item])=>`${LABEL[key]||key}：${readable(item,records,key,ownerType)}`).join('\n');
    if(field.endsWith('_id') || field.endsWith('_ids') || field==='merged_into') { const record=resolveReference(records,field,value,ownerType); return record?recordName(record):'未关联'; }
    return displayField(value, field);
  }
  function recordFields(record, records) {
    const list=el('dl',{class:'definition-list'});
    const missing=el('dl',{class:'definition-list'});
    const priority=['name','product_id','supplier_id','price','currency','unit_snapshot','tax_mode','tax_rate','min_qty','quoted_on','valid_until','rating','rating_note','project_id','inquirer_name','inquiry_date'];
    const rank=key=>priority.includes(key)?priority.indexOf(key):priority.length;
    let missingCount=0;
    for(const [key,value] of Object.entries(record.data).sort(([a],[b])=>rank(a)-rank(b))) {
      const absent=value==null||value===''||(Array.isArray(value)&&!value.length);
      if(absent)missingCount++;
      (absent?missing:list).append(el('dt',{},LABEL[key]||key),el('dd',{class:['price','min_qty','quantity','tax_rate'].includes(key)?'mono':''},readable(value,records,key,record.entity_type)));
    }
    return el('div',{class:'stack'},list,missingCount?el('details',{},el('summary',{},`未填写字段（${missingCount}）`),missing):null);
  }
  function recordsView(records, root) {
    const body=el('div',{});
    const sorted=[...records].sort((a,b)=>Number(b.entity_id===root.entity_id&&b.entity_type===root.entity_type)-Number(a.entity_id===root.entity_id&&a.entity_type===root.entity_type));
    for (const record of sorted) {
      const isRoot=record.entity_id===root.entity_id && record.entity_type===root.entity_type;
      const product=record.entity_type==='quotation'?resolveReference(records,'product_id',record.data.product_id):null;
      const section=el(isRoot?'section':'details',{class:'record-section'},el(isRoot?'h3':'summary',{},`${TYPE[record.entity_type]||record.entity_type} · ${product?recordName(product):recordName(record)}${isRoot?' · 所选资料':''}`),recordFields(record,records));
      body.append(section);
    }
    return body;
  }
  function metric(label,value,note) { return el('div',{class:'metric'},el('p',{class:'muted'},label),el('div',{class:'metric-value'},value??'—'),note?el('p',{class:'muted'},note):null); }
  function pager(offset,count,onPage) {
    const previous=button('上一页',()=>onPage(Math.max(0,offset-20))); previous.disabled=offset===0;
    const next=button('下一页',()=>onPage(offset+20)); next.disabled=count<20 || offset+20>1000000;
    return el('div',{class:'pager'},el('span',{},count?`第 ${offset+1}–${offset+count} 条`:'本页无记录'),previous,next);
  }
  async function loadStatus() {
    const epoch=state.epoch;
    const status=await request('/v1/status');
    if(epoch!==state.epoch) return;
    state.status=status;state.connected=true;$('#connection-state').textContent='中心已连接';
    return status;
  }
  async function navigate(page, focus=false) {
    state.page=PAGE[page]?page:'home';const run=++state.pageRun;
    if(detail.open) detail.close(); state.detailRun++;
    document.querySelectorAll('[data-page]').forEach(node=>{if(node.dataset.page===state.page)node.setAttribute('aria-current','page');else node.removeAttribute('aria-current');});
    [$('#page-title').textContent,$('#page-subtitle').textContent]=PAGE[state.page];
    document.title=`${PAGE[state.page][0]} · 公司资料中心`;
    if(focus)main.focus();
    if(!state.connected){disconnected();return;}
    main.replaceChildren(el('div',{class:'empty-state',role:'status'},'正在加载…'));
    try {
      if(state.page==='suppliers'||state.page==='quotes'){await renderList(run);return;}
      if(state.page==='publish'){renderPublish();return;}
      await loadStatus(); if(run!==state.pageRun)return;
      if(state.page==='home') renderHome();
      if(state.page==='sync') renderSync();
      if(state.page==='settings') renderSettings();
    }catch(error){if(run===state.pageRun)showError(main,error,()=>navigate(state.page));}
  }
  function renderHome() {
    const s=state.status;
    const tasks=el('section',{class:'panel'},el('div',{class:'panel-header'},el('h2',{},'常用工作'),el('span',{class:'muted'},'明确发布 · 随时查阅')),
      el('div',{class:'panel-body stack'},el('div',{class:'actions'},button('查供应商',()=>navigate('suppliers',true),'primary'),button('参考历史报价',()=>navigate('quotes',true)),button('发布资料',()=>navigate('publish',true))),el('p',{class:'muted'},'供应商评价与报价条件均保留原始记录。先核对适用条件，再用于当前项目。')));
    const exchange=el('section',{class:'panel'},el('div',{class:'panel-header'},el('h2',{},'同步与交换'),button('查看状态',()=>navigate('sync',true),'quiet')),el('div',{class:'panel-body stack'},el('p',{},s.sync_enabled?`已开启 · ${s.sync_role==='export'?'向指定目录投递':'从指定目录接收'}`:'双网同步未开启'),el('p',{class:'muted'},s.sync_enabled?'已发布资料自动参加交换。单向链路没有远端回执。':'中心内的发布与检索正常使用。开启后会补投关闭期间的已发布资料。')));
    main.replaceChildren(el('div',{class:'ledger'},metric('共享资料',s.store.publication_count,'含已撤回资料'),metric('保留版本',s.store.revision_count,'支持历史追溯'),metric('接收包',s.store.received_packages,'接收端累计记录'),metric('已投递版本',s.store.exported_versions,'本地投递，不代表远端收到')),el('div',{class:'stack'},tasks,exchange));
  }
  async function renderList(run) {
    const page=state.page, filter=state.filters[page], kind=page==='suppliers'?'supplier':'quotation';
    const search=el('input',{id:'list-search',type:'search',placeholder:kind==='supplier'?'搜索名称、评价说明或关键词':'搜索物料、供应商或询价条件',maxlength:200,'aria-label':'搜索共享资料',value:filter.q});
    const include=el('input',{type:'checkbox',checked:filter.withdrawn,onchange:()=>{filter.withdrawn=include.checked;filter.offset=0;navigate(page);}});
    const form=el('form',{class:'toolbar',onsubmit:event=>{event.preventDefault();filter.q=search.value.trim();filter.offset=0;navigate(page);}},search,el('button',{type:'submit',class:'primary'},'搜索'),el('label',{},include,'包含已撤回'),el('span',{class:'muted'},'Ctrl / ⌘ K 搜索'));
    const results=el('section',{class:'panel','aria-busy':'true'},el('div',{class:'empty-state'},'正在检索…'));main.replaceChildren(form,results);
    const params=new URLSearchParams({kind,q:filter.q,limit:'20',offset:String(filter.offset),include_withdrawn:String(filter.withdrawn)});
    try {
      const response=await request(`/v1/publications?${params}`);if(run!==state.pageRun)return;
      results.removeAttribute('aria-busy');
      const items=response.items;
      if(!items.length){results.replaceChildren(el('div',{class:'empty-state'},el('h2',{},filter.q?'没有找到匹配资料':'暂无共享资料'),el('p',{},filter.q?'调整关键词或包含已撤回资料后再试。':'从客户端导出选定资料，在「发布资料」中核对并共享。'),button('发布资料',()=>navigate('publish',true))),pager(filter.offset,0,offset=>{filter.offset=offset;navigate(page);}));return;}
      const headings=kind==='supplier'?['供应商','评价','评价说明','来源','状态']:['物料 / 报价','原始单价','报价条件','询价日期','来源'];
      const tbody=el('tbody');
      for(const item of items){
        const c=item.context;
        const name=el('td',{},button(item.title||'未命名资料',()=>openDetail(item),'row-link'),kind==='quotation'?el('div',{class:'muted'},[c.supplier_name,c.product_model].filter(Boolean).join(' · ')):null,item.withdrawn?el('div',{},el('span',{class:'badge warning'},'已撤回')):null);
        const cells=kind==='supplier'?[name,el('td',{},translated(c.rating)),el('td',{},text(c.rating_note)),el('td',{},source(item.origin)),el('td',{},el('span',{class:`badge ${item.withdrawn?'warning':'blue'}`},item.withdrawn?'已撤回':'已共享'))]:[name,el('td',{class:'number'},el('div',{class:'price'},exactPrice(c))),el('td',{},translated(c.tax_mode),el('div',{class:'muted'},`起订量 ${text(c.min_qty)} · 有效期 ${text(c.valid_until)}`)),el('td',{},text(c.quoted_on||c.inquiry_date)),el('td',{},source(item.origin))];
        tbody.append(el('tr',{},...cells));
      }
      results.replaceChildren(el('div',{class:'table-wrap',tabindex:'0',role:'region','aria-label':`${PAGE[page][0]}列表，可横向滚动`},el('table',{class:'data-table'},el('thead',{},el('tr',{},...headings.map((label,index)=>el('th',{scope:'col',class:kind==='quotation'&&index===1?'number':''},label)))),tbody)),pager(filter.offset,items.length,offset=>{filter.offset=offset;navigate(page);}));
    }catch(error){if(run===state.pageRun)showError(results,error,()=>navigate(page));}
  }
  async function openDetail(item, revision=null) {
    const run=++state.detailRun,epoch=state.epoch;
    const target=$('#detail-content');target.replaceChildren(el('div',{class:'empty-state'},'正在读取资料…'));if(!detail.open)detail.showModal();
    const path=`/v1/publications/${encodeURIComponent(item.origin)}/${encodeURIComponent(item.publication_id)}`;
    try {
      const latest=await request(path);
      const publication=revision==null||revision===latest.revision?latest:await request(`${path}?revision=${revision}`);
      if(run!==state.detailRun||epoch!==state.epoch||!detail.open)return;
      const root=publication.records.find(r=>r.entity_id===publication.root.entity_id&&r.entity_type===publication.root.entity_type);
      const product=resolveReference(publication.records,'product_id',root?.data.product_id,root?.entity_type);
      const title=root?.data.name||product?.data.name||item.title||'资料详情';
      const heading=el('div',{},el('p',{class:'eyebrow'},TYPE[publication.root.entity_type]||'共享资料'),el('h2',{},title),el('p',{class:'muted'},`${source(publication.origin)} · 第 ${publication.revision} 次发布${publication.revision!==latest.revision?' · 历史内容':''}`));
      const history=el('section',{class:'stack'},el('h3',{},'发布历史'));
      const historyBody=el('div');history.append(historyBody);
      async function loadHistory(offset=0){
        historyBody.replaceChildren(el('p',{class:'muted'},'正在读取历史…'));
        try{const result=await request(`${path}/history?limit=20&offset=${offset}`);if(run!==state.detailRun)return;
          historyBody.replaceChildren(el('div',{class:'history-list'},...result.items.map(version=>button(`第 ${version.revision} 次${version.withdrawn?' · 撤回':''}`,()=>openDetail(item,version.revision),version.revision===publication.revision?'selected':'secondary'))),pager(offset,result.items.length,loadHistory));
        }catch(error){if(run===state.detailRun)showError(historyBody,error,()=>loadHistory(offset));}
      }
      const controls=el('div',{class:'stack'});
      if(publication.origin===state.status.center_id && publication.revision===latest.revision && latest.revision<2147483647){
        const action=publication.withdrawn?'恢复共享':'撤回共享';
        const confirmArea=el('div',{hidden:true,class:'preview stack'},el('p',{},publication.withdrawn?'恢复后，该资料会重新出现在共享检索中。':'撤回后，该资料从默认检索中隐藏；历史记录保留。开启交换时，撤回状态也会投递。'));
        const confirm=button(`确认${action}`,async()=>{
          confirm.disabled=true;
          try {const draft=changedVisibility(publication,state.status.center_id,latest.revision);await request('/v1/publications',{method:'POST',body:JSON.stringify(draft)});if(run!==state.detailRun)return;notice(`${action}完成。`);detail.close();await navigate(state.page);}
          catch(error){if(run===state.detailRun){notice(error.message,'error');confirmArea.replaceChildren(el('p',{class:'error'},error.message),button('重新读取资料',()=>openDetail(item)));}}
        },publication.withdrawn?'primary':'danger');
        confirmArea.append(el('div',{class:'actions'},confirm,button('取消',()=>{confirmArea.hidden=true;})));
        controls.append(button(action,()=>{confirmArea.hidden=false;confirm.focus();},publication.withdrawn?'secondary':'danger'),confirmArea);
      }
      target.replaceChildren(heading,publication.withdrawn?el('p',{class:'warning'},'此发布版本已撤回，不在默认检索中展示。'):nullSafe(),controls,recordsView(publication.records,publication.root),history,diagnostic(publication));
      await loadHistory();
    }catch(error){if(run===state.detailRun)showError(target,error,()=>openDetail(item,revision));}
  }
  function nullSafe(){return document.createTextNode('');}
  function renderPublish() {
    const run=++state.fileRun;
    const output=el('div',{class:'stack'});
    const input=el('input',{type:'file',accept:'.json,application/json',id:'publication-file',disabled:state.publishBusy});
    const introduction=el('section',{class:'panel'},el('div',{class:'panel-header'},el('h2',{},'发布选定资料'),el('span',{class:'badge'},'预览后确认')),
      el('div',{class:'panel-body stack'},el('ol',{class:'step-list'},el('li',{},'从客户端选取供应商或报价，导出中心端资料文件。'),el('li',{},'在这里核对正文、关联记录和共享范围。'),el('li',{},'确认发布；若已开启双网交换，资料会自动投递。')),el('label',{class:'field',for:'publication-file'},'选择资料文件（JSON，最大 1 MiB）',input),el('p',{class:'muted'},'选文件只做校验与预览。只有点击「确认发布」才会写入共享库。')));
    main.replaceChildren(el('div',{class:'stack'},introduction,output));
    input.addEventListener('change',async()=>{
      const requestRun=++state.fileRun,epoch=state.epoch;state.draft=null;state.lastReceipt=null;output.replaceChildren();
      const file=input.files[0];if(!file)return;
      try{
        if(file.size>1024*1024)throw new Error('文件超过 1 MiB，请减少客户端选取范围。');
        const body=await file.text();if(requestRun!==state.fileRun||epoch!==state.epoch)return;
        let draft;try{draft=JSON.parse(body);}catch{throw new Error('无法读取 JSON，请选择客户端导出的中心端资料文件。');}
        output.replaceChildren(el('p',{class:'muted',role:'status'},'正在校验资料与关联范围…'));
        const preview=await request('/v1/publications/preview',{method:'POST',body:JSON.stringify(draft)});
        if(requestRun!==state.fileRun||epoch!==state.epoch)return;
        state.draft=preview.draft;drawPreview(preview,output,input,requestRun);
      }catch(error){if(requestRun===state.fileRun && epoch===state.epoch)output.replaceChildren(el('p',{class:'error',role:'alert'},error.message));}
    });
    if(state.publishBusy)output.replaceChildren(el('p',{class:'callout',role:'status'},'正在发布，请勿重复提交。完成后会显示本中心回执。'));
    else if(state.lastReceipt)renderReceipt(output);
    else if(state.draft){drawPreview({draft:state.draft,title:'待确认资料',record_count:state.draft.records.length},output,input,run);}
  }
  function renderReceipt(output) {
    const result=state.lastReceipt;
    output.replaceChildren(el('section',{class:'panel panel-body stack'},el('h2',{},result.duplicate?'此资料已发布':'发布完成'),el('p',{class:'success'},result.duplicate?'已确认相同内容，未重复创建发布记录。':'资料已写入本中心共享库。'),el('p',{class:'muted'},state.status.sync_enabled?'已纳入本地交换任务；这里不代表远端已经接收。':'当前未开启双网同步。'),button('查看已发布资料',()=>openDetail(result))));
  }
  function drawPreview(preview,output,input,run){
    const draft=preview.draft,epoch=state.epoch;
    const counts={};for(const record of draft.records)counts[TYPE[record.entity_type]||record.entity_type]=(counts[TYPE[record.entity_type]||record.entity_type]||0)+1;
    const accepted=el('input',{type:'checkbox'});
    const submit=button('确认发布',async()=>{
      if(!accepted.checked||state.publishBusy)return;state.publishBusy=true;submit.disabled=true;input.disabled=true;
      try{
        const result=await request('/v1/publications',{method:'POST',body:JSON.stringify(draft)});
        if(epoch!==state.epoch)return;
        state.draft=null;state.lastReceipt={...result,title:preview.title};notice(result.duplicate?'已确认此资料此前已发布。':'资料发布完成。');
      }catch(error){if(epoch===state.epoch)notice(error.message,'error');}
      finally{if(epoch===state.epoch){state.publishBusy=false;if(state.page==='publish')renderPublish();}}
    },'primary');submit.disabled=true;
    accepted.addEventListener('change',()=>{submit.disabled=!accepted.checked||state.publishBusy;});
    output.replaceChildren(el('section',{class:'preview stack'},el('div',{class:'panel-header'},el('h2',{},preview.title),el('span',{class:'badge blue'},'待确认预览')),el('p',{},`共 ${preview.record_count} 条记录 · ${Object.entries(counts).map(([key,value])=>`${key} ${value}`).join(' / ')}`),draft.withdrawn?el('p',{class:'warning'},'此文件请求撤回共享。发布后会隐藏当前资料，历史保留。'):null,el('p',{class:'muted'},'请同时检查关联供应商、项目与询价正文。联系人快照、询价人及备注也会共享。'),recordsView(draft.records,draft.root),el('label',{class:'checkbox-row'},accepted,'我已核对正文及关联范围，同意将这些资料发布到公司共享库。'),el('div',{class:'actions'},submit),diagnostic(draft)));
  }
  function renderSync(){
    const s=state.status,report=parseReport(s.store.tasks.directory_exchange);
    const diagram=el('div',{class:'flow'},el('div',{class:'flow-node'},'来源中心',el('small',{},'发布资料 → 投递目录')),el('span',{class:'flow-arrow','aria-hidden':'true'},'→'),el('div',{class:'flow-node'},'既有单向搬运',el('small',{},'定期复制指定目录文件')),el('span',{class:'flow-arrow','aria-hidden':'true'},'→'),el('div',{class:'flow-node'},'内网中心',el('small',{},'接收目录 → 校验入库')));
    const panel=el('section',{class:'panel'},el('div',{class:'panel-header'},el('h2',{},'单向目录交换'),el('span',{class:`badge ${s.sync_enabled?'blue':''}`},s.sync_enabled?'已开启':'未开启')),diagram,el('div',{class:'panel-body stack'},el('p',{class:'callout warning'},'严格单向链路没有回程。来源端的「已投递」只代表文件已写入本地目录，不能证明内网已经收到。'),el('p',{},`本中心角色：${s.sync_role==='export'?'投递端':'接收端'} · ${s.sync_enabled?`每 ${s.sync_interval_seconds} 秒执行`:'当前不执行目录任务'}`)));
    const last=el('section',{class:'panel'},el('div',{class:'panel-header'},el('h2',{},'最近一次本地任务'),button('刷新状态',()=>navigate('sync'),'quiet')));
    if(report){last.append(el('div',{class:'ledger'},...['scanned','exported','imported','duplicates','failed'].map((key,index)=>metric(['检查文件','本次投递','本次导入','重复记录','失败条目'][index],report[key]??'—'))));if(report.errors?.length)last.append(el('div',{class:'panel-body stack'},...report.errors.map(error=>el('p',{class:'error'},error))));}
    else last.append(el('div',{class:'empty-state'},s.sync_enabled?'尚无本地任务结果，请稍后刷新。':'未开启交换，尚无任务结果。'));
    main.replaceChildren(el('div',{class:'stack'},panel,last,el('p',{class:'muted'},'开启、角色及目录通过服务配置修改并重启生效。关闭不会删除已投递文件。目录文件与历史版本需要按容量制定保留策略。')));
  }
  function renderSettings(){
    const s=state.status,list=el('dl',{class:'definition-list'});
    for(const [label,value] of [['管理端地址',location.origin],['访问方式',s.authentication_required?'访问令牌':'本机直接访问'],['双网交换',s.sync_enabled?'已开启':'未开启'],['交换角色',s.sync_role==='export'?'向指定目录投递':'从指定目录接收'],['执行间隔',`${s.sync_interval_seconds} 秒`],['重发间隔',`${s.resend_seconds} 秒`],['单次处理上限',`${s.max_files_per_tick} 个文件`]])list.append(el('dt',{},label),el('dd',{},value));
    main.replaceChildren(el('div',{class:'stack'},el('section',{class:'panel'},el('div',{class:'panel-header'},el('h2',{},'当前运行配置'),el('span',{class:'badge'},'只读')),el('div',{class:'panel-body stack'},list,el('p',{class:'callout'},'交换开关与目录由服务配置文件管理，修改后重启生效。此页面展示当前实际生效值。'),button('管理当前连接',openConnection))),el('section',{class:'panel'},el('div',{class:'panel-header'},el('h2',{},'数据与恢复')),el('div',{class:'panel-body stack'},el('p',{},'中心保留发布版本与接收账本。备份由服务端命令执行，恢复前应停止服务并保留旧库。'),el('p',{class:'muted'},'附件交换与按技术要求自主选型尚未开放。已发布报价中的条件与评价仍应由使用者核对。'))),el('details',{},el('summary',{},'诊断信息'),el('pre',{},JSON.stringify({center_id:s.center_id,trusted_origin:s.trusted_origin,remote_receipt_available:s.remote_receipt_available},null,2)))));
  }
  document.querySelectorAll('[data-page]').forEach(node=>node.addEventListener('click',()=>navigate(node.dataset.page,true)));
  $('#refresh-button').addEventListener('click',()=>navigate(state.page));
  $('#connection-button').addEventListener('click',openConnection);
  $('#detail-close').addEventListener('click',()=>detail.close());
  detail.addEventListener('close',()=>{state.detailRun++;$('#detail-content').replaceChildren();});
  $('#connection-close').addEventListener('click',()=>{connect.close();$('#api-token').value='';});
  connect.addEventListener('close',()=>{$('#api-token').value='';});
  $('#disconnect-button').addEventListener('click',()=>{clearSession();connect.close();disconnected();});
  $('#connection-form').addEventListener('submit',async(event)=>{
    event.preventDefault();const token=$('#api-token').value.trim();clearSession();state.token=token;const epoch=state.epoch;
    const submit=$('#connect-submit');submit.disabled=true;$('#connection-error').hidden=true;
    try{await loadStatus();if(epoch!==state.epoch)return;connect.close();navigate(state.page);}
    catch(error){if(error.name!=='AbortError'){$('#connection-error').textContent=error.message;$('#connection-error').hidden=false;disconnected();}}
    finally{submit.disabled=false;$('#api-token').value='';}
  });
  document.addEventListener('keydown',event=>{if((event.ctrlKey||event.metaKey)&&event.key.toLowerCase()==='k'&&!detail.open&&!connect.open){const search=$('#list-search');if(search){event.preventDefault();search.focus();search.select();}}});
  loadStatus().then(()=>navigate(state.page)).catch(error=>{if(!connect.open)showError(main,error,()=>location.reload());});
}
