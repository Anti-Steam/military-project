'use strict';

// Отсутствие без срока окончания (командировка «до особого распоряжения») и
// досрочное прекращение любого отсутствия — в отличие от «снять», когда
// отсутствия не было.

const personnel = require('../../services/app/modules/personnel/service');
const muster = require('../../services/app/modules/personnel/muster');
const db = require('../../services/app/db/pool');

const one = async (sql, params = []) => (await db.query(sql, params)).rows[0];
const failure = async (fn) => {
  try { await fn(); return null; } catch (err) { return err; }
};
const dayKey = (d) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
const plus = (n) => dayKey(new Date(Date.now() + n * 86400000));

async function inRollback(fn) {
  const rollback = new Error('rollback absence terms');
  try {
    await db.transaction(async () => { await fn(); throw rollback; });
  } catch (err) {
    if (err !== rollback) throw err;
  }
}

async function freePerson() {
  return one(`SELECT e.id FROM personnel.employees e WHERE e.is_active AND e.unit_id IS NOT NULL
    AND NOT EXISTS (SELECT 1 FROM personnel.absences a WHERE a.employee_id = e.id AND a.cancelled_at IS NULL
      AND a.date_to >= CURRENT_DATE) LIMIT 1`);
}

/** Бессрочное: хранится без окончания, человек отсутствует на любую будущую дату. */
exports.отсутствие_без_срока = async (t) => {
  await inRollback(async () => {
    const person = await freePerson();
    const from = plus(1);
    const id = await personnel.recordAbsence({ employeeId: person.id, typeCode: 'TRIP', dateFrom: from,
      dateTo: '', openEnded: true, documentRef: 'проверка' });
    const row = await one("SELECT date_to = 'infinity' AS open FROM personnel.absences WHERE id = $1", [id]);
    t.ok(row.open, 'окончание — без срока');

    const listed = (await personnel.listAbsencesFor(person.id, from, plus(400))).find((a) => a.id === id);
    t.is(listed.date_to, 'infinity', 'в карточке — «без срока»');

    const far = plus(500);
    t.ok((await personnel.listAbsentOn(far)).some((a) => a.id === person.id), 'и через полтора года отсутствует');
    t.ok(/уже есть запись/.test((await failure(() => personnel.recordAbsence({ employeeId: person.id, typeCode: 'VACATION',
      dateFrom: plus(200), dateTo: plus(210) })) || {}).message || ''), 'новая запись поверх — отказ');

    // Строевая записка на далекую дату — «без срока» в перечне.
    const absences = new Map([[person.id, { code: 'TRIP', reason: 'Командировка', date_from: from, date_to: 'infinity' }]]);
    const tree = [{ id: 1, short_name: 'ч', name: 'ч', positions: [], employees: [{ id: person.id, full_name: 'Тест' }], children: [] }];
    const report = muster.build({ tree, absences, dutyState: { onDuty: new Map(), resting: new Map(), justRested: new Map() }, onDate: far });
    t.is(report.absent[0].to, 'infinity', 'в строевой записке — без срока');
    t.is(report.total.trip, 1, 'в графе командировок');

    // Завершить — указать дату окончания.
    await personnel.endAbsence(id, plus(30));
    t.is((await one("SELECT to_char(date_to, 'YYYY-MM-DD') AS d FROM personnel.absences WHERE id = $1", [id])).d, plus(30),
      'завершено датой');
  });
};

/** Досрочное прекращение любого отсутствия. */
exports.досрочное_прекращение = async (t) => {
  await inRollback(async () => {
    const person = await freePerson();
    const id = await personnel.recordAbsence({ employeeId: person.id, typeCode: 'VACATION',
      dateFrom: plus(2), dateTo: plus(20), documentRef: 'проверка' });

    t.ok(/раньше прежнего/.test((await failure(() => personnel.endAbsence(id, plus(25))) || {}).message || ''),
      'позже прежнего окончания — не досрочно, отказ');
    t.ok(/раньше начала/.test((await failure(() => personnel.endAbsence(id, plus(1))) || {}).message || ''),
      'раньше начала — отказ');
    await personnel.endAbsence(id, plus(10));
    const row = await one(`SELECT to_char(date_to, 'YYYY-MM-DD') AS d, cancelled_at FROM personnel.absences WHERE id = $1`, [id]);
    t.is(row.d, plus(10), 'окончание перенесено раньше');
    t.is(row.cancelled_at, null, 'запись не снята — отсутствие было');
    t.is((await personnel.listAbsentOn(plus(15))).some((a) => a.id === person.id), false, 'после — снова налицо');
  });
};

/** Страницы: «без срока» в отметке, «завершить» и «прекратить досрочно». */
exports.без_срока_на_страницах = async (t, ctx) => {
  if (!ctx.alive) { t.ok(true, 'приложение не запущено — пропущено'); return; }
  const { get, post: send } = require('../lib');
  const person = await freePerson();
  if (!person) { t.ok(true, 'подходящего человека нет — пропущено'); return; }
  try {
    const card = await get(`/personnel/${person.id}`);
    t.ok(card.body.includes('name="openEnded"'), 'в отметке — «без срока окончания»');

    const recorded = await send(`/personnel/${person.id}/absence`, { typeCode: 'TRIP', dateFrom: dayKey(new Date()),
      openEnded: 'on', documentRef: 'проверка-срок', back: `/personnel/${person.id}` });
    t.is(recorded.status, 302, 'бессрочная командировка отмечена');
    const after = await get(`/personnel/${person.id}`);
    t.ok(after.body.includes('без срока'), 'в карточке — «без срока»');
    t.ok(after.body.includes('завершить'), 'и «завершить»');
    const people = await get('/people');
    const at = people.body.indexOf(`href="/personnel/${person.id}"`);
    t.ok(at > 0 && /tag-away">[^<]* без срока</.test(people.body.slice(at, at + 1500)),
      'во вкладке «Личный состав» — пометка «… без срока»');

    const absence = await one(`SELECT id FROM personnel.absences WHERE employee_id = $1 AND document_ref = 'проверка-срок'`, [person.id]);
    const ended = await send(`/absences/${absence.id}/end`, { dateTo: dayKey(new Date()), back: `/personnel/${person.id}` });
    t.is(ended.status, 302, 'завершено');
    t.is(ended.location, `/personnel/${person.id}#absences`, 'возврат в карточку');
    const card2 = await get(`/personnel/${person.id}`);
    t.ok(card2.body.includes('прекратить досрочно'), 'у срочной — «прекратить досрочно»');
  } finally {
    await db.query("DELETE FROM personnel.absences WHERE employee_id = $1 AND document_ref = 'проверка-срок'", [person.id]);
  }
};
