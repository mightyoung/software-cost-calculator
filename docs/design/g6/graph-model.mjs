export const groups = [
  {name:'供应商与报价', ids:['supplier','contact','quotation'], color:'#677DA1'},
  {name:'物料与物料参数', ids:['product','product_param'], color:'#5C8B86'},
  {name:'项目与询价', ids:['project','project_item','inquiry'], color:'#92734F'},
  {name:'技术要求', ids:['spec_request','spec_item','spec_response'], color:'#84709B'},
];
export const groupOf = id => groups.find(g => g.ids.includes(id));
export function neighborhood(data, id, all = false) {
  const edges = data.edges.filter(e => all || e.source === id || e.target === id);
  return {edges, nodes:new Set([id, ...edges.flatMap(e => [e.source,e.target])])};
}
export function matchingNodes(data, query) {
  const q = query.trim().toLocaleLowerCase();
  return data.nodes.filter(n => `${n.id} ${n.data.label}`.toLocaleLowerCase().includes(q));
}
export function validateSchema(data) {
  if(data.schemaVersion !== 1) throw new Error('Unsupported schema version');
  const ids = new Set(data.nodes.map(n => n.id));
  if(ids.size !== data.nodes.length) throw new Error('Duplicate nodes');
  const edges = new Set();
  for(const edge of data.edges) {
    if(edges.has(edge.id) || !ids.has(edge.source) || !ids.has(edge.target)) throw new Error('Invalid edge');
    edges.add(edge.id);
  }
  return data;
}
