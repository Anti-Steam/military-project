'use strict';

// Журнал изменений (МС-4): пишет база триггерами — любое добавление,
// изменение, удаление; автор — пользователь запроса; журнал неизменяем;
// пароли в него не попадают.

const db = require('../../services/app/db/pool');
const audit = require('../../services/app/modules/audit/service');

const one = async (sql, params = []) => (await db.query(sql, params)).rows[0];

async function inRollback(fn) {
  const rollback = new Error('rollback audit');
  try {
    await db.transaction(async () => { await fn(); throw rollback; });
  } catch (err) {
    if (err !== rollback) throw err;
  }
}

/** Добавление, изменение (только изменившееся), удаление — с автором. */
exports.журнал_пишет_база = async (t) => {
  const admin = await one("SELECT id FROM core.users WHERE role_code = 'admin' LIMIT 1");
  await db.asUser(admin.id, () => inRollback(async () => {
    const { id } = await one(`INSERT INTO personnel.employees (last_name, first_name) VALUES ('Журналов', 'Тест') RETURNING id`);
    const added = await one(`SELECT * FROM audit.changes WHERE table_name = 'personnel.employees' AND row_id = $1
      AND action = 'insert'`, [String(id)]);
    t.ok(Boolean(added), 'добавление записано');
    t.is(added.user_id, admin.id, 'автор — пользователь запроса (в транзакции)');
    t.is(added.new_data.last_name, 'Журналов', 'что добавлено');

    await db.query("UPDATE personnel.employees SET phone = '123', last_name = last_name WHERE id = $1", [id]);
    const changed = await one(`SELECT * FROM audit.changes WHERE table_name = 'personnel.employees' AND row_id = $1
      AND action = 'update' ORDER BY id DESC LIMIT 1`, [String(id)]);
    t.is(changed.new_data.phone, '123', 'изменение: стало');
    t.is(changed.old_data.phone, null, 'было');
    t.is(Object.keys(changed.new_data).includes('last_name'), false, 'неизменившиеся поля не пишутся');

    const before = await one('SELECT count(*)::int AS n FROM audit.changes WHERE row_id = $1', [String(id)]);
    await db.query('UPDATE personnel.employees SET phone = phone WHERE id = $1', [id]);
    const after = await one('SELECT count(*)::int AS n FROM audit.changes WHERE row_id = $1', [String(id)]);
    t.is(after.n, before.n, 'правка без изменений не пишется');

    await db.query('DELETE FROM personnel.employees WHERE id = $1', [id]);
    const removed = await one(`SELECT * FROM audit.changes WHERE table_name = 'personnel.employees' AND row_id = $1
      AND action = 'delete'`, [String(id)]);
    t.is(removed.old_data.last_name, 'Журналов', 'удаление — с тем, что было');
  }));
};

/** Одиночная запись вне транзакции — тоже за пользователем; без него — система. */
exports.автор_вне_транзакции = async (t) => {
  const admin = await one("SELECT id FROM core.users WHERE role_code = 'admin' LIMIT 1");
  const unit = await one('SELECT id, short_name FROM core.units WHERE parent_id IS NOT NULL LIMIT 1');
  try {
    await db.asUser(admin.id, () => db.query('UPDATE core.units SET short_name = $2 WHERE id = $1',
      [unit.id, `${unit.short_name}*`]));
    const row = await one(`SELECT user_id FROM audit.changes WHERE table_name = 'core.units' AND row_id = $1
      ORDER BY id DESC LIMIT 1`, [String(unit.id)]);
    t.is(row.user_id, admin.id, 'одиночная запись — за пользователем');
  } finally {
    await db.query('UPDATE core.units SET short_name = $2 WHERE id = $1', [unit.id, unit.short_name]);
  }
  const system = await one(`SELECT user_id FROM audit.changes WHERE table_name = 'core.units' AND row_id = $1
    ORDER BY id DESC LIMIT 1`, [String(unit.id)]);
  t.is(system.user_id, null, 'без пользователя — система');
};

