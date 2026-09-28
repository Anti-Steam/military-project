'use strict';

// Свои виды приказов для разбора («Приказ на караул»): вид задает, что
// сделать с каждым найденным человеком — отметить отсутствующим, занять его
// оружие на срок (на наряд оно тогда не выдается), выдать допуск. Приказы
// таких видов — во вкладке «Приказы» → «Прочие». Все документы и люди —
// синтетические.

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const r = require('../../services/app/modules/orderparse/recognize');
const { parseProfile } = require('../../services/app/modules/orderparse/parse');
const db = require('../../services/app/db/pool');

const one = async (sql, params = []) => (await db.query(sql, params)).rows[0];

const PEOPLE = [
  { id: 1, last_name: 'Иванов', first_name: 'Иван', middle_name: 'Иванович' },
  { id: 3, last_name: 'Петров', first_name: 'Пётр', middle_name: 'Петрович' },
  { id: 5, last_name: 'Сидоров', first_name: 'Семен', middle_name: 'Семенович' },
];
const WEAPONS = [
  { id: 101, serial_number: 'ТС-А-001', holder_id: 1 },
  { id: 102, serial_number: 'ТС-А-002', holder_id: null },
  { id: 103, serial_number: 'ТС-А-0021', holder_id: null },
  { id: 104, serial_number: 'ТП-17', holder_id: 5 },
];
const p = (text) => ({ type: 'p', text });

exports.номера_оружия = async (t) => {
  const found = (text) => r.findWeapons(text, WEAPONS).map((w) => w.weaponId).join();
  t.is(found('автомат ТС-А-002'), '102', 'номер как в учете');
  t.is(found('автомат тс а 002 и ТС-А-0021'), '102,103', 'иначе записанный номер; длинный — не путается с коротким');
  t.is(found('автомат ТС-А-00211'), '', 'часть чужого номера — не номер');
  t.ok(r.mentionsWeapon('с закрепленным оружием') && r.mentionsWeapon('с автоматом') && !r.mentionsWeapon('в наряд'),
    'упоминание оружия без номера');
};

exports.разбор_по_виду = async (t) => {
  const profile = { header_phrases: ['караул'], reserve_weapons: true, default_days: 2 };
  const res = parseProfile([
    p('ПРИКАЗ от 10.10.2026 № 215'),
    p('О назначении караула'),
    p('С 12.10.2026 назначить в караул:'),
    p('рядового Иванова И.И. с закрепленным автоматом;'),
    p('рядового Петрова П.П. — автомат ТС-А-002, рядового Сидорова С.С. — ТС-А-0021;'),
    { type: 'table', rows: [['ФИО', 'Оружие', 'Срок'], ['Петров П.П.', 'ТС-А-002', 'с 20.10.2026 по 25.10.2026']] },
  ], profile, PEOPLE, WEAPONS, '2026-10-10');
  const row = (id, weapon) => res.facts.find((f) => f.employeeId === id && f.weaponId === weapon);

  t.ok(res.matchedBy.includes('караул'), 'вид узнан по словам заголовка');
  t.ok(row(1, 101), 'без номера, но с оружием — закрепленное за человеком');
  t.ok(row(3, 102) && row(5, 103), 'двое в одном абзаце — каждому свой номер');
  t.is(row(1, 101).dateFrom, '2026-10-12', 'срок — из общего абзаца выше, не дата издания');
  t.is(row(1, 101).dateTo, '2026-10-13', 'конца нет — срок вида по умолчанию (2 суток)');
  const own = res.facts.find((f) => f.employeeId === 3 && f.dateFrom === '2026-10-20');
  t.ok(own && own.dateTo === '2026-10-25' && own.weaponId === 102, 'строка таблицы — свой срок и оружие');

  const noWeapons = parseProfile([p('С 12.10.2026 по 13.10.2026:'), p('Иванова И.И. с автоматом ТС-А-002')],
    { header_phrases: [], reserve_weapons: false }, PEOPLE, WEAPONS, '2026-10-10');
  t.is(noWeapons.facts[0].weaponId, null, 'вид без оружия — оружие не предлагается');
  const noPeriod = parseProfile([p('Иванова И.И.')], profile, PEOPLE, WEAPONS, '2026-10-10');
  t.is(noPeriod.unparsed.length, 1, 'нет срока — в «не понятно»');
};

