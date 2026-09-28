'use strict';

// Штат и перевод личного состава: должности подразделений, вакансии, перевод
// на вакантную должность, права кадровика и командира, зона ответственности.

const org = require('../../services/app/modules/org/service');
const db = require('../../services/app/db/pool');

const failure = async (fn) => {
  try { await fn(); return null; } catch (err) { return err; }
};

async function unitByName(shortName) {
  const { rows } = await db.query('SELECT id FROM core.units WHERE short_name = $1', [shortName]);
  return rows[0] ? rows[0].id : null;
}

/** Штат заведен из нынешнего состава: у каждого действующего — должность. */
exports.штат_из_состава = async (t) => {
  const { rows: [r] } = await db.query(`
    SELECT count(*)::int AS people,
           count(p.id)::int AS placed
    FROM personnel.employees e
    LEFT JOIN core.positions p ON p.employee_id = e.id
    WHERE e.is_active AND e.unit_id IS NOT NULL
  `);
  t.ok(r.people > 0, 'люди есть');
  t.is(r.placed, r.people, 'каждый в подразделении занимает должность');

  // За штатом — вне всех подразделений: без должности и без подразделения.
  const { rows: odd } = await db.query(`
    SELECT 1 FROM personnel.employees e
    WHERE e.is_active AND e.unit_id IS NULL
      AND EXISTS (SELECT 1 FROM core.positions p WHERE p.employee_id = e.id) LIMIT 1
  `);
  t.is(odd.length, 0, 'у человека без подразделения нет должности');

  const { rows: mismatch } = await db.query(`
    SELECT 1 FROM core.positions p JOIN personnel.employees e ON e.id = p.employee_id
    WHERE e.unit_id <> p.unit_id LIMIT 1
  `);
  t.is(mismatch.length, 0, 'должность — в подразделении человека');
};

/** Права: должности ведет кадровик и администратор; командир — только переводит. */
exports.права_на_штат = async (t) => {
  const perms = async (role) => (await db.query(
    'SELECT permission_code FROM core.role_permissions WHERE role_code = $1', [role],
  )).rows.map((r) => r.permission_code);

  const hr = await perms('hr');
  t.ok(hr.includes('staff.manage') && hr.includes('personnel.assign'), 'кадровик ведет штат и переводит');
  t.ok((await perms('admin')).includes('staff.manage'), 'администратор — тоже');
  const commander = await perms('commander');
  t.ok(commander.includes('personnel.assign'), 'командир переводит');
  t.is(commander.includes('staff.manage'), false, 'но должности не ведет');
};

/**
 * Весь путь на данных роты, в транзакции с откатом: должности, перевод
 * внутри роты и между ротами, ограничения командира.
 */
