'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { Case } = require('./lib');
// Только автономные проверки. Файлы с БД запускает tests/run.js.
for (const file of ['130-inputs', '140-calculations', '150-service-boundaries', '170-backup']) {
  for (const [name, fn] of Object.entries(require(`./checks/${file}`))) {
    test(`${file}: ${name}`, async () => {
      const item = new Case(name);
      await fn(item);
      assert.deepEqual(item.failures, []);
    });
  }
}
