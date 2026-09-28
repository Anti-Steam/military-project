'use strict';

// Раздел «Приказы»: хранилище приказов по назначению — допуски, отсутствия и
// приказы на наряды (по вкладке на вид наряда).

const personnel = require('../../services/app/modules/personnel/service');
const duty = require('../../services/app/modules/duty/service');
const db = require('../../services/app/db/pool');

const one = async (sql, params = []) => (await db.query(sql, params)).rows[0];
const failure = async (fn) => {
  try { await fn(); return null; } catch (err) { return err; }
};
const dayKey = (d) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
const plus = (n) => dayKey(new Date(Date.now() + n * 86400000));

async function inRollback(fn) {
  const rollback = new Error('rollback orders');
  try {
    await db.transaction(async () => { await fn(); throw rollback; });
  } catch (err) {
    if (err !== rollback) throw err;
  }
}

async function freePerson() {
  return one(`SELECT e.id, e.last_name FROM personnel.employees e WHERE e.is_active AND e.unit_id IS NOT NULL
    AND NOT EXISTS (SELECT 1 FROM personnel.absences a WHERE a.employee_id = e.id AND a.cancelled_at IS NULL
      AND a.date_to >= CURRENT_DATE) LIMIT 1`);
}

/** Приказ об отсутствии: без направления, отметка по нему, связь и защита. */
exports.приказ_об_отсутствии = async (t) => {
  await inRollback(async () => {
    t.ok(Boolean(await failure(() => personnel.createOrder({ kind: 'permit', number: '1', issuedOn: plus(-1) }, null, null))),
      'приказу на допуск направление обязательно');

    const orderId = await personnel.createOrder({ kind: 'absence', number: 'ОТ-1', issuedOn: plus(-1),
      title: 'Об убытии в командировку' }, null, null);
    const order = await personnel.getOrder(orderId);
    t.is(order.kind, 'absence', 'вид — отсутствие');
    t.is(order.direction_id, null, 'без направления');
    t.ok((await personnel.listAbsenceOrders()).some((o) => o.id === orderId), 'в реестре приказов об отсутствии');

    const person = await freePerson();
    await personnel.recordAbsence({ employeeId: person.id, typeCode: 'TRIP', dateFrom: plus(1), dateTo: plus(5),
      orderId });
    const absence = await one('SELECT order_id, document_ref FROM personnel.absences WHERE employee_id = $1 AND order_id = $2',
      [person.id, orderId]);
    t.ok(Boolean(absence), 'отметка ссылается на приказ');
    t.ok(/приказ № ОТ-1 от/.test(absence.document_ref), 'основание подставлено из приказа');
    t.ok((await personnel.orderAbsences(orderId)).some((a) => a.employee_id === person.id), 'в приказе видно, кто отсутствует');
    t.is((await personnel.getOrder(orderId)).absences, 1, 'счетчик отмеченных');

    t.ok(/отмечено отсутствий/.test((await failure(() => personnel.removeOrder(orderId)) || {}).message || ''),
      'приказ с отметками не удаляется');

    const permitType = await one('SELECT id FROM personnel.permit_types WHERE NOT is_post_specific LIMIT 1');
    t.ok(/только по приказу на допуск/.test((await failure(() => personnel.grantPermit({ employeeId: person.id,
      permitTypeId: permitType.id, orderId })) || {}).message || ''), 'по приказу об отсутствии допуск не выдать');

    const permitOrder = await one("SELECT id FROM personnel.permit_orders WHERE kind = 'permit' LIMIT 1");
    if (permitOrder) {
      t.ok(Boolean(await failure(() => personnel.recordAbsence({ employeeId: person.id, typeCode: 'VACATION',
        dateFrom: plus(20), dateTo: plus(22), orderId: permitOrder.id }))), 'по приказу на допуск отсутствие не отметить');
    }
  });
};

/** Приказы на наряд: утвержденный приказ хранится во вкладке своего вида. */
exports.приказы_на_наряд = async (t) => {
  await inRollback(async () => {
    const root = await one('SELECT id FROM core.units WHERE parent_id IS NULL LIMIT 1');
    const admin = await one("SELECT id FROM core.users WHERE role_code = 'admin' LIMIT 1");
    const type = (await one(`INSERT INTO duty.duty_types (code, name, kind, start_time, duration_hours,
      recovery_sleep_days, recovery_off_days, rest_excludes_weekends, base_weight)
      VALUES ('TEST_ORDS', 'Проверка приказов', 'daily', '18:00', 24, 1, 0, false, 1) RETURNING id`)).id;
    const post = (await one("INSERT INTO duty.duty_posts (duty_type_id, name) VALUES ($1, 'Пост') RETURNING id", [type])).id;
    const person = (await one(`INSERT INTO personnel.employees (last_name, first_name, unit_id)
      VALUES ('Приказной', 'Тест', $1) RETURNING id`, [root.id])).id;

    t.is((await duty.listStoredOrders(type)).length, 0, 'пока не утверждено — приказов нет');
    const date = '2031-08-13';
    await duty.saveBlock({ dutyTypeId: type, date, userId: admin.id, byDate: new Map([[date, new Map([[post, person]])]]) });
    await duty.approveBlock(type, date, null, admin.id);

    const stored = await duty.listStoredOrders(type);
    t.is(stored.length, 1, 'утвержденный приказ — в перечне');
    t.ok(stored[0].approved, 'с пометкой «утвержден»');
    t.ok(Boolean(stored[0].duty_id) && stored[0].days === 1, 'со ссылкой на наряд и числом суток');
  });
};