exports.должности_и_перевод = async (t) => {
  const rollback = new Error('rollback staff');
  try {
    await db.transaction(async () => {
      const companyA = await unitByName('1 рота');
      const companyB = await unitByName('2 рота');
      const hr = { id: null, scope_unit_id: null, permissions: new Set(['staff.manage', 'personnel.assign']) };
      const commander = { id: null, scope_unit_id: companyA, permissions: new Set(['personnel.assign']) };

      // Командир должности не заводит; кадровик — заводит.
      const denied = await failure(() => org.addPosition(commander, companyA, 'Писарь'));
      t.is(denied && denied.status, 403, 'командир не заводит должности');
      const clerkA = await org.addPosition(hr, companyA, 'Писарь');
      const clerkB = await org.addPosition(hr, companyB, 'Писарь');
      t.ok(clerkA > 0 && clerkB > 0, 'кадровик заводит должности');

      const tree = await org.personnelTree(hr);
      const find = (nodes, id) => nodes.reduce((f, n) => f || (n.id === id ? n : find(n.children, id)), null);
      const vacancy = find(tree, companyA).positions.find((p) => p.id === clerkA);
      t.ok(vacancy && !vacancy.employee_id, 'новая должность видна вакантной');

      // Человек роты A с должностью.
      const { rows: [person] } = await db.query(`
        SELECT p.id AS position_id, p.employee_id, p.title FROM core.positions p
        WHERE p.unit_id = $1 AND p.employee_id IS NOT NULL LIMIT 1`, [companyA]);

      // Командир: внутри своей роты — можно.
      t.is(await org.transferEmployee(commander, person.employee_id, clerkA), true, 'командир переводит внутри роты');
      const moved = await org.positionOf(person.employee_id);
      t.is(moved.id, clerkA, 'человек занял новую должность');
      const { rows: [emp] } = await db.query('SELECT position, unit_id FROM personnel.employees WHERE id = $1',
        [person.employee_id]);
      t.is(emp.position, 'Писарь', 'должность человека обновилась');
      const { rows: [old] } = await db.query('SELECT employee_id FROM core.positions WHERE id = $1', [person.position_id]);
      t.is(old.employee_id, null, 'прежняя должность стала вакантной');

      // Командир: в чужую роту — нельзя.
      t.ok(Boolean(await failure(() => org.transferEmployee(commander, person.employee_id, clerkB))),
        'командир не переводит в чужую роту');

      // Занятую должность не занять.
      const { rows: [busy] } = await db.query(`
        SELECT id FROM core.positions WHERE unit_id = $1 AND employee_id IS NOT NULL
          AND employee_id <> $2 LIMIT 1`, [companyA, person.employee_id]);
      t.ok(/занята/.test((await failure(() => org.transferEmployee(hr, person.employee_id, busy.id)) || {}).message || ''),
        'на занятую должность не переводят');

      // Кадровик — в любую роту.
      t.is(await org.transferEmployee(hr, person.employee_id, clerkB), true, 'кадровик переводит в другую роту');
      const { rows: [there] } = await db.query('SELECT unit_id FROM personnel.employees WHERE id = $1', [person.employee_id]);
      t.is(there.unit_id, companyB, 'человек теперь в другой роте');

      // Переименование меняет должность и у человека.
      await org.renamePosition(hr, clerkB, 'Старший писарь');
      const { rows: [renamed] } = await db.query('SELECT position FROM personnel.employees WHERE id = $1', [person.employee_id]);
      t.is(renamed.position, 'Старший писарь', 'переименование — и у человека');

      // Перенос должности в другое подразделение — вместе с человеком.
      t.ok(Boolean(await failure(() => org.movePosition(commander, clerkB, companyA))), 'командир должности не переносит');
      t.is(await org.movePosition(hr, clerkB, companyA), true, 'кадровик переносит должность');
      const { rows: [carried] } = await db.query('SELECT unit_id FROM personnel.employees WHERE id = $1', [person.employee_id]);
      t.is(carried.unit_id, companyA, 'человек переехал вместе с должностью');
      t.is((await org.positionOf(person.employee_id)).id, clerkB, 'и остался на ней');

      // Порядок должностей подразделения — перетаскиванием.
      const order = (await db.query('SELECT id FROM core.positions WHERE unit_id = $1 ORDER BY sort_order, id', [companyA]))
        .rows.map((r) => r.id);
      await org.reorderPositions(hr, companyA, [...order].reverse());
      const after = (await db.query('SELECT id FROM core.positions WHERE unit_id = $1 ORDER BY sort_order, id', [companyA]))
        .rows.map((r) => r.id);
      t.is(after.join(','), [...order].reverse().join(','), 'порядок должностей сохранен');
      t.ok(Boolean(await failure(() => org.reorderPositions(hr, companyA, order.slice(1)))), 'неполный перечень — отказ');

      // В корзину: должность удаляется, человек уходит за штат.
      await org.removePosition(hr, clerkB);
      t.is(await org.positionOf(person.employee_id), null, 'занятую удалили — человек без должности');
      t.ok((await org.unplaced(hr)).some((e) => e.id === person.employee_id), 'он в списке «за штатом»');
      const { rows: [kept] } = await db.query('SELECT unit_id, is_active FROM personnel.employees WHERE id = $1', [person.employee_id]);
      t.ok(kept.is_active && kept.unit_id === null, 'и не числится ни в одном подразделении');
      t.is((await org.unplaced(commander)).length, 0, 'командир список «за штатом» не видит');
      t.ok(/кадровик/.test((await failure(() => org.transferEmployee(commander, person.employee_id, clerkA)) || {}).message || ''),
        'и людей оттуда не берет');

      // Из-за штата — на вакантную должность.
      await org.transferEmployee(hr, person.employee_id, person.position_id);
      t.is((await org.unplaced(hr)).some((e) => e.id === person.employee_id), false, 'снова в штате');

      await org.removePosition(hr, clerkA);
      const { rows: gone } = await db.query('SELECT 1 FROM core.positions WHERE id = $1', [clerkA]);
      t.is(gone.length, 0, 'вакантная удаляется');

      const vacant = await org.vacantPositions(commander);
      t.ok(vacant.every((p) => p.unit), 'вакансии — с подразделением');
      throw rollback;
    });
  } catch (err) {
    if (err !== rollback) throw err;
  }
};

