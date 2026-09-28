'use strict';

// Оружие по подразделениям — как штат: склад, перемещение, закрепление за
// людьми подразделения, незакрепленное — за командиром, права полного
// доступа (начальник службы вооружения) и командира (свое подразделение).

const personnel = require('../../services/app/modules/personnel/service');
const org = require('../../services/app/modules/org/service');
const db = require('../../services/app/db/pool');

const failure = async (fn) => {
  try { await fn(); return null; } catch (err) { return err; }
};
const one = async (sql, params = []) => (await db.query(sql, params)).rows[0];
const FULL = { id: null, scope_unit_id: null, permissions: new Set(['weapon.view', 'weapon.transfer', 'weapon.assign']) };

async function inRollback(fn) {
  const rollback = new Error('rollback weapons');
  try {
    await db.transaction(async () => { await fn(); throw rollback; });
  } catch (err) {
    if (err !== rollback) throw err;
  }
}

/** Закрепленное — в подразделении владельца; незакрепленное — за командиром. */
exports.оружие_по_подразделениям = async (t) => {
  const odd = await one(`SELECT count(*)::int AS n FROM personnel.weapons w
    JOIN personnel.employees e ON e.id = w.owner_id
    WHERE w.is_active AND w.unit_id IS DISTINCT FROM e.unit_id`);
  t.is(odd.n, 0, 'закрепленное оружие — в подразделении владельца');

  const holder = await one(`SELECT count(*)::int AS n FROM personnel.v_weapons w
    JOIN core.units u ON u.id = w.unit_id
    WHERE w.owner_id IS NULL AND w.holder_id IS DISTINCT FROM u.commander_employee_id`);
  t.is(holder.n, 0, 'незакрепленное числится за командиром подразделения');
};

/** Права: полный доступ — начальник службы вооружения; командир — свое. */
exports.права_на_оружие = async (t) => {
  const perms = async (role) => (await db.query(
    'SELECT permission_code FROM core.role_permissions WHERE role_code = $1', [role])).rows.map((r) => r.permission_code);
  const armament = await perms('armament');
  t.ok(armament.includes('weapon.transfer') && armament.includes('weapon.assign'), 'начальник службы вооружения — полный доступ');
  const commander = await perms('commander');
  t.ok(commander.includes('weapon.assign'), 'командир закрепляет в своем подразделении');
  t.is(commander.includes('weapon.transfer'), false, 'но полного доступа у него нет');
  const { rows } = await db.query("SELECT code FROM core.permissions WHERE code IN ('weapon.assign', 'weapon.transfer')");
  t.is(rows.length, 2, 'оба права есть в перечне — админ включает их в карточке пользователя');
};

