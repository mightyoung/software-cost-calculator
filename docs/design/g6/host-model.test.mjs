import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {hostPayload} from './host-model.mjs';
const schema=JSON.parse(await readFile(new URL('./schema.json',import.meta.url)));
const value={version:1,schema,counts:{supplier:13},selected:'supplier',dark:false,reducedMotion:true,textScale:1.4};
test('host boundary preserves real counts, selected object and accessibility',()=>{
  const p=hostPayload(value);assert.equal(p.counts.supplier,13);assert.equal(p.counts.product,undefined);
  assert.equal(p.selected,'supplier');assert.equal(p.textScale,1.4);assert.equal(p.reducedMotion,true);
  assert.equal(p.schema,schema);assert.deepEqual(value.counts,{supplier:13});
});
test('host rejects invalid versions, selections, counts and themes before mutation',()=>{
  for(const override of [{version:2},{selected:'missing'},{counts:{supplier:-1}},{counts:{supplier:1.5}},{dark:'false'},{reducedMotion:null}])assert.throws(()=>hostPayload({...value,...override}));
});
test('text scaling is bounded for legible embedded layout',()=>{
  assert.equal(hostPayload({...value,textScale:99}).textScale,2);
  assert.equal(hostPayload({...value,textScale:.2}).textScale,1);
});
test('packaged HTML is offline classic script with host bridge, not an ESM fetch entrypoint',async()=>{
  const html=await readFile(new URL('../../../apps/supplier_app/assets/ontology_graph/index.html',import.meta.url),'utf8');
  assert.ok(html.includes('<script src="g6.min.js"></script>'));
  assert.ok(!html.includes('type="module"'));assert.ok(!html.includes('src="http'));
  assert.ok(html.includes('window.ONTOLOGY_ASSETS='));assert.ok(html.includes('flutterInAppWebViewPlatformReady'));
  assert.ok(html.includes("notify('ontologyRendered')"));assert.ok(Buffer.byteLength(html)<2*1024*1024);
});
