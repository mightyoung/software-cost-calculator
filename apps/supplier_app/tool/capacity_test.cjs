// Node's VM supplies only capacity API inputs; this tests the actual bridge.
const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const source = fs.readFileSync(path.join(__dirname, '../web/supplier_platform.js'), 'utf8');
async function sample(storage) {
  const context = {window: {}, navigator: {storage}};
  vm.runInNewContext(source, context);
  return JSON.parse(await context.window.supplierPlatform.capacityEstimate());
}
test('usage and quota are estimates, with negative remainder clamped to zero', async () => {
  assert.equal((await sample({estimate: async () => ({usage: 10, quota: 20})})).available, 10);
  assert.equal((await sample({estimate: async () => ({usage: 20, quota: 10})})).available, 0);
});
test('unavailable, rejected, and malformed estimates retain unknown status', async () => {
  assert.equal((await sample(undefined)).status, 'unsupported');
  const rejected = await sample({estimate: async () => {throw new Error('sampling failed');}});
  assert.equal(rejected.status, 'failed');
  assert.match(rejected.diagnostic, /sampling failed/);
  for (const value of [{}, {usage: -1, quota: 10}, {usage: 0.5, quota: 10},
    {usage: 0, quota: Infinity}, {usage: 0, quota: 9007199254740992}]) {
    const result = await sample({estimate: async () => value});
    assert.equal(result.status, 'invalid');
    assert.equal(result.available, undefined);
  }
});
