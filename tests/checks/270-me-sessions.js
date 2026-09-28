'use strict';

// «Мои данные» (свое без права просмотра личного состава), сеансы учетной
// записи и журнал доступа с фильтрами. Люди — синтетические.

const access = require('../../services/app/modules/access/service');
const duty = require('../../services/app/modules/duty/service');
const db = require('../../services/app/db/pool');
const { CHECK_LOGIN } = require('../lib');

const one = async (sql, params = []) => (await db.query(sql, params)).rows[0];
const iso = (n) => new Date(Date.now() + n * 86400000).toISOString().slice(0, 10);

exports.мои_данные = async (t, ctx) => {
  if (!ctx.alive) { t.ok(true, 'приложение не запущено — пропущено'); return; }
  const { get } = require('../lib');
  const me = await one('SELECT id, employee_id FROM core.users WHERE login = $1', [CHECK_LOGIN]);
  // Человек с нарядом в окне страницы, если такой есть; иначе любой.
  const person = await one(`SELECT e.id, e.last_name, p.name AS post FROM personnel.employees e
      JOIN duty.v_assignment_periods a ON a.employee_id = e.id AND a.status <> 'cancelled'
        AND a.start_date BETWEEN $1::date AND $2::date
      JOIN duty.duty_posts p ON p.id = a.post_id
    WHERE e.is_active LIMIT 1`, [iso(-30), iso(60)])
    || await one('SELECT id, last_name, NULL AS post FROM personnel.employees WHERE is_active LIMIT 1');
  try {
    const empty = await get('/me');
    t.is(empty.status, 200, 'страница открывается любому вошедшему');
    if (!me.employee_id) t.ok(empty.body.includes('не связана с сотрудником'), 'без сотрудника — объяснение');
    t.ok(empty.body.includes('Где я вошел') && empty.body.includes('>этот<'), 'сеансы, текущий отмечен');
    t.ok(empty.body.includes('href="/me"'), 'ссылка «Мои данные» в шапке');

    await db.query('UPDATE core.users SET employee_id = $2 WHERE id = $1', [me.id, person.id]);
    const page = await get('/me');
    t.ok(page.body.includes(person.last_name), 'свои данные');
    t.ok(page.body.includes('Мои наряды') && page.body.includes('Мои допуски') && page.body.includes('Мое оружие'),
      'наряды, допуски, оружие');
    if (person.post) t.ok(page.body.includes(person.post), 'свой наряд в списке');
    t.is(page.body.includes('/permits/orders/'), false, 'без ссылок в закрытые разделы');

    const rows = await duty.employeeAssignments(person.id, iso(-30), iso(60));
    t.ok(rows.every((r) => r.status !== 'cancelled'), 'отмененные наряды не показываются');
  } finally {
    await db.query('UPDATE core.users SET employee_id = $2 WHERE id = $1', [me.id, me.employee_id]);
  }
};

exports.сеансы = async (t, ctx) => {
  if (!ctx.alive) { t.ok(true, 'приложение не запущено — пропущено'); return; }
  const { get, post: send } = require('../lib');
  const me = await one('SELECT id FROM core.users WHERE login = $1', [CHECK_LOGIN]);
  const login = `check.sess${Date.now() % 100000}`;
  const addSession = async (userId, tag) => db.query(`INSERT INTO core.sessions (id, user_id, csrf_token, expires_at, ip, user_agent)
    VALUES ($1, $2, 'x', now() + interval '1 day', '10.0.0.9', 'Mozilla/5.0 (X11; Linux) Firefox/128.0')`, [`check-${tag}-${Date.now()}`, userId]);
  let other = null;
  try {
    // Свои: «выйти на остальных компьютерах» — текущий остается.
    await addSession(me.id, 'mine');
    const before = (await one('SELECT count(*)::int AS n FROM core.sessions WHERE user_id = $1', [me.id])).n;
    t.ok(before >= 2, 'у записи два сеанса');
    t.ok((await get('/me')).body.includes('Firefox, Linux'), 'браузер и система видны');
    t.is((await send('/me/sessions/end-others', {})).status, 302, 'остальные завершены');
    t.is((await one('SELECT count(*)::int AS n FROM core.sessions WHERE user_id = $1', [me.id])).n, 1, 'остался один');
    t.is((await get('/me')).status, 200, 'текущий сеанс работает');

    // Чужие: администратор завершает все сеансы записи.
    other = (await access.createUser({ login, roleCode: 'user', permissions: [], actorId: null })).id;
    await addSession(other, 'other');
    const card = await get(`/users/${other}`);
    t.ok(card.body.includes('id="sessions"') && card.body.includes('10.0.0.9'), 'сеансы в карточке учетной записи');
    t.is((await send(`/users/${other}/sessions/end`, {})).status, 302, 'все сеансы завершены');
    t.is((await one('SELECT count(*)::int AS n FROM core.sessions WHERE user_id = $1', [other])).n, 0, 'сеансов нет');

    // Журнал доступа: фильтры.
    const log = await get(`/security?group=users&login=${login}`);
    t.ok(log.body.includes('завершены сеансы') && log.body.includes(login), 'событие — в журнале, фильтр по записи и группе');
    t.is(log.body.includes('>вход<'), false, 'чужие группы событий отфильтрованы');
    const future = await get(`/security?from=${iso(3)}`);
    t.ok(future.body.includes('Событий нет'), 'фильтр по датам');
    const page = await access.listEvents({ before: 1 });
    t.is(page.length, 0, '«Раньше» от первого события — пусто');
  } finally {
    if (other) {
      await db.query('DELETE FROM core.sessions WHERE user_id = $1', [other]);
      await db.query('DELETE FROM core.users WHERE id = $1', [other]);
    }
    await db.query("DELETE FROM core.sessions WHERE user_id = $1 AND id LIKE 'check-mine-%'", [me.id]);
  }
};