/** Страницы: штат с вакансиями и перетаскиванием, перевод из карточки. */
exports.страницы_штата = async (t, ctx) => {
  if (!ctx.alive) { t.ok(true, 'приложение не запущено — пропущено'); return; }
  const { get, post: send } = require('../lib');

  const unit = await unitByName('1 рота');
  const title = `Проверочная должность ${Date.now()}`;

  try {
    // Окно «изменить» сохраняется одной кнопкой — с новой должностью.
    const { rows: [u] } = await db.query('SELECT name, short_name, parent_id, is_active FROM core.units WHERE id = $1', [unit]);
    const added = await send(`/units/${unit}`, {
      name: u.name, shortName: u.short_name, parentId: String(u.parent_id), isActive: u.is_active ? 'on' : '',
      childName: '', childShort: '', newPositions: [title, ''],
    });
    t.is(added.status, 302, 'должность заведена из окна «изменить»');
    const { rows: [pos] } = await db.query('SELECT id FROM core.positions WHERE title = $1', [title]);

    const page = await get(`/units?open=${unit}`);
    t.ok(page.body.includes(`data-vacant="${pos.id}"`), 'вакантная должность — строкой штата');
    t.ok(page.body.includes('вакант'), 'помечена «вакант»');
    t.ok(page.body.includes('class="person-cell"'), 'людей тянут за фамилию');
    t.ok(page.body.includes('drag-handle position-drag'), 'должности — за «⠿»');
    t.ok(page.body.includes(`data-sortable="/units/${unit}/positions/order"`), 'порядок должностей — перетаскиванием');
    t.ok(page.body.includes('id="staff-trash"'), 'есть корзина');
    t.ok(page.body.includes('id="staff-dialog"'), 'действия — с подтверждением');
    t.ok(page.body.includes('name="newPositions"'), 'должности добавляются в «изменить»');
    t.ok(page.body.includes(`data-configure="${pos.id}"`), 'у должности — «настроить» в конце строки');
    t.ok(page.body.includes('id="position-dialog"'), 'окошко настройки должности');
    t.is(page.body.includes('class="unit-staff"'), false, 'отдельного перечня «Штат» нет — одна таблица');
    t.is(page.body.includes('Назначить командиром'), false, 'ручного назначения командира нет — он из штата');

    // Перевод через страницу и обратно.
    const { rows: [person] } = await db.query(`
      SELECT id AS position_id, employee_id FROM core.positions
      WHERE unit_id = $1 AND employee_id IS NOT NULL LIMIT 1`, [unit]);
    const card = await get(`/personnel/${person.employee_id}`);
    t.ok(card.body.includes('action="/personnel/transfer"'), 'в карточке — «перевести»');
    t.ok(card.body.includes(`"id":${pos.id}`), 'и вакансия в выборе');
    t.ok(card.body.includes('data-unit-steps'), 'подразделение выбирается по уровням');

    const moved = await send('/personnel/transfer',
      { employeeId: String(person.employee_id), positionId: String(pos.id), back: `/personnel/${person.employee_id}` });
    t.is(moved.status, 302, 'перевод выполнен');
    t.is(moved.location, `/personnel/${person.employee_id}`, 'возврат в карточку');

    const back = await send('/personnel/transfer',
      { employeeId: String(person.employee_id), positionId: String(person.position_id) });
    t.is(back.status, 302, 'и возвращен обратно');

    const roster = await get('/personnel/roster');
    t.is(roster.body.includes('/personnel/move'), false, 'старого перевода в списке личного состава нет');
  } finally {
    await db.query('DELETE FROM core.positions WHERE title = $1 AND employee_id IS NULL', [title]);
  }
};

