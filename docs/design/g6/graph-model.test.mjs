import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {neighborhood, matchingNodes, validateSchema, groupOf} from './graph-model.mjs';
const data=JSON.parse(readFileSync(new URL('./schema.json',import.meta.url)));
test('actual ontology has valid and fully grouped nodes',()=>{
  assert.equal(validateSchema(data),data);
  assert.equal(data.nodes.length,11);
  assert(data.nodes.every(n=>groupOf(n.id)));
});
test('supplier and product self references survive neighborhood filtering',()=>{
  for(const id of ['supplier','product'])
    assert(neighborhood(data,id).edges.some(e=>e.source===id && e.target===id));
});
test('parallel relations keep independent ids and never aggregate silently',()=>{
  const sample={nodes:[{id:'a'},{id:'b'}],edges:[
    {id:'a.first',source:'a',target:'b'}, {id:'a.second',source:'a',target:'b'}]};
  assert.equal(neighborhood(sample,'a').edges.length,2);
  assert.equal(neighborhood(data,'supplier',true).edges.length,data.edges.length);
});
test('Chinese and technical names search without mutating schema',()=>{
  const before=JSON.stringify(data);
  assert(matchingNodes(data,'物料').length>=1);
  assert.equal(matchingNodes(data,'  SUPPLIER ')[0].id,'supplier');
  assert.equal(matchingNodes(data,'does-not-exist').length,0);
  assert.equal(JSON.stringify(data),before);
});