/** Вид «караул» через страницы: заведение, разбор, принятие, действие на наряды. */
exports.приказ_на_караул = async (t, ctx) => {
  if (!ctx.alive) { t.ok(true, 'приложение не запущено — пропущено'); return; }
  const { get, post: send } = require('../lib');
  const personnel = require('../../services/app/modules/personnel/service');
  const dutyQueries = require('../../services/app/modules/duty/queries');
  const person = await one(`SELECT e.id, e.last_name, e.first_name, e.middle_name FROM personnel.employees e
    WHERE e.is_active AND e.unit_id IS NOT NULL AND e.middle_name IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM personnel.absences a WHERE a.employee_id = e.id AND a.cancelled_at IS NULL AND a.date_to >= CURRENT_DATE)
      AND (SELECT count(*) FROM personnel.employees x WHERE x.last_name = e.last_name) = 1
    LIMIT 1`);
  const weapon = await one(`SELECT w.id, w.serial_number, w.kind FROM personnel.weapons w WHERE w.is_active
    AND NOT EXISTS (SELECT 1 FROM personnel.weapon_reservations z WHERE z.weapon_id = w.id AND z.cancelled_at IS NULL)
    ORDER BY w.id LIMIT 1`);
  const name = `Караул проверки ${Date.now()}`;
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'check-profile-'));
  let profileId = null;
  let orderId = null;
  try {
    const day = (n) => new Date(Date.now() + n * 86400000);
    const iso = (d) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
    const ru = (d) => iso(d).split('-').reverse().join('.');
    const [from, to] = [day(20), day(21)];

    // Вид приказа: без действий не заводится.
    t.is((await send('/orders/parse/profiles', { name })).status, 400, 'вид без действий — отказ');
    const created = await send('/orders/parse/profiles', { name, headerPhrases: 'караул, назначении караула',
      absenceCode: 'OTHER', reserveWeapons: 'on', defaultDays: '1' });
    t.is(created.status, 302, 'вид приказа заведен');
    profileId = (await one('SELECT id FROM parse.profiles WHERE name = $1', [name])).id;
    const dictPage = await get('/orders/parse');
    t.ok(dictPage.body.includes(`id="profile-${profileId}"`) && dictPage.body.includes('занять оружие'), 'вид — в словаре разбора');

    // Приказ вида — во вкладке «Прочие».
    fs.writeFileSync(path.join(dir, 'o.html'), `<html><head><meta charset="utf-8"></head><body>
      <p>О назначении караула</p><p>С ${ru(from)} по ${ru(to)} назначить в караул:</p>
      <p>${person.last_name} ${person.first_name[0]}.${person.middle_name[0]}. — автомат ${weapon.serial_number}</p></body></html>`);
    execFileSync('soffice', ['--headless', '--norestore', '--infilter=HTML (StarWriter)', '--convert-to',
      'docx:MS Word 2007 XML', '--outdir', dir, path.join(dir, 'o.html')], { timeout: 120000 });
    const issued = new Date(Date.now() - 86400000).toISOString().slice(0, 10);
    orderId = await personnel.createOrder({ kind: 'other', profileId, number: `КР-${Date.now()}`, issuedOn: issued,
      title: 'О назначении караула' }, { fileName: 'o.docx', data: fs.readFileSync(path.join(dir, 'o.docx')),
      mime: 'application/vnd.openxmlformats-officedocument.wordprocessingml.document' }, null);
    const list = await get('/orders/other');
    t.ok(list.body.includes(`/permits/orders/${orderId}"`) && list.body.includes(name), '«Прочие»: приказ под своим видом');
    t.ok(list.body.includes('href="/orders/other"'), 'вкладка «Прочие» в «Приказах»');

    const review = await get(`/permits/orders/${orderId}/parse`);
    t.is(review.status, 200, 'разбор открывается');
    t.ok(review.body.includes(`<option value="${person.id}" selected>`), 'человек узнан');
    t.ok(review.body.includes(`<option value="${weapon.id}" selected>`), 'оружие узнано по номеру');
    t.ok(review.body.includes(`value="${iso(from)}"`) && review.body.includes(`value="${iso(to)}"`), 'срок из приказа');

    const applied = await send(`/permits/orders/${orderId}/parse/apply`, { count: '1', accept_0: 'on',
      employee_0: String(person.id), weapon_0: String(weapon.id), from_0: iso(from), to_0: iso(to) });
    t.is(applied.status, 302, 'принято');
    const absence = await one('SELECT source FROM personnel.absences WHERE order_id = $1 AND employee_id = $2',
      [orderId, person.id]);
    t.ok(absence && absence.source === 'import', 'человек отмечен отсутствующим по приказу');
    const reservation = await one('SELECT id, reason FROM personnel.weapon_reservations WHERE order_id = $1 AND weapon_id = $2 AND cancelled_at IS NULL',
      [orderId, weapon.id]);
    t.ok(reservation && reservation.reason === name, 'оружие занято на срок');
    const twice = await send(`/permits/orders/${orderId}/parse/apply`, { count: '1', accept_0: 'on',
      employee_0: String(person.id), weapon_0: String(weapon.id), from_0: iso(from), to_0: iso(to) });
    t.ok(!(twice.location || '').includes('failed'), 'повторное принятие — без ошибок и без двойных записей');
    t.is((await one('SELECT count(*)::int AS n FROM personnel.weapon_reservations WHERE order_id = $1', [orderId])).n, 1, 'занятость одна');

    // Действие на наряды: занятое оружие не выдается.
    const free = await dutyQueries.freeWeapons([{ key: 'a', from: iso(from), to: iso(from), kind: weapon.kind }]);
    t.is(free.some((w) => w.id === weapon.id), false, 'в срок караула оружие не предлагается на наряд');
    const later = await dutyQueries.freeWeapons([{ key: 'b', from: iso(day(40)), to: iso(day(40)), kind: weapon.kind }]);
    const owned = await one('SELECT owner_id FROM personnel.weapons WHERE id = $1', [weapon.id]);
    if (!owned.owner_id) t.ok(later.some((w) => w.id === weapon.id), 'после срока — снова свободно');
    await t.fails(() => personnel.reserveWeapon({ weaponId: weapon.id, dateFrom: iso(to), dateTo: iso(to), reason: 'стрельбы' }),
      'пересекающаяся занятость — отказ');

    const orderPage = await get(`/permits/orders/${orderId}`);
    t.ok(orderPage.body.includes('Занятое по приказу оружие') && orderPage.body.includes(weapon.serial_number), 'в приказе — занятое оружие');
    t.ok(orderPage.body.includes('Кто отсутствует по приказу'), 'и отсутствующие');
    t.is((await send(`/orders/parse/profiles/${profileId}/delete`, {})).status, 400, 'вид с приказами не удаляется');
    t.is((await send(`/permits/orders/${orderId}/delete`, {})).status, 400, 'приказ с отметками не удаляется');

    const commander = { id: null, scope_unit_id: 1, permissions: new Set(['absence.manage', 'weapon.assign', 'weapon.view']) };
    await t.fails(() => personnel.cancelReservation(commander, reservation.id), 'командир подразделения занятость не снимает');
    const cancelled = await send(`/weapons/reservations/${reservation.id}/cancel`, { back: `/permits/orders/${orderId}` });
    t.is(cancelled.status, 302, 'занятость снимается');
    const after = await dutyQueries.freeWeapons([{ key: 'c', from: iso(from), to: iso(from), kind: weapon.kind }]);
    if (!owned.owner_id) t.ok(after.some((w) => w.id === weapon.id), 'снятая — оружие снова свободно');
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
    if (orderId) {
      const documents = require('../../services/app/lib/documents');
      const files = await one('SELECT file_path, pdf_path FROM personnel.permit_orders WHERE id = $1', [orderId]);
      if (files) { documents.remove(files.file_path); documents.remove(files.pdf_path); }
      await db.query('DELETE FROM personnel.weapon_reservations WHERE order_id = $1', [orderId]);
      await db.query('DELETE FROM personnel.absences WHERE order_id = $1', [orderId]);
      await db.query('DELETE FROM personnel.employee_permits WHERE order_id = $1', [orderId]);
      await db.query('DELETE FROM parse.documents WHERE order_id = $1', [orderId]);
      await db.query('DELETE FROM personnel.permit_orders WHERE id = $1', [orderId]);
    }
    await db.query('DELETE FROM parse.profiles WHERE name = $1', [name]);
  }
};