/** Командир видит штат только своего подразделения (с вложенными). */
exports.штат_в_зоне_командира = async (t) => {
  const company = await unitByName('1 рота');
  const foreign = await unitByName('2 рота');
  const commander = { id: null, scope_unit_id: company, permissions: new Set(['personnel.assign']) };
  const own = new Set(await org.scopeIds(commander));

  const tree = await org.personnelTree(commander);
  const positions = [];
  const walk = (nodes) => nodes.forEach((n) => { positions.push(...n.positions); walk(n.children); });
  walk(tree);

  t.ok(positions.length > 0, 'штат своего подразделения виден');
  t.ok(positions.every((p) => own.has(p.unit_id)), 'все должности — из своего подразделения');
  t.is(positions.some((p) => p.unit_id === foreign), false, 'чужой роты в штате нет');

  const vacant = await org.vacantPositions(commander);
  t.ok(vacant.every((p) => own.has(p.unit_id)), 'вакансии для перевода — только свои');
};

const SQUAD = `u.name ILIKE '%отделение%' AND NOT EXISTS (SELECT 1 FROM core.units c WHERE c.parent_id = u.id)`;
const SQUAD_TITLES = ['Командир отделения', 'Заместитель командира отделения', 'Наводчик-оператор',
  'Механик-водитель', 'Пулемётчик', 'Гранатомётчик', 'Старший стрелок', 'Стрелок'];

/** Все отделения одинаковые: восемь должностей, первая — командирская. */
exports.штат_отделений = async (t) => {
  const { rows: squads } = await db.query(`
    SELECT u.id, u.commander_employee_id,
           array_agg(p.title ORDER BY p.sort_order, p.id) AS titles,
           count(*) FILTER (WHERE p.is_commander)::int AS commanders,
           (SELECT x.employee_id FROM core.positions x WHERE x.unit_id = u.id AND x.is_commander) AS holder,
           (array_agg(p.is_commander ORDER BY p.sort_order, p.id))[1] AS first_is_commander
    FROM core.units u JOIN core.positions p ON p.unit_id = u.id
    WHERE ${SQUAD}
    GROUP BY u.id
  `);
  t.ok(squads.length > 0, 'отделения есть');
  t.ok(squads.every((s) => s.titles.join('|') === SQUAD_TITLES.join('|')), 'у всех — одни и те же восемь должностей');
  t.ok(squads.every((s) => s.commanders === 1 && s.first_is_commander), 'одна командирская — первая');
  t.ok(squads.every((s) => (s.commander_employee_id || null) === (s.holder || null)),
    'командир отделения — тот, кто занимает командирскую');
};

/**
 * Командир следует из штата: занял командирскую должность — командир, и
 * учетная запись получает доступ командира; освободил — снимается.
 */
