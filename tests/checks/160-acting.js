'use strict';

// ВРИО командира и штаб: предложение ВРИО по старшинству и вложенности,
// назначение кадровиком, подпись приказа ВРИО на время отсутствия, права
// командира у ВРИО, вторая подпись — начальник штаба.

const org = require('../../services/app/modules/org/service');
const access = require('../../services/app/modules/access/service');
const duty = require('../../services/app/modules/duty/service');
const tpl = require('../../services/app/modules/duty/order-template');
const declension = require('../../services/app/lib/declension');
const db = require('../../services/app/db/pool');

const failure = async (fn) => {
  try { await fn(); return null; } catch (err) { return err; }
};
const HR = { id: null, scope_unit_id: null, permissions: new Set(['staff.manage', 'personnel.assign']) };
const dayKey = (d) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
const TODAY = dayKey(new Date());

async function inRollback(fn) {
  const rollback = new Error('rollback acting');
  try {
    await db.transaction(async () => { await fn(); throw rollback; });
  } catch (err) {
    if (err !== rollback) throw err;
  }
}

const one = async (sql, params = []) => (await db.query(sql, params)).rows[0];
const rankId = async (name) => (await one('SELECT id FROM core.ranks WHERE name = $1', [name])).id;
async function person(last, rank, unitId, title) {
  const e = await one(`INSERT INTO personnel.employees (last_name, first_name, middle_name, rank_id, unit_id, position)
    VALUES ($1, 'Тест', 'Тестович', $2, $3, $4) RETURNING id`, [last, await rankId(rank), unitId, title]);
  await db.query('INSERT INTO core.positions (unit_id, title, sort_order, employee_id) VALUES ($1, $2, 900, $3)',
    [unitId, title, e.id]);
  return e.id;
}
async function absent(employeeId, from, to) {
  await db.query(`INSERT INTO personnel.absences (employee_id, absence_type_id, date_from, date_to)
    SELECT $1, id, $2, $3 FROM personnel.absence_types WHERE code = 'OTHER'`, [employeeId, from, to]);
}

exports.должность_врио = async (t) => {
  t.is(declension.actingTitle('Командир части'), 'Врио командира части', 'командир → командира');
  t.is(declension.actingTitle('Начальник штаба'), 'Врио начальника штаба', 'начальник → начальника');
  t.is(declension.actingTitle('Заместитель командира роты'), 'Врио заместителя командира роты', 'заместитель → заместителя');
};

/** Штаб части: начальник — командирская, несколько человек и вакансии. */
exports.штаб_части = async (t) => {
  const hq = await one('SELECT id, parent_id FROM core.units WHERE is_headquarters');
  t.ok(Boolean(hq), 'штаб заведен');
  if (!hq) return;
  const root = await one('SELECT id FROM core.units WHERE parent_id IS NULL LIMIT 1');
  t.is(hq.parent_id, root.id, 'штаб — подразделение части');
  const post = await one(`SELECT title, employee_id FROM core.positions WHERE unit_id = $1 AND is_commander`, [hq.id]);
  t.is(post.title, 'Начальник штаба', 'командирская — «Начальник штаба»');
  t.ok(Boolean(post.employee_id), 'и занята');
  const counts = await one(`SELECT count(employee_id)::int AS people, (count(*) - count(employee_id))::int AS vacant
    FROM core.positions WHERE unit_id = $1`, [hq.id]);
  t.ok(counts.people >= 2, 'в штабе несколько человек');
  t.ok(counts.vacant >= 1, 'и вакансии');
};