/** Весь путь: склад → подразделение → закрепление → перемещение → списание. */
exports.путь_оружия = async (t) => {
  await inRollback(async () => {
    const company = await one("SELECT id FROM core.units WHERE short_name = '1 рота'");
    const foreign = await one("SELECT id FROM core.units WHERE short_name = '2 рота'");
    const child = await one('SELECT id FROM core.units WHERE parent_id = $1 LIMIT 1', [company.id]);
    const commander = { id: null, scope_unit_id: company.id, permissions: new Set(['weapon.view', 'weapon.assign']) };

    // Заведение — только полным доступом, на склад.
    t.is((await failure(() => personnel.addWeapon(commander, { name: 'ПМ', serialNumber: 'ПР-1',
      manufacturedOn: '2001-01-01', kind: 'pistol' })) || {}).status, 403, 'командир оружие не заводит');
    const id = await personnel.addWeapon(FULL, { name: 'ПМ', serialNumber: `ПР-${Date.now()}`,
      manufacturedOn: '2001-01-01', kind: 'pistol' });
    t.ok((await personnel.weaponTree(FULL)).stock.some((w) => w.id === id), 'новое — на складе');
    t.is((await personnel.weaponTree(commander)).stock.length, 0, 'командир склад не видит');

    // Со склада — только полным доступом.
    t.is((await failure(() => personnel.moveWeapon(commander, id, company.id)) || {}).status, 403,
      'командир со склада не берет');
    await personnel.moveWeapon(FULL, id, company.id);
    const holder = await one('SELECT holder_id, owner_id FROM personnel.v_weapons WHERE id = $1', [id]);
    const unit = await one('SELECT commander_employee_id AS c FROM core.units WHERE id = $1', [company.id]);
    t.is(holder.owner_id, null, 'в подразделении без закрепления');
    t.is(holder.holder_id, unit.c, 'числится за командиром роты');

    // Закрепление — за человеком своего подразделения.
    const own = await one(`WITH RECURSIVE tree AS (SELECT id FROM core.units WHERE id = $1
      UNION ALL SELECT u.id FROM core.units u JOIN tree t ON u.parent_id = t.id)
      SELECT e.id FROM personnel.employees e JOIN tree ON tree.id = e.unit_id WHERE e.is_active LIMIT 1`, [company.id]);
    const stranger = await one('SELECT id FROM personnel.employees WHERE unit_id = $1 AND is_active LIMIT 1', [foreign.id]);
    t.ok(/этого подразделения/.test((await failure(() => personnel.attachWeapon(commander, id, stranger.id)) || {}).message || ''),
      'за чужим не закрепить');
    await personnel.attachWeapon(commander, id, own.id);
    t.is((await one('SELECT owner_id FROM personnel.weapons WHERE id = $1', [id])).owner_id, own.id,
      'командир закрепил за своим');
    t.ok((await personnel.weaponsOf(own.id)).some((w) => w.id === id && w.own), 'в карточке — закреплено');

    // Перемещение в своих пределах — закрепление снимается.
    await personnel.moveWeapon(commander, id, child.id);
    const moved = await one('SELECT unit_id, owner_id FROM personnel.weapons WHERE id = $1', [id]);
    t.ok(moved.unit_id === child.id && moved.owner_id === null, 'перемещено во вложенное, закрепление снято');
    t.ok(Boolean(await failure(() => personnel.moveWeapon(commander, id, foreign.id))), 'в чужую роту — нельзя');
    t.is((await failure(() => personnel.moveWeapon(commander, id, null)) || {}).status, 403, 'на склад — только полным доступом');

    // Порядок в подразделении.
    const order = (await db.query('SELECT id FROM personnel.weapons WHERE unit_id = $1 AND is_active ORDER BY sort_order, id',
      [child.id])).rows.map((r) => r.id);
    await personnel.reorderWeapons(commander, child.id, [...order].reverse());
    const after = (await db.query('SELECT id FROM personnel.weapons WHERE unit_id = $1 AND is_active ORDER BY sort_order, id',
      [child.id])).rows.map((r) => r.id);
    t.is(after.join(','), [...order].reverse().join(','), 'порядок сохранен');

    // Правка и списание — полным доступом.
    t.is((await failure(() => personnel.decommissionWeapon(commander, id)) || {}).status, 403, 'командир не списывает');
    await personnel.editWeapon(FULL, id, { name: 'ПМ-М', serialNumber: 'ПР-испр', manufacturedOn: '2002-02-02', kind: 'pistol' });
    t.is((await one('SELECT name FROM personnel.weapons WHERE id = $1', [id])).name, 'ПМ-М', 'правка');
    await personnel.decommissionWeapon(FULL, id);
    const gone = await one('SELECT is_active, unit_id FROM personnel.weapons WHERE id = $1', [id]);
    t.ok(!gone.is_active && gone.unit_id === null, 'списано — из учета подразделений');
  });
};

/** Человек ушел из подразделения — его оружие остается там, за командиром. */
exports.оружие_при_переводе = async (t) => {
  await inRollback(async () => {
    const hr = { id: null, scope_unit_id: null, permissions: new Set(['staff.manage', 'personnel.assign']) };
    const w = await one(`SELECT w.id, w.unit_id, w.owner_id FROM personnel.weapons w
      JOIN core.positions p ON p.employee_id = w.owner_id AND NOT p.is_commander
      WHERE w.is_active LIMIT 1`);
    const vacancy = await one(`SELECT id FROM core.positions WHERE employee_id IS NULL AND unit_id <> $1 LIMIT 1`, [w.unit_id]);
    await org.transferEmployee(hr, w.owner_id, vacancy.id);
    const after = await one('SELECT unit_id, owner_id FROM personnel.weapons WHERE id = $1', [w.id]);
    t.is(after.unit_id, w.unit_id, 'оружие осталось в подразделении');
    t.is(after.owner_id, null, 'закрепление снято — за командиром');
  });
};