exports.командир_по_должности = async (t) => {
  const rollback = new Error('rollback commander');
  try {
    await db.transaction(async () => {
      const hr = { id: null, scope_unit_id: null, permissions: new Set(['staff.manage', 'personnel.assign']) };
      const one = async (sql, params = []) => (await db.query(sql, params)).rows[0];

      // Отделение с занятой командирской и вакансиями.
      const squad = await one(`
        SELECT u.id FROM core.units u
        WHERE ${SQUAD} AND EXISTS (SELECT 1 FROM core.positions p WHERE p.unit_id = u.id AND p.is_commander AND p.employee_id IS NOT NULL)
          AND (SELECT count(*) FROM core.positions p WHERE p.unit_id = u.id AND p.employee_id IS NULL) >= 2
        LIMIT 1`);
      const command = await one('SELECT id, employee_id FROM core.positions WHERE unit_id = $1 AND is_commander', [squad.id]);
      const vacancy = async () => one(`SELECT id FROM core.positions WHERE unit_id = $1 AND employee_id IS NULL
        AND NOT is_commander ORDER BY sort_order LIMIT 1`, [squad.id]);
      const user = async (login, employeeId, role, scope = null) => one(`INSERT INTO core.users (login, password_hash, role_code, employee_id, scope_unit_id)
        VALUES ($1, 'x', $2, $3, $4) RETURNING id`, [login, role, employeeId, scope]);
      const roleOf = async (id) => one('SELECT role_code, scope_unit_id FROM core.users WHERE id = $1', [id]);
      const commanderOf = async () => (await one('SELECT commander_employee_id AS c FROM core.units WHERE id = $1', [squad.id])).c;

      // Прежний командир с учетной записью командира этого отделения.
      // Командир — только с подразделением (решение 155).
      const oldUser = await user(`check-old-${Date.now()}`, command.employee_id, 'commander', squad.id);

      await org.transferEmployee(hr, command.employee_id, (await vacancy()).id);
      t.is(await commanderOf(), null, 'освободил командирскую — командира нет');
      t.is((await roleOf(oldUser.id)).role_code, 'user', 'и его учетная запись больше не командирская');

      // Человек из другого подразделения с учетной записью пользователя.
      const newcomer = await one(`SELECT e.id FROM personnel.employees e JOIN core.units u ON u.id = e.unit_id
        WHERE e.is_active AND u.id <> $1 LIMIT 1`, [squad.id]);
      const newUser = await user(`check-new-${Date.now()}`, newcomer.id, 'user');
      await org.transferEmployee(hr, newcomer.id, command.id);
      t.is(await commanderOf(), newcomer.id, 'занял командирскую — командир отделения');
      const promoted = await roleOf(newUser.id);
      t.is(promoted.role_code, 'commander', 'учетная запись получила роль командира');
      t.is(promoted.scope_unit_id, squad.id, 'с зоной этого отделения');

      // Роль выше командира не понижается и не меняется.
      await org.transferEmployee(hr, newcomer.id, (await vacancy()).id);
      const chief = await one(`SELECT e.id FROM personnel.employees e JOIN core.units u ON u.id = e.unit_id
        WHERE e.is_active AND u.id <> $1 AND e.id <> $2 LIMIT 1`, [squad.id, newcomer.id]);
      const chiefUser = await user(`check-chief-${Date.now()}`, chief.id, 'chief');
      await org.transferEmployee(hr, chief.id, command.id);
      t.is(await commanderOf(), chief.id, 'командиром стал и начальник службы');
      t.is((await roleOf(chiefUser.id)).role_code, 'chief', 'но его роль не понижена');

      // Кадровик отмечает командирской другую должность — командир меняется.
      const other = await one(`SELECT id, employee_id FROM core.positions WHERE unit_id = $1 AND employee_id IS NOT NULL
        AND NOT is_commander LIMIT 1`, [squad.id]);
      await org.setCommanderPosition(hr, other.id);
      const flags = await one('SELECT count(*) FILTER (WHERE is_commander)::int AS n FROM core.positions WHERE unit_id = $1', [squad.id]);
      t.is(flags.n, 1, 'командирская должность одна');
      t.is(await commanderOf(), other.employee_id, 'командир — занимающий новую командирскую');

      const denied = await failure(() => org.setCommanderPosition(
        { id: null, scope_unit_id: squad.id, permissions: new Set(['personnel.assign']) }, command.id));
      t.is(denied && denied.status, 403, 'командир отмечать командирскую не может');

      // Настройка из строки: переименование и снятие/возврат отметки.
      await org.updatePosition(hr, other.id, { title: 'Командир отделения (врио)', isCommander: false });
      t.is(await commanderOf(), null, 'сняли отметку командирской — командира нет');
      t.is((await one('SELECT title FROM core.positions WHERE id = $1', [other.id])).title,
        'Командир отделения (врио)', 'наименование изменено');
      await org.updatePosition(hr, other.id, { title: 'Командир отделения', isCommander: true });
      t.is(await commanderOf(), other.employee_id, 'вернули отметку — снова командир');
      t.is((await failure(() => org.updatePosition(
        { id: null, scope_unit_id: squad.id, permissions: new Set(['personnel.assign']) },
        other.id, { title: 'x' })) || {}).status, 403, 'командир должности не настраивает');

      // Командирскую — в корзину: вместе с ней уходит и командирство.
      await org.removePosition(hr, other.id);
      t.is(await commanderOf(), null, 'удалили командирскую — командира нет');

      // Новое подразделение сразу получает командирскую должность.
      const created = await org.createUnit(hr, { parentId: squad.id, name: 'Проверочная группа', shortName: 'ПГ' });
      const head = await one('SELECT title, is_commander FROM core.positions WHERE unit_id = $1', [created]);
      t.ok(head && head.is_commander, 'у нового подразделения есть командирская должность');
      t.is(head.title, 'Командир подразделения', 'с общим наименованием — переименуют');
      throw rollback;
    });
  } catch (err) {
    if (err !== rollback) throw err;
  }
};

