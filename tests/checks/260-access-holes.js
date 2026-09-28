'use strict';

// Дыры разграничения доступа, закрытые решением 155:
//   - исключенный из списков не входит (его записи отключаются);
//   - командир — только с подразделением;
//   - словарь разбора и виды приказов — только без ограничения подразделением;
//   - в приказе командир видит только своих;
//   - блокировка входа — по компьютеру (см. 50-access).
// Люди и данные — синтетические.

const access = require('../../services/app/modules/access/service');
const personnel = require('../../services/app/modules/personnel/service');
const db = require('../../services/app/db/pool');
const { CHECK_LOGIN } = require('../lib');

const one = async (sql, params = []) => (await db.query(sql, params)).rows[0];
const failure = async (fn) => {
  try { await fn(); return null; } catch (err) { return err; }
};
const HR = { id: null, scope_unit_id: null, permissions: new Set(['staff.manage', 'personnel.assign', 'personnel.view']) };

async function inRollback(fn) {
  const rollback = new Error('rollback access holes');
  try {
    await db.transaction(async () => { await fn(); throw rollback; });
  } catch (err) {
    if (err !== rollback) throw err;
  }
}

exports.исключенный_не_входит = async (t) => {
  await inRollback(async () => {
    const id = await personnel.hireEmployee(HR, { lastName: 'Выбывший', firstName: 'Тест' });
    const { id: userId } = await access.createUser({ login: `check.gone${Date.now() % 100000}`, roleCode: 'user',
      employeeId: id, permissions: [], actorId: null });
    await db.query(`INSERT INTO core.sessions (id, user_id, csrf_token, expires_at) VALUES ($1, $2, 'x', now() + interval '1 day')`,
      [`check-gone-${Date.now()}`, userId]);

    await personnel.excludeEmployee(HR, id, 'проверка');
    const user = await one('SELECT is_active FROM core.users WHERE id = $1', [userId]);
    t.is(user.is_active, false, 'учетная запись исключенного отключена');
    t.is((await one('SELECT count(*)::int AS n FROM core.sessions WHERE user_id = $1', [userId])).n, 0, 'его сеансы завершены');

    t.ok(Boolean(await failure(() => access.updateUser(userId, { roleCode: 'user', employeeId: id, isActive: true,
      permissions: [], actorId: null }))), 'включить запись исключенного нельзя');
    t.ok(Boolean(await failure(() => access.createUser({ login: `check.gone2${Date.now() % 100000}`, roleCode: 'user',
      employeeId: id, permissions: [], actorId: null }))), 'и завести новую на него');
  });
};

exports.командир_только_с_подразделением = async (t) => {
  const unit = await one('SELECT id FROM core.units ORDER BY id LIMIT 1');
  await inRollback(async () => {
    t.ok(Boolean(await failure(() => access.createUser({ login: `check.cmd${Date.now() % 100000}`, roleCode: 'commander',
      permissions: [], actorId: null }))), 'без подразделения не заводится');
    const { id } = await access.createUser({ login: `check.cmd${Date.now() % 100000}`, roleCode: 'commander',
      scopeUnitId: unit.id, permissions: [], actorId: null });
    t.ok(Boolean(await failure(() => access.updateUser(id, { roleCode: 'commander', isActive: true, scopeUnitId: null,
      permissions: [], actorId: null }))), 'и подразделение у него не снять');
    const err = await failure(() => db.transaction(() => db.query("UPDATE core.users SET scope_unit_id = NULL WHERE id = $1", [id])));
    t.ok(err && err.code === '23514', 'база тоже не допускает командира без подразделения');
  });
  t.is((await one("SELECT count(*)::int AS n FROM core.users WHERE role_code = 'commander' AND scope_unit_id IS NULL")).n, 0,
    'таких записей в базе нет');
};

/** Вошедший с подразделением: словарь разбора закрыт, в приказе — только свои. */
exports.подразделение_в_приказах = async (t, ctx) => {
  if (!ctx.alive) { t.ok(true, 'приложение не запущено — пропущено'); return; }
  const { get } = require('../lib');
  // Двое из разных веток: свой — в подразделении A, чужой — вне его поддерева.
  const mine = await one(`SELECT e.id, e.last_name, e.unit_id FROM personnel.employees e
    WHERE e.is_active AND e.unit_id IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM personnel.absences a WHERE a.employee_id = e.id AND a.cancelled_at IS NULL AND a.date_to >= CURRENT_DATE)
    ORDER BY e.id LIMIT 1`);
  const other = await one(`WITH RECURSIVE sub AS (SELECT id FROM core.units WHERE id = $1
      UNION ALL SELECT u.id FROM core.units u JOIN sub ON u.parent_id = sub.id)
    SELECT e.id, e.last_name FROM personnel.employees e
    WHERE e.is_active AND e.unit_id IS NOT NULL AND e.unit_id NOT IN (SELECT id FROM sub) AND e.last_name <> $2
      AND NOT EXISTS (SELECT 1 FROM personnel.absences a WHERE a.employee_id = e.id AND a.cancelled_at IS NULL AND a.date_to >= CURRENT_DATE)
    ORDER BY e.id LIMIT 1`, [mine.unit_id, mine.last_name]);
  const iso = (n) => new Date(Date.now() + n * 86400000).toISOString().slice(0, 10);
  let orderId = null;
  try {
    orderId = await personnel.createOrder({ kind: 'absence', number: `ДП-${Date.now()}`, issuedOn: iso(-1) }, null, null);
    for (const person of [mine, other]) {
      await personnel.recordAbsence({ employeeId: person.id, typeCode: 'OTHER', dateFrom: iso(200), dateTo: iso(201),
        orderId, userId: null });
    }
    const full = await get(`/permits/orders/${orderId}`);
    t.ok(full.body.includes(mine.last_name) && full.body.includes(other.last_name), 'без подразделения — видны все');
    t.is((await get('/orders/parse')).status, 200, 'и словарь разбора открыт');

    await db.query('UPDATE core.users SET scope_unit_id = $2 WHERE login = $1', [CHECK_LOGIN, mine.unit_id]);
    const scoped = await get(`/permits/orders/${orderId}`);
    t.ok(scoped.body.includes(mine.last_name), 'с подразделением — свой виден');
    t.is(scoped.body.includes(other.last_name), false, 'чужой — нет');
    t.is((await get('/orders/parse')).status, 403, 'словарь разбора и виды приказов закрыты');
    t.is(scoped.body.includes('href="/orders/parse"'), false, 'и вкладки «Словарь разбора» нет');
    const others = await get('/orders/other');
    t.is(others.body.includes('name="profileId"'), false, '«прочие» приказы не заводит');
  } finally {
    await db.query('UPDATE core.users SET scope_unit_id = NULL WHERE login = $1', [CHECK_LOGIN]);
    if (orderId) {
      await db.query('DELETE FROM personnel.absences WHERE order_id = $1', [orderId]);
      await db.query('DELETE FROM personnel.permit_orders WHERE id = $1', [orderId]);
    }
  }
};
