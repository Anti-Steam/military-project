'use strict';

// Ведение личного состава: вкладка «Личный состав» (люди по подразделениям,
// поиск), прием на службу, правка данных из карточки, исключение из
// списков и возврат; права кадровика.

const personnel = require('../../services/app/modules/personnel/service');
const duty = require('../../services/app/modules/duty/service');
const db = require('../../services/app/db/pool');

const one = async (sql, params = []) => (await db.query(sql, params)).rows[0];
const failure = async (fn) => {
  try { await fn(); return null; } catch (err) { return err; }
};
const HR = { id: null, scope_unit_id: null, permissions: new Set(['staff.manage', 'personnel.assign', 'personnel.view']) };

async function inRollback(fn) {
  const rollback = new Error('rollback people');
  try {
    await db.transaction(async () => { await fn(); throw rollback; });
  } catch (err) {
    if (err !== rollback) throw err;
  }
}

/** Вкладка «Личный состав»: люди по подразделениям, поиск, без вакансий. */
exports.вкладка_личного_состава = async (t, ctx) => {
  if (!ctx.alive) { t.ok(true, 'приложение не запущено — пропущено'); return; }
  const { get } = require('../lib');
  const person = await one('SELECT id FROM personnel.employees WHERE is_active AND unit_id IS NOT NULL LIMIT 1');

  const page = await get('/people');
  t.is(page.status, 200, 'вкладка открывается');
  t.ok(page.body.includes('id="people-search"'), 'есть поиск');
  t.ok(page.body.includes(`href="/personnel/${person.id}"`), 'люди — со ссылкой на карточку');
  t.is(page.body.includes('вакант'), false, 'вакансий нет — только люди');
  t.is(page.body.includes('data-sortable'), false, 'структурой здесь не управляют');
  t.ok(page.body.includes('href="/people/new"'), 'кадровику — «Принять на службу»');

  const menu = await get('/');
  t.ok(menu.body.includes('href="/people"'), 'вкладка в меню');
};

/** Прием, правка, исключение и возврат — через страницы. */
exports.прием_правка_исключение = async (t, ctx) => {
  if (!ctx.alive) { t.ok(true, 'приложение не запущено — пропущено'); return; }
  const { get, post: send } = require('../lib');
  const number = `ПРВ-${Date.now()}`;
  let id = null;

  // Вакансия для приема.
  const vacancy = await one('SELECT id, unit_id, title FROM core.positions WHERE employee_id IS NULL AND NOT is_commander LIMIT 1');
  try {
    const form = await get('/people/new');
    t.is(form.status, 200, 'форма приема открывается');
    t.ok(form.body.includes('data-unit-steps'), 'должность — по уровням подразделений');

    const hired = await send('/people', { lastName: 'Принятов', firstName: 'Тест', middleName: 'Тестович',
      rankId: '', personnelNumber: number, phone: '', positionId: String(vacancy.id) });
    t.is(hired.status, 302, 'принят');
    id = Number((hired.location || '').split('/').pop());
    const person = await one('SELECT unit_id, position, is_active FROM personnel.employees WHERE id = $1', [id]);
    t.ok(person.is_active && person.unit_id === vacancy.unit_id, 'в подразделении вакансии');
    t.is(person.position, vacancy.title, 'на ее должности');

    const again = await send('/people', { lastName: 'Двойников', firstName: 'Тест', personnelNumber: number, positionId: '' });
    t.is(again.status, 400, 'тот же личный номер — отказ');

    // Карточка — вкладками; данные правятся по кнопке.
    const card = await get(`/personnel/${id}`);
    t.is((card.body.match(/data-tab-link=/g) || []).length, 5, 'карточка — пять разделов-вкладок');
    t.ok(card.body.includes('data-edit-person') && card.body.includes('class="form person-edit" hidden'),
      '«Изменить» — форма спрятана');
    const edited = await send(`/personnel/${id}/data`, { lastName: 'Исправлов', firstName: 'Тест', middleName: '',
      rankId: '', personnelNumber: number, phone: '+7 000 000-00-00' });
    t.is(edited.status, 302, 'данные сохранены');
    t.is(edited.location, `/personnel/${id}#data`, 'возврат к данным');
    t.is((await one('SELECT last_name, phone FROM personnel.employees WHERE id = $1', [id])).last_name, 'Исправлов',
      'фамилия изменена');

    // Исключение: должность свободна, человек недействующий.
    const refused = await send(`/personnel/${id}/exclude`, { reason: '' });
    t.is(refused.status, 400, 'без основания — отказ');
    const excluded = await send(`/personnel/${id}/exclude`, { reason: 'приказ № 1 (проверка)' });
    t.is(excluded.status, 302, 'исключен');
    const after = await one('SELECT is_active, unit_id, excluded_on, exclusion_reason FROM personnel.employees WHERE id = $1', [id]);
    t.ok(!after.is_active && after.unit_id === null && after.excluded_on, 'недействующий, без подразделения, с датой');
    t.is((await one('SELECT employee_id FROM core.positions WHERE id = $1', [vacancy.id])).employee_id, null,
      'должность снова вакантна');
    const list = await get('/people');
    t.ok(list.body.includes('Исключенные из списков') && list.body.includes('Исправлов'), 'в списке исключенных');

    const restored = await send(`/personnel/${id}/restore`, {});
    t.is(restored.status, 302, 'возвращен в списки');
    const back = await one('SELECT is_active, unit_id FROM personnel.employees WHERE id = $1', [id]);
    t.ok(back.is_active && back.unit_id === null, 'действующий, за штатом');
  } finally {
    if (id) {
      await db.query('UPDATE core.positions SET employee_id = NULL WHERE employee_id = $1', [id]);
      await db.query('DELETE FROM personnel.employees WHERE id = $1', [id]);
    }
  }
};