/** Вкладка «Оружие»: дерево, склад, корзина, «настроить». */
exports.вкладка_оружия = async (t, ctx) => {
  if (!ctx.alive) { t.ok(true, 'приложение не запущено — пропущено'); return; }
  const { get, post: send } = require('../lib');
  const serial = `ПР-стр-${Date.now()}`;
  const company = await one("SELECT id FROM core.units WHERE short_name = '1 рота'");

  try {
    const added = await send('/weapons', { name: 'ПМ', serialNumber: serial, manufacturedOn: '2001-01-01',
      kind: 'pistol', unitId: '' });
    t.is(added.status, 302, 'оружие заведено со страницы');
    const w = await one('SELECT id FROM personnel.weapons WHERE serial_number = $1', [serial]);

    const page = await get('/weapons');
    t.is(page.status, 200, 'вкладка открывается');
    t.ok(page.body.includes('Свободное оружие'), 'склад — внизу');
    t.ok(page.body.includes(serial), 'новое — на складе');
    t.ok(page.body.includes('id="weapon-trash" hidden'), 'корзина спрятана, пока не тащат');
    t.ok(page.body.includes(`data-sortable="/units/${company.id}/weapons/order"`), 'порядок — перетаскиванием');
    t.ok(page.body.includes('id="weapon-settings"'), 'окно «настроить»');
    t.ok(page.body.includes('Добавить оружие'), 'добавление — полным доступом');

    const moved = await send(`/weapons/${w.id}/move`, { unitId: String(company.id) });
    t.is(moved.status, 302, 'со склада — в роту');
    const people = JSON.parse((await get(`/weapons/${w.id}/people`)).body);
    t.ok(people.people.length > 0, 'люди роты для закрепления');
    const attached = await send(`/weapons/${w.id}`, { employeeId: String(people.people[0].id) });
    t.is(attached.status, 302, 'закреплено');
    t.is((await one('SELECT owner_id FROM personnel.weapons WHERE id = $1', [w.id])).owner_id, people.people[0].id,
      'за выбранным человеком');
    const off = await send(`/weapons/${w.id}`, { action: 'decommission' });
    t.is(off.status, 302, 'списано');
  } finally {
    await db.query('DELETE FROM personnel.weapons WHERE serial_number = $1', [serial]);
  }
};

/** Люди без оружия видны, и оружие выдается им перетаскиванием. */
exports.выдача_человеку_без_оружия = async (t) => {
  await inRollback(async () => {
    const company = await one("SELECT id FROM core.units WHERE short_name = '1 рота'");
    const foreign = await one("SELECT id FROM core.units WHERE short_name = '2 рота'");
    const commander = { id: null, scope_unit_id: company.id, permissions: new Set(['weapon.view', 'weapon.assign']) };

    // Человек роты без оружия: снимаем с него все, что числится.
    const person = await one(`WITH RECURSIVE tree AS (SELECT id FROM core.units WHERE id = $1
      UNION ALL SELECT u.id FROM core.units u JOIN tree t ON u.parent_id = t.id)
      SELECT e.id, e.unit_id FROM personnel.employees e JOIN tree ON tree.id = e.unit_id
      WHERE e.is_active AND NOT EXISTS (SELECT 1 FROM core.units u WHERE u.commander_employee_id = e.id) LIMIT 1`, [company.id]);
    await db.query('UPDATE personnel.weapons SET owner_id = NULL WHERE owner_id = $1', [person.id]);

    const find = (nodes, id) => nodes.reduce((f, n) => f || (n.id === id ? n : find(n.children, id)), null);
    let tree = (await personnel.weaponTree(FULL)).tree;
    t.ok(find(tree, person.unit_id).unarmed.some((p) => p.id === person.id), 'человек — в строке «Без оружия»');

    // Со склада — сразу человеку: оружие переезжает в его подразделение.
    const stock = await personnel.addWeapon(FULL, { name: 'АК-74М', serialNumber: `ПР-в-${Date.now()}`,
      manufacturedOn: '2010-01-01', kind: 'rifle' });
    t.is((await failure(() => personnel.giveWeapon(commander, stock, person.id)) || {}).status, 403,
      'командир со склада не выдает');
    await personnel.giveWeapon(FULL, stock, person.id);
    const given = await one('SELECT unit_id, owner_id FROM personnel.weapons WHERE id = $1', [stock]);
    t.is(given.unit_id, person.unit_id, 'оружие переехало в подразделение человека');
    t.is(given.owner_id, person.id, 'и закреплено за ним');
    tree = (await personnel.weaponTree(FULL)).tree;
    t.is(find(tree, person.unit_id).unarmed.some((p) => p.id === person.id), false, 'из «Без оружия» он ушел');

    // Командир выдает оружие своей роты своему; чужому — нет.
    const stranger = await one('SELECT id FROM personnel.employees WHERE unit_id = $1 AND is_active LIMIT 1', [foreign.id]);
    t.ok(Boolean(await failure(() => personnel.giveWeapon(commander, stock, stranger.id))), 'чужой роте — нельзя');
    await personnel.attachWeapon(commander, stock, null);
    await personnel.giveWeapon(commander, stock, person.id);
    t.is((await one('SELECT owner_id FROM personnel.weapons WHERE id = $1', [stock])).owner_id, person.id,
      'командир выдал своему');
  });
};