/** Человек «в корзину» — за штат: должность вакантна, он остается в подразделении. */
exports.человек_за_штат = async (t) => {
  const rollback = new Error('rollback release');
  try {
    await db.transaction(async () => {
      const hr = { id: null, scope_unit_id: null, permissions: new Set(['staff.manage', 'personnel.assign']) };
      const one = async (sql, params = []) => (await db.query(sql, params)).rows[0];

      // Командир отделения — чтобы заодно проверить снятие командирства.
      const command = await one(`SELECT p.id, p.unit_id, p.employee_id FROM core.positions p
        WHERE p.is_commander AND p.employee_id IS NOT NULL LIMIT 1`);
      const commander = { id: null, scope_unit_id: command.unit_id, permissions: new Set(['personnel.assign']) };

      t.is((await failure(() => org.releaseEmployee(commander, command.employee_id)) || {}).status, 403,
        'командир за штат не выводит');

      await org.releaseEmployee(hr, command.employee_id);
      const position = await one('SELECT employee_id FROM core.positions WHERE id = $1', [command.id]);
      t.is(position.employee_id, null, 'должность стала вакантной');
      const person = await one('SELECT unit_id, is_active, position FROM personnel.employees WHERE id = $1', [command.employee_id]);
      t.ok(person.is_active, 'человек в списках части');
      t.is(person.unit_id, null, 'но ни в одном подразделении');
      t.is(person.position, null, 'и без должности');
      t.ok((await org.unplaced(hr)).some((e) => e.id === command.employee_id), 'он — за штатом');
      const unit = await one('SELECT commander_employee_id AS c FROM core.units WHERE id = $1', [command.unit_id]);
      t.is(unit.c, null, 'с командирской — командирство снято');

      t.is(await org.releaseEmployee(hr, command.employee_id), false, 'повторно — ничего не меняет');
      throw rollback;
    });
  } catch (err) {
    if (err !== rollback) throw err;
  }
};