/** Пароли не журналируются; журнал не правится. */
exports.журнал_защищен = async (t) => {
  await inRollback(async () => {
    const user = await one("SELECT id FROM core.users LIMIT 1");
    const before = await one('SELECT count(*)::int AS n FROM audit.changes WHERE table_name = $1', ['core.users']);
    await db.query("UPDATE core.users SET password_hash = 'scrypt$x' WHERE id = $1", [user.id]);
    const after = await one('SELECT count(*)::int AS n FROM audit.changes WHERE table_name = $1', ['core.users']);
    t.is(after.n, before.n, 'смена пароля в журнал не пишется (ни старый, ни новый хеш)');
    const leak = await one("SELECT count(*)::int AS n FROM audit.changes WHERE (old_data ? 'password_hash') OR (new_data ? 'password_hash')");
    t.is(leak.n, 0, 'хешей паролей в журнале нет');
  });

  let refused = false;
  try {
    await db.transaction(() => db.query('UPDATE audit.changes SET action = action WHERE id = (SELECT max(id) FROM audit.changes)'));
  } catch (err) {
    refused = /не правится/.test(err.message);
  }
  t.ok(refused, 'журнал не правится');
};

/** Страница: правка из карточки видна в журнале за вошедшим; фильтр по человеку. */
exports.страница_журнала = async (t, ctx) => {
  if (!ctx.alive) { t.ok(true, 'приложение не запущено — пропущено'); return; }
  const { get, post: send, CHECK_LOGIN } = require('../lib');
  const person = await one(`SELECT id, last_name, first_name, middle_name, rank_id, personnel_number, phone
    FROM personnel.employees WHERE is_active AND unit_id IS NOT NULL LIMIT 1`);
  const phone = `+7 ${Date.now() % 10000000}`;
  try {
    const saved = await send(`/personnel/${person.id}/data`, { lastName: person.last_name, firstName: person.first_name,
      middleName: person.middle_name || '', rankId: person.rank_id ? String(person.rank_id) : '',
      personnelNumber: person.personnel_number || '', phone });
    t.is(saved.status, 302, 'данные изменены через карточку');

    const row = await one(`SELECT c.user_id, u.login FROM audit.changes c LEFT JOIN core.users u ON u.id = c.user_id
      WHERE c.table_name = 'personnel.employees' AND c.row_id = $1 AND c.new_data ->> 'phone' = $2`, [String(person.id), phone]);
    t.ok(Boolean(row), 'изменение записано в журнал');
    t.is(row && row.login, CHECK_LOGIN, 'за вошедшим пользователем');

    const page = await get(`/audit?employee=${person.id}`);
    t.is(page.status, 200, 'журнал открывается');
    t.ok(page.body.includes(phone) && page.body.includes('телефон'), 'видно поле и новое значение');
    const card = await get(`/personnel/${person.id}`);
    t.ok(card.body.includes(`/audit?employee=${person.id}`), 'в карточке — «История изменений»');

    const journal = await audit.journal({ employeeId: person.id });
    t.ok(journal.items.some((i) => i.section === 'Личный состав' && i.action === 'изменено'), 'раздел и действие — по-русски');
  } finally {
    await db.query('UPDATE personnel.employees SET phone = $2 WHERE id = $1', [person.id, person.phone]);
  }
};

/** Право на журнал — у администратора; остальным включает администратор. */
exports.право_на_журнал = async (t) => {
  const has = async (role) => (await db.query(
    "SELECT 1 FROM core.role_permissions WHERE role_code = $1 AND permission_code = 'audit.view'", [role])).rows.length > 0;
  t.ok(await has('admin'), 'у администратора есть');
  t.is(await has('commander'), false, 'у командира — нет');
};

/** Вход (время входа, счетчик попыток) — не «изменение»: он в журнале безопасности. */
exports.вход_не_засоряет_журнал = async (t) => {
  await inRollback(async () => {
    const user = await one('SELECT id FROM core.users LIMIT 1');
    const before = await one("SELECT count(*)::int AS n FROM audit.changes WHERE table_name = 'core.users'");
    await db.query('UPDATE core.users SET last_login_at = now(), failed_attempts = failed_attempts + 1 WHERE id = $1', [user.id]);
    const after = await one("SELECT count(*)::int AS n FROM audit.changes WHERE table_name = 'core.users'");
    t.is(after.n, before.n, 'вход и попытки входа в журнал изменений не пишутся');
  });
};