/** На странице — плашки «Без оружия» и выдача через маршрут. */
exports.плашки_без_оружия_на_странице = async (t, ctx) => {
  if (!ctx.alive) { t.ok(true, 'приложение не запущено — пропущено'); return; }
  const { get, post: send } = require('../lib');
  const serial = `ПР-пл-${Date.now()}`;
  try {
    await send('/weapons', { name: 'ПМ', serialNumber: serial, manufacturedOn: '2001-01-01', kind: 'pistol', unitId: '' });
    const w = await one('SELECT id FROM personnel.weapons WHERE serial_number = $1', [serial]);
    const person = await one(`SELECT e.id, e.unit_id FROM personnel.employees e WHERE e.is_active AND e.unit_id IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM personnel.v_weapons x WHERE x.is_active AND x.holder_id = e.id) LIMIT 1`);
    if (!person) { t.ok(true, 'все с оружием — пропущено'); return; }

    const page = await get('/weapons');
    t.ok(page.body.includes(`class="person-chip" draggable="true"`) && page.body.includes(`data-employee="${person.id}"`),
      'человек без оружия — плашкой');
    t.ok(page.body.includes(`data-weapon-row="${w.id}"`), 'строки оружия принимают плашку');

    const given = await send(`/weapons/${w.id}/give`, { employeeId: String(person.id) });
    t.is(given.status, 302, 'выдано');
    const after = await one('SELECT unit_id, owner_id FROM personnel.weapons WHERE id = $1', [w.id]);
    t.ok(after.owner_id === person.id && after.unit_id === person.unit_id, 'со склада — человеку, в его подразделение');
  } finally {
    await db.query('DELETE FROM personnel.weapons WHERE serial_number = $1', [serial]);
  }
};

/** В окне «настроить» — «вынести на склад» (полный доступ). */
exports.вынести_на_склад_из_списка = async (t, ctx) => {
  if (!ctx.alive) { t.ok(true, 'приложение не запущено — пропущено'); return; }
  const { get, post: send } = require('../lib');
  const serial = `ПР-ск-${Date.now()}`;
  const company = await one("SELECT id FROM core.units WHERE short_name = '1 рота'");
  try {
    await send('/weapons', { name: 'ПМ', serialNumber: serial, manufacturedOn: '2001-01-01', kind: 'pistol',
      unitId: String(company.id) });
    const w = await one('SELECT id, unit_id FROM personnel.weapons WHERE serial_number = $1', [serial]);
    t.is(w.unit_id, company.id, 'оружие в роте');

    const page = await get('/weapons');
    t.ok(page.body.includes('вынести на склад'), 'в списке «Закреплено за» есть «вынести на склад»');

    const moved = await send(`/weapons/${w.id}`, { employeeId: 'stock' });
    t.is(moved.status, 302, 'выбрано «на склад»');
    t.ok((moved.location || '').includes('#stock'), 'возврат к складу');
    const after = await one('SELECT unit_id, owner_id FROM personnel.weapons WHERE id = $1', [w.id]);
    t.ok(after.unit_id === null && after.owner_id === null, 'оружие на складе, закрепление снято');
  } finally {
    await db.query('DELETE FROM personnel.weapons WHERE serial_number = $1', [serial]);
  }
};