/** Предлагается самый старший: сначала в самом подразделении, потом во вложенных. */
exports.предложение_врио = async (t) => {
  await inRollback(async () => {
    const root = await one('SELECT id FROM core.units WHERE parent_id IS NULL LIMIT 1');
    const top = await org.createUnit(HR, { parentId: root.id, name: 'Проверочная рота', shortName: 'ПРр' });
    const inner = await org.createUnit(HR, { parentId: top, name: 'Проверочный взвод', shortName: 'ПРв' });

    // В самой роте — только командир; во взводе — капитан и лейтенант.
    const commander = await person('Ротный', 'майор', top, 'Командир роты');
    await db.query(`UPDATE core.positions SET employee_id = NULL WHERE unit_id = $1 AND is_commander`, [top]);
    await db.query(`UPDATE core.positions SET is_commander = false WHERE unit_id = $1`, [top]);
    await db.query(`UPDATE core.positions SET is_commander = true WHERE employee_id = $1`, [commander]);
    const captain = await person('Капитанов', 'капитан', inner, 'Командир взвода');
    await person('Лейтенантов', 'лейтенант', inner, 'Заместитель');

    let panel = await org.actingPanel(HR, top);
    t.is(panel.suggested, captain, 'в роте никого — предложен старший вложенного уровня');
    t.is(panel.candidates.some((c) => c.id === commander), false, 'сам командир в кандидаты не входит');

    // Появился человек в самой роте — он первый, хоть и младше.
    const own = await person('Старшина', 'старший лейтенант', top, 'Заместитель командира роты');
    panel = await org.actingPanel(HR, top);
    t.is(panel.suggested, own, 'свой уровень — раньше вложенного');

    const denied = await failure(() => org.actingPanel(
      { id: null, scope_unit_id: top, permissions: new Set(['personnel.assign']) }, top));
    t.is(denied && denied.status, 403, 'командир ВРИО не назначает');

    // У командира части — любой человек части.
    const whole = await org.actingPanel(HR, root.id);
    const { rows: [{ n }] } = await db.query(`SELECT count(*)::int AS n FROM personnel.employees e
      WHERE e.is_active AND e.unit_id IS NOT NULL
        AND e.id IS DISTINCT FROM (SELECT employee_id FROM core.positions WHERE unit_id = $1 AND is_commander)`, [root.id]);
    t.is(whole.candidates.length, n, 'у командира части кандидаты — вся часть');
  });
};

/**
 * Назначение ВРИО, подпись на время отсутствия (назначенный или
 * предложенный) и права командира у ВРИО.
 */
exports.врио_подпись_и_права = async (t) => {
  await inRollback(async () => {
    const squad = await one(`SELECT u.id FROM core.units u
      WHERE u.name ILIKE '%отделение%' AND EXISTS (SELECT 1 FROM core.positions p WHERE p.unit_id = u.id
        AND p.is_commander AND p.employee_id IS NOT NULL)
        AND (SELECT count(*) FROM core.positions p WHERE p.unit_id = u.id AND p.employee_id IS NOT NULL) >= 3
      LIMIT 1`);
    const post = await one('SELECT employee_id FROM core.positions WHERE unit_id = $1 AND is_commander', [squad.id]);
    const panel = await org.actingPanel(HR, squad.id);
    const [first, second] = panel.candidates.map((c) => c.id);

    // Командир на месте — подписывает сам.
    let signer = await org.signerOn(squad.id, TODAY);
    t.is(signer.person.id, post.employee_id, 'командир на месте — подписывает он');
    t.is(signer.acting, false, 'не ВРИО');

    // Командир отсутствует, ВРИО не назначен — подписывает предложенный.
    await absent(post.employee_id, TODAY, TODAY);
    signer = await org.signerOn(squad.id, TODAY);
    t.is(signer.person.id, first, 'в отсутствие — предложенный системой');
    t.ok(/^Врио командира/.test(signer.title), `должность — «${signer.title}»`);

    // Назначенный ВРИО сильнее предложенного.
    const outsider = await one(`SELECT e.id FROM personnel.employees e WHERE e.is_active AND e.unit_id IS NOT NULL
      AND e.unit_id <> $1 LIMIT 1`, [squad.id]);
    t.ok(Boolean(await failure(() => org.assignActing(HR,
      { unitId: squad.id, employeeId: outsider.id, dateFrom: TODAY, dateTo: TODAY }))), 'чужого ВРИО не назначить');
    t.ok(Boolean(await failure(() => org.assignActing(HR,
      { unitId: squad.id, employeeId: post.employee_id, dateFrom: TODAY, dateTo: TODAY }))), 'самого командира — тоже');
    const acting = await org.assignActing(HR, { unitId: squad.id, employeeId: second, dateFrom: TODAY, dateTo: TODAY,
      reason: 'проверка' });
    t.ok(/уже назначен/.test((await failure(() => org.assignActing(HR,
      { unitId: squad.id, employeeId: first, dateFrom: TODAY, dateTo: TODAY })) || {}).message || ''),
    'пересекающийся ВРИО — отказ');
    signer = await org.signerOn(squad.id, TODAY);
    t.is(signer.person.id, second, 'назначенный ВРИО подписывает');

    // Права: учетная запись ВРИО получает права командира этого отделения.
    const account = await one(`INSERT INTO core.users (login, password_hash, role_code, employee_id)
      VALUES ($1, 'x', 'user', $2) RETURNING id`, [`check-acting-${Date.now()}`, second]);
    const user = await access.applyActing({ id: account.id, role_code: 'user', employee_id: second,
      scope_unit_id: null, permissions: new Set(['duty.view']) });
    t.ok(user.permissions.has('personnel.assign') && user.permissions.has('duty.create'), 'права командира');
    t.is(user.scope_unit_id, squad.id, 'с зоной этого отделения');

    await org.cancelActing(HR, acting);
    const after = await access.applyActing({ id: account.id, role_code: 'user', employee_id: second,
      scope_unit_id: null, permissions: new Set(['duty.view']) });
    t.is(after.permissions.has('personnel.assign'), false, 'ВРИО отменен — прав командира нет');

    // Должность вакантна — тоже предложенный.
    await db.query('UPDATE core.positions SET employee_id = NULL WHERE unit_id = $1 AND is_commander', [squad.id]);
    signer = await org.signerOn(squad.id, '2031-01-01');
    t.ok(signer && signer.acting, 'должность вакантна — подписывает ВРИО (предложенный)');
  });
};