/** Страницы раздела: вкладки, реестр отсутствий, приказ, выбор в карточке. */
exports.страницы_приказов = async (t, ctx) => {
  if (!ctx.alive) { t.ok(true, 'приложение не запущено — пропущено'); return; }
  const { get } = require('../lib');
  const number = `ОТ-стр-${Date.now()}`;
  const person = await freePerson();
  let orderId = null;
  try {
    const menu = await get('/');
    t.ok(menu.body.includes('href="/permits">Приказы<'), 'в меню — «Приказы»');

    const permits = await get('/permits');
    t.ok(permits.body.includes('href="/orders/absences"'), 'вкладка «Отсутствия»');
    const types = await duty.listDutyTypes();
    const type = types[0];
    t.ok(permits.body.includes('href="/orders/duty">Дежурства<'), 'одна вкладка «Дежурства»');
    t.is(permits.body.includes('href="/orders/duty/'), false, 'подвкладки видов — только внутри «Дежурств»');
    const toFirst = await get('/orders/duty');
    t.is(toFirst.status, 302, '«Дежурства» открывают первый вид наряда');

    orderId = await personnel.createOrder({ kind: 'absence', number, issuedOn: plus(-1), title: 'Проверка реестра' }, null, null);
    await personnel.recordAbsence({ employeeId: person.id, typeCode: 'VACATION', dateFrom: plus(1), dateTo: plus(3), orderId });

    const list = await get('/orders/absences');
    t.is(list.status, 200, 'реестр отсутствий открывается');
    t.ok(list.body.includes(number), 'приказ в реестре');
    t.ok(list.body.includes('name="kind" value="absence"'), 'заведение приказа об отсутствии');

    const page = await get(`/permits/orders/${orderId}`);
    t.ok(page.body.includes('Кто отсутствует по приказу') && page.body.includes(person.last_name),
      'в приказе — кто отсутствует');
    t.is(page.body.includes('Выдать допуск'), false, 'выдачи допуска у такого приказа нет');

    const card = await get(`/personnel/${person.id}`);
    t.ok(card.body.includes('name="orderId"') && card.body.includes(`№ ${number}`), 'в карточке — выбор приказа');

    const dutyPage = await get(`/orders/duty/${type.id}`);
    t.is(dutyPage.status, 200, 'вкладка приказов на наряд открывается');
    t.ok(types.every((x) => dutyPage.body.includes(`href="/orders/duty/${x.id}"`)),
      'внутри «Дежурств» — подвкладка на каждый вид наряда');
  } finally {
    if (orderId) {
      await db.query('DELETE FROM personnel.absences WHERE order_id = $1', [orderId]);
      await db.query('DELETE FROM personnel.permit_orders WHERE id = $1', [orderId]);
    }
  }
};

/** Подвкладки строятся из перечня видов: новый вид — новая, удаленный — пропадает. */
exports.подвкладки_по_видам = async (t, ctx) => {
  if (!ctx.alive) { t.ok(true, 'приложение не запущено — пропущено'); return; }
  const { get } = require('../lib');
  const { rows: [created] } = await db.query(`INSERT INTO duty.duty_types (code, name, kind, start_time, duration_hours,
    recovery_sleep_days, recovery_off_days, rest_excludes_weekends, base_weight)
    VALUES ('ТПВ', 'Проверка подвкладки', 'daily', '09:00', 24, 1, 0, false, 1) RETURNING id`);
  try {
    const first = (await duty.listDutyTypes())[0];
    const page = await get(`/orders/duty/${first.id}`);
    t.ok(page.body.includes(`href="/orders/duty/${created.id}"`), 'новый вид — новая подвкладка');
  } finally {
    await db.query('DELETE FROM duty.duty_types WHERE id = $1', [created.id]);
  }
  const first = (await duty.listDutyTypes())[0];
  const after = await get(`/orders/duty/${first.id}`);
  t.is(after.body.includes(`href="/orders/duty/${created.id}"`), false, 'удаленный вид — подвкладка пропала');
};