/** Исключение снимает с будущих нарядов, открепляет оружие; права — у кадровика. */
exports.исключение_наряды_оружие_права = async (t) => {
  await inRollback(async () => {
    const commander = { id: null, scope_unit_id: 1, permissions: new Set(['personnel.assign', 'personnel.view']) };
    t.is((await failure(() => personnel.hireEmployee(commander, { lastName: 'А', firstName: 'Б' })) || {}).status, 403,
      'командир не принимает');

    const root = await one('SELECT id FROM core.units WHERE parent_id IS NULL LIMIT 1');
    const admin = await one("SELECT id FROM core.users WHERE role_code = 'admin' LIMIT 1");
    const type = (await one(`INSERT INTO duty.duty_types (code, name, kind, start_time, duration_hours,
      recovery_sleep_days, recovery_off_days, rest_excludes_weekends, base_weight)
      VALUES ('TEST_EXCL', 'Проверка исключения', 'daily', '18:00', 24, 1, 0, false, 1) RETURNING id`)).id;
    const post = (await one(`INSERT INTO duty.duty_posts (duty_type_id, name) VALUES ($1, 'Пост') RETURNING id`, [type])).id;

    const id = await personnel.hireEmployee(HR, { lastName: 'Уходов', firstName: 'Тест' });
    const vacancy = await one('SELECT id FROM core.positions WHERE unit_id = $1 AND employee_id IS NULL LIMIT 1', [root.id])
      || { id: (await one(`INSERT INTO core.positions (unit_id, title) VALUES ($1, 'Проверочная') RETURNING id`, [root.id])).id };
    await require('../../services/app/modules/org/service').transferEmployee(HR, id, vacancy.id);

    const weapon = await one(`INSERT INTO personnel.weapons (name, serial_number, manufactured_on, kind, unit_id, owner_id)
      VALUES ('ПМ', $1, '2001-01-01', 'pistol', $2, $3) RETURNING id`, [`ПР-искл-${Date.now()}`, root.id, id]);

    const date = '2031-07-16';
    await duty.saveBlock({ dutyTypeId: type, date, userId: admin.id, byDate: new Map([[date, new Map([[post, id]])]]) });

    t.is((await failure(() => personnel.excludeEmployee(commander, id, 'x')) || {}).status, 403, 'командир не исключает');
    t.is((await failure(() => personnel.editEmployee(commander, id, { lastName: 'x', firstName: 'y' })) || {}).status, 403,
      'и не правит данные');

    await personnel.excludeEmployee(HR, id, 'проверка');
    const dropped = await duty.dropFromFutureDuties(id, admin.id);
    t.is(dropped, 1, 'снят с будущего наряда');
    const left = await one(`SELECT count(*)::int AS n FROM duty.duty_assignments WHERE employee_id = $1`, [id]);
    t.is(left.n, 0, 'будущих назначений нет');
    t.is((await one('SELECT owner_id FROM personnel.weapons WHERE id = $1', [weapon.id])).owner_id, null,
      'оружие откреплено — осталось в подразделении');
    t.ok(Boolean(await failure(() => personnel.excludeEmployee(HR, id, 'снова'))), 'повторно не исключить');
  });
};

/** Принятый за штат (без должности) открывается и правится как обычно. */
exports.карточка_за_штатом = async (t, ctx) => {
  if (!ctx.alive) { t.ok(true, 'приложение не запущено — пропущено'); return; }
  const { get, post: send } = require('../lib');
  let id = null;
  try {
    const hired = await send('/people', { lastName: 'Заштатнов', firstName: 'Тест', positionId: '' });
    t.is(hired.status, 302, 'принят без должности');
    id = Number((hired.location || '').split('/').pop());
    t.is((await one('SELECT unit_id FROM personnel.employees WHERE id = $1', [id])).unit_id, null, 'за штатом');

    const card = await get(`/personnel/${id}`);
    t.is(card.status, 200, 'карточка открывается');
    t.ok(card.body.includes('за штатом'), 'подразделение — «за штатом»');
    t.ok(card.body.includes('action="/personnel/transfer"'), 'можно перевести на должность');

    const edited = await send(`/personnel/${id}/data`, { lastName: 'Заштатнов', firstName: 'Исправлен' });
    t.is(edited.status, 302, 'данные правятся');

    const list = await get('/people');
    t.ok(list.body.includes(`href="/personnel/${id}"`), 'виден в «За штатом» на вкладке');

    const error = await get('/personnel/0');
    t.ok(error.body.includes('history.back()'), 'на странице ошибки — «Назад»');
  } finally {
    if (id) await db.query('DELETE FROM personnel.employees WHERE id = $1', [id]);
  }
};
