import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { exactPrice, changedVisibility, toDraft, parseReport, displayField, resolveReference } from './app.js';

test('admin navigation uses the same local icon geometry as the application', async () => {
  const html = await readFile(new URL('./index.html', import.meta.url), 'utf8');
  const catalog = JSON.parse(await readFile(new URL('../../../docs/design/icons/catalog.json', import.meta.url), 'utf8'));
  for (const id of ['workspace','supplier','quotation','upload','exchange','settings','refresh','close']) {
    const icon = catalog.find(entry => entry.id === id);
    assert.ok(html.includes(`data-icon="${id}"`), `missing ${id}`);
    assert.ok(html.includes(`d="${icon.path}"`), `geometry drift: ${id}`);
  }
  assert.doesNotMatch(html, /[▤▥≡⇄⚙]/u);
});

test('admin surfaces expose neutral themes, scaling, local table scroll and reduced motion', async () => {
  const css = await readFile(new URL('./styles.css', import.meta.url), 'utf8');
  assert.match(css, /--canvas:#f7f8fa/i);
  assert.match(css, /--canvas:#131211/i);
  assert.match(css, /data-theme=dark/);
  assert.match(css, /data-theme=light/);
  assert.match(css, /font:0\.875rem/);
  assert.match(css, /prefers-reduced-motion/);
  assert.match(css, /\.table-wrap\{overflow:auto/);
});

test('preserves decimal price without binary floating point conversion', () => {
  assert.equal(exactPrice({price:'123456789012.123456',currency:'CNY',unit_snapshot:'台'}),'CNY 123456789012.123456 / 台');
  assert.equal(exactPrice({price:'0.000001',currency:'USD'}),'USD 0.000001');
});
test('withdrawal is limited to current own-origin revision and keeps immutable input', () => {
  const p={origin:'source',publication_id:'id',revision:2,withdrawn:false,root:{entity_type:'supplier',entity_id:'s'},records:[{data:{name:'原名'}}]};
  assert.throws(()=>changedVisibility(p,'other',2));
  assert.throws(()=>changedVisibility(p,'source',3));
  const next=changedVisibility(p,'source',2);
  assert.equal(next.revision,3);assert.equal(next.withdrawn,true);assert.equal('origin' in next,false);
  next.records[0].data.name='changed';assert.equal(p.records[0].data.name,'原名');
  assert.equal(toDraft(p).revision,2);
});
test('handles persisted plain-text exchange failures without inventing success', () => {
  assert.equal(parseReport(undefined),null);
  assert.deepEqual(parseReport('disk full'),{errors:['disk full']});
  assert.deepEqual(parseReport('{"failed":2,"errors":["半文件"]}'),{failed:2,errors:['半文件']});
});
test('translates controlled fields without changing supplier names or free-form notes', () => {
  assert.equal(displayField('preferred','rating'),'优选');
  assert.equal(displayField('preferred','name'),'preferred');
  assert.equal(displayField('included','notes'),'included');
});
test('reference identity includes entity type even when UUIDs coincide', () => {
  const supplier={entity_type:'supplier',entity_id:'same',data:{name:'供应商'}};
  const product={entity_type:'product',entity_id:'same',data:{name:'物料'}};
  assert.equal(resolveReference([product,supplier],'supplier_id','same'),supplier);
  assert.equal(resolveReference([supplier,product],'product_id','same'),product);
  assert.equal(resolveReference([product,supplier],'merged_into','same','supplier'),supplier);
});
