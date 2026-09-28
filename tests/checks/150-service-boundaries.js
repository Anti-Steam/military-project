'use strict';
const assert = require('node:assert/strict');
const org = require('../../services/app/modules/org/service');
const orgQueries = require('../../services/app/modules/org/queries');
const personnel = require('../../services/app/modules/personnel/service');
const queries = require('../../services/app/modules/personnel/queries');
const db = require('../../services/app/db/pool');

// Подменяются только внешние зависимости; восстановление обязательно даже при падении.
async function patched(target, replacements, run) {
  const old = Object.fromEntries(Object.keys(replacements).map(key => [key, target[key]]));
  Object.assign(target, replacements);
  try { await run(); } finally { Object.assign(target, old); }
}
exports.subdivisionScope = async t => {
  await patched(orgQueries, { subtreeIds: async id => {
    t.is(id, 10, 'Область строится от назначенного подразделения');
    return [10, 11];
  } }, async () => {
    t.is(await org.inScope({ scope_unit_id: 10 }, '11'), true, 'Потомок доступен');
    t.is(await org.inScope({ scope_unit_id: 10 }, 12), false, 'Сосед недоступен');
    await assert.rejects(org.assertInScope({ scope_unit_id: 10 }, 12), { status: 403 });
    t.ok(true, 'Выход за область возвращает 403');
    t.is(await org.inScope({ scope_unit_id: null }, 12), true, 'Общая область доступна');
  });
};
exports.permitValidation = async t => {
  let written;
  await patched(db, { transaction: fn => fn() }, () => patched(queries, {
    getOrder: async () => ({ id: 3, issued_on: '2020-02-01' }),
    listAllPermitTypes: async () => [{ id: 2, is_post_specific: false }],
    listByIds: async () => [{ id: 1, last_name: 'Тестов', first_name: 'Иван' }],
    listPermitsFor: async () => [],
    grantPermit: async data => { written = data; return 4; },
  }, async () => {
    const input = { employeeId: 1, permitTypeId: 2, orderId: 3 };
    await assert.rejects(personnel.grantPermit({ ...input, expiresAt: '2020-01-31' }), { status: 400 });
    t.is(written, undefined, 'Истечение до приказа не записано');
    t.is(await personnel.grantPermit(input), 4, 'Бессрочный допуск выдан');
    t.is(written.issuedAt, '2020-02-01', 'Дата взята из приказа');
    t.is(written.expiresAt, null, 'Пустой срок означает бессрочно');
    await patched(queries, { listPermitsFor: async () => [{ permit_type_id: 2, order_id: 3 }] }, async () => {
      await assert.rejects(personnel.grantPermit(input), { status: 400 });
      t.ok(true, 'Дубликат отклонён');
    });
    await patched(queries, { listAllPermitTypes: async () => [{ id: 2, is_post_specific: true }] }, async () => {
      await assert.rejects(personnel.grantPermit(input), { status: 400 });
      t.ok(true, 'Постовой допуск нельзя выдать как общий');
    });
    await patched(queries, { getOrder: async () => null }, async () => {
      await assert.rejects(personnel.grantPermit(input), { status: 404 });
      t.ok(true, 'Отсутствующий приказ возвращает 404');
    });
  }));
};
exports.permitStatus = async t => {
  const writes = [];
  await patched(db, { transaction: fn => fn() }, () => patched(queries, {
    getPermit: async () => ({ id: 7 }), revokePermit: async (...args) => writes.push(args),
  }, async () => {
    await assert.rejects(personnel.setPermitStatus(7, 'deleted'), { status: 400 });
    t.is(writes.length, 0, 'Неизвестный статус не записывается');
    for (const status of ['suspended', 'revoked', 'active']) await personnel.setPermitStatus(7, status);
    t.is(writes, [[7, 'suspended'], [7, 'revoked'], [7, 'active']], 'Допустимые состояния передаются без удаления истории');
    await patched(queries, { getPermit: async () => null }, async () => {
      await assert.rejects(personnel.setPermitStatus(7, 'revoked'), { status: 404 });
      t.ok(true, 'Отсутствующий допуск возвращает 404');
    });
  }));
};
exports.orderNames = async t => {
  await patched(queries, { orderPermits: async () => [{ employee_id: 1, last_name: 'Тестов', first_name: 'Иван', middle_name: 'Петрович', rank_short: 'ст.' }] }, async () => {
    const [person] = await personnel.orderPermits(1);
    t.is(person.full_name, 'Тестов Иван Петрович', 'Полное имя в приказе');
    t.is(person.short_name, 'ст. Тестов И.П.', 'Звание и инициалы в приказе');
  });
};