/** Корзина видна только при перетаскивании; вывод за штат со страницы. */
exports.корзина_и_за_штат_со_страницы = async (t, ctx) => {
  if (!ctx.alive) { t.ok(true, 'приложение не запущено — пропущено'); return; }
  const { get, post: send } = require('../lib');

  const page = await get('/units');
  t.ok(page.body.includes('id="staff-trash" hidden'), 'корзина спрятана, пока ничего не тащат');

  const { rows: [p] } = await db.query(`SELECT p.id, p.employee_id FROM core.positions p
    WHERE p.employee_id IS NOT NULL AND NOT p.is_commander LIMIT 1`);
  try {
    const released = await send(`/personnel/${p.employee_id}/release`, {});
    t.is(released.status, 302, 'человек выведен за штат');
    const after = await get('/units');
    t.ok(after.body.includes('За штатом'), 'появился список «За штатом»');
    t.ok(after.body.includes(`data-vacant="${p.id}"`), 'его должность — вакантная строка');
  } finally {
    await send('/personnel/transfer', { employeeId: String(p.employee_id), positionId: String(p.id) });
    const { rows: [back] } = await db.query('SELECT employee_id FROM core.positions WHERE id = $1', [p.id]);
    t.is(back.employee_id, p.employee_id, 'и возвращен на должность');
  }
};

/**
 * «Командир …» становится командирской сама, если у подразделения ее нет, —
 * и приказ подписывает тот, кто занимает командирскую должность части.
 */
exports.командир_по_наименованию_и_приказ = async (t) => {
  const duty = require('../../services/app/modules/duty/service');
  const rollback = new Error('rollback commander title');
  try {
    await db.transaction(async () => {
      const hr = { id: null, scope_unit_id: null, permissions: new Set(['staff.manage', 'personnel.assign']) };
      const one = async (sql, params = []) => (await db.query(sql, params)).rows[0];
      const root = await one('SELECT id FROM core.units WHERE parent_id IS NULL LIMIT 1');

      // Командирскую части убираем — как если бы ее завели без отметки.
      await db.query('UPDATE core.positions SET is_commander = false WHERE unit_id = $1', [root.id]);

      const post = await org.addPosition(hr, root.id, 'Командир части (проверка)');
      t.ok((await one('SELECT is_commander FROM core.positions WHERE id = $1', [post])).is_commander,
        '«Командир …» отмечена командирской сама');
      const second = await org.addPosition(hr, root.id, 'Командир второй (проверка)');
      t.is((await one('SELECT is_commander FROM core.positions WHERE id = $1', [second])).is_commander, false,
        'вторая «Командир …» — нет: командирская уже есть');

      // Человек на командирскую — он и в подписи приказа.
      const person = await one(`SELECT e.id, e.last_name FROM personnel.employees e
        JOIN core.positions p ON p.employee_id = e.id WHERE NOT p.is_commander LIMIT 1`);
      await org.transferEmployee(hr, person.id, post);
      const order = await duty.sampleOrder((await duty.listDutyTypes())[0].id);
      t.ok(duty.orderLayout(order).items.some((x) => x.type === 'sign' && x.right.endsWith(person.last_name)),
        'приказ подписывает новый командир части');

      // Переименование в «Командир …» тоже отмечает, если командирской нет.
      await db.query('UPDATE core.positions SET is_commander = false WHERE unit_id = $1', [root.id]);
      const plain = await org.addPosition(hr, root.id, 'Писарь (проверка)');
      await org.updatePosition(hr, plain, { title: 'Командир (проверка)' });
      t.ok((await one('SELECT is_commander FROM core.positions WHERE id = $1', [plain])).is_commander,
        'переименовали в «Командир …» — стала командирской');
      throw rollback;
    });
  } catch (err) {
    if (err !== rollback) throw err;
  }
};