/** Приказ подписывают двое: командир части и под ним начальник штаба. */
exports.две_подписи_приказа = async (t) => {
  await inRollback(async () => {
    const hq = await one('SELECT id FROM core.units WHERE is_headquarters');
    const chief = await one(`SELECT e.id, e.last_name, e.first_name, e.middle_name FROM core.positions p
      JOIN personnel.employees e ON e.id = p.employee_id WHERE p.unit_id = $1 AND p.is_commander`, [hq.id]);

    const signers = await org.orderSigners(TODAY);
    t.is(signers.chief.person.id, chief.id, 'вторая подпись — начальник штаба');

    const context = { unit: signers.unit,
      commander: { ...signers.commander.person, title: signers.commander.title },
      chief: { ...signers.chief.person, title: signers.chief.title } };
    const order = { dutyType: { code: 'X', name: 'X' }, sections: [], orderDate: TODAY, totalAssigned: 0, context };
    let signs = tpl.layout(tpl.DEFAULT_TEMPLATE, order).items.filter((x) => x.type === 'sign');
    t.is(signs.length, 2, 'в шаблоне по умолчанию две подписи');
    t.ok(signs[1].right.endsWith(chief.last_name), 'вторая — начальника штаба');
    t.ok(signs[1].left.startsWith('Начальник штаба\n'), 'с должностью и званием');

    // Начальник штаба отсутствует — подписывает ВРИО.
    await absent(chief.id, TODAY, TODAY);
    const acting = await org.orderSigners(TODAY);
    t.ok(acting.chief.acting, 'в отсутствие — ВРИО');
    context.chief = { ...acting.chief.person, title: acting.chief.title };
    signs = tpl.layout(tpl.DEFAULT_TEMPLATE, order).items.filter((x) => x.type === 'sign');
    t.ok(signs[1].left.startsWith('Врио начальника штаба'), 'подпись — «Врио начальника штаба»');

    // Предпросмотр тоже с двумя подписями.
    const sample = await duty.sampleOrder((await duty.listDutyTypes())[0].id);
    t.ok(sample.context.chief, 'в предпросмотре есть начальник штаба');
  });
};

/** Окно ВРИО на странице и кандидаты по запросу. */
exports.страница_врио = async (t, ctx) => {
  if (!ctx.alive) { t.ok(true, 'приложение не запущено — пропущено'); return; }
  const { get } = require('../lib');
  const hq = await one('SELECT id FROM core.units WHERE is_headquarters');

  const page = await get('/units');
  t.ok(page.body.includes(`data-acting-unit="${hq.id}"`), 'в «изменить» — ВРИО командира');

  const panel = await get(`/units/${hq.id}/acting`);
  t.is(panel.status, 200, 'кандидаты отдаются');
  const data = JSON.parse(panel.body);
  t.ok(data.candidates.length > 0 && data.suggested, 'есть кандидаты и предложенный');

  const typeId = (await duty.listDutyTypes())[0].id;
  const preview = await get(`/duty-types/${typeId}/order/preview`);
  t.ok(preview.body.includes('Начальник штаба'), 'в образце приказа — подпись начальника штаба');
};
