'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { Case } = require('./lib');
for (const [name, fn] of Object.entries(require('./checks/120-audit'))) {
  test(name, async () => {
    const item = new Case(name);
    await fn(item);
    assert.deepEqual(item.failures, []);
  });
}
