'use strict';

// Отсутствия из карточки человека: отметка, снятие, пометка в дереве
// подразделений. Наряд и отсыпной руками не вносятся — только причины
// отсутствия (отпуск, командировка, больничный, прочее).

const db = require('../../services/app/db/pool');

const one = async (sql, params = []) => (await db.query(sql, params)).rows[0];
const dayKey = (d) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;

exports.отсутствие_из_карточки = async (t, ctx) => {
  if (!ctx.alive) { t.ok(true, 'приложение не запущено — пропущено'); return; }
  const { get, post: send } = require('../lib');
  const today = dayKey(new Date());

  // Человек на должности, без отсутствий и нарядов сегодня.
  const person = await one(`
    SELECT e.id, p.unit_id FROM personnel.employees e
    JOIN core.positions p ON p.employee_id = e.id
    WHERE e.is_active
      AND NOT EXISTS (SELECT 1 FROM personnel.absences a WHERE a.employee_id = e.id AND a.cancelled_at IS NULL
                      AND a.date_to >= CURRENT_DATE - 1)
      AND NOT EXISTS (SELECT 1 FROM duty.v_assignment_periods x WHERE x.employee_id = e.id
                      AND x.status <> 'cancelled' AND x.ends_at > now() - interval '3 days'
                      AND x.starts_at < now() + interval '3 days')
    LIMIT 1`);
  if (!person) { t.ok(true, 'подходящего человека нет — пропущено'); return; }

  try {
    const card = await get(`/personnel/${person.id}`);
    t.ok(card.body.includes('Отметить отсутствие'), 'в карточке — форма отметки отсутствия');
    t.ok(card.body.includes('name="typeCode"') && card.body.includes('VACATION'), 'с причинами: отпуск и др.');

    const recorded = await send(`/personnel/${person.id}/absence`, {
      typeCode: 'VACATION', dateFrom: today, dateTo: today, documentRef: 'проверка', note: '',
      back: `/personnel/${person.id}`,
    });
    t.is(recorded.status, 302, 'отсутствие отмечено');
    t.is(recorded.location, `/personnel/${person.id}#absences`, 'и возврат в карточку, к отсутствиям');

    const after = await get(`/personnel/${person.id}`);
    const absence = await one(`SELECT id FROM personnel.absences WHERE employee_id = $1 AND cancelled_at IS NULL
      AND document_ref = 'проверка'`, [person.id]);
    t.ok(Boolean(absence), 'запись есть');
    t.ok(after.body.includes(`/absences/${absence.id}/cancel`), 'в карточке — «снять»');

    const units = await get(`/units?open=${person.unit_id}`);
    const at = units.body.indexOf(`href="/personnel/${person.id}"`);
    t.ok(at > 0 && units.body.slice(at, at + 400).includes('tag-away'), 'в «Подразделениях» у фамилии — пометка отсутствия');

    const cancelled = await send(`/absences/${absence.id}/cancel`, { back: `/personnel/${person.id}` });
    t.is(cancelled.status, 302, 'отметка снята');
    t.is(cancelled.location, `/personnel/${person.id}#absences`, 'возврат в карточку');
    const gone = await one('SELECT cancelled_at FROM personnel.absences WHERE id = $1', [absence.id]);
    t.ok(Boolean(gone.cancelled_at), 'запись снята (история сохранена)');
  } finally {
    await db.query("DELETE FROM personnel.absences WHERE employee_id = $1 AND document_ref = 'проверка'", [person.id]);
  }
};
