'use strict';

// Страница назначения наряда (из графика): «Назначить автоматически» на ее
// сутки и сворачиваемые сутки — открыты те, по которым щелкнули.

const duty = require('../../services/app/modules/duty/service');
const db = require('../../services/app/db/pool');

const one = async (sql, params = []) => (await db.query(sql, params)).rows[0];

/** Автоподбор со страницы: только эти сутки, назначенных не трогает. */
exports.автоподбор_на_странице = async (t) => {
  const rollback = new Error('rollback plan autofill');
  try {
    await db.transaction(async () => {
      const root = await one('SELECT id FROM core.units WHERE parent_id IS NULL LIMIT 1');
      const admin = await one("SELECT id FROM core.users WHERE role_code = 'admin' LIMIT 1");
      const type = (await one(`INSERT INTO duty.duty_types (code, name, kind, start_time, duration_hours,
        recovery_sleep_days, recovery_off_days, rest_excludes_weekends, base_weight)
        VALUES ('TEST_AF', 'Проверка автоподбора', 'daily', '18:00', 24, 1, 0, false, 1) RETURNING id`)).id;
      const posts = [];
      for (const name of ['Пост А', 'Пост Б']) {
        posts.push((await one('INSERT INTO duty.duty_posts (duty_type_id, name) VALUES ($1, $2) RETURNING id', [type, name])).id);
      }
      const people = [];
      for (let i = 0; i < 4; i += 1) {
        people.push((await one(`INSERT INTO personnel.employees (last_name, first_name, unit_id)
          VALUES ($1, 'Тест', $2) RETURNING id`, [`Подборов${i}`, root.id])).id);
      }

      const date = '2031-09-17';
      // Один пост назначен вручную — он должен остаться.
      await duty.saveBlock({ dutyTypeId: type, date, userId: admin.id,
        byDate: new Map([[date, new Map([[posts[0], people[0]]])]]) });

      const filled = await duty.autoFillPlan(type, date, admin.id);
      t.is(filled, 1, 'занято одно свободное место');
      const rows = (await db.query(`SELECT da.post_id, da.employee_id FROM duty.duty_assignments da
        JOIN duty.duties d ON d.id = da.duty_id WHERE d.duty_type_id = $1`, [type])).rows;
      t.is(rows.length, 2, 'оба поста замещены');
      t.is(rows.find((r) => r.post_id === posts[0]).employee_id, people[0], 'назначенный вручную остался');
      t.is(await duty.autoFillPlan(type, date, admin.id), 0, 'повторно — ничего не меняет');

      const other = (await db.query(`SELECT count(*)::int AS n FROM duty.duties WHERE duty_type_id = $1
        AND start_date <> $2`, [type, date])).rows[0].n;
      t.is(other, 0, 'другие сутки не тронуты');
      throw rollback;
    });
  } catch (err) {
    if (err !== rollback) throw err;
  }
};

/** Сутки сворачиваются: открыты те, по которым щелкнули в графике. */
exports.сворачиваемые_сутки = async (t, ctx) => {
  if (!ctx.alive) { t.ok(true, 'приложение не запущено — пропущено'); return; }
  const { get } = require('../lib');

  // Приказ на несколько суток — ищется по свойству: страница с 2+ сутками.
  const now = new Date();
  const month = new Date(now.getFullYear(), now.getMonth() + 2, 1);
  let found = null;
  for (const type of await duty.listDutyTypes()) {
    for (let day = 1; day <= 28 && !found; day += 1) {
      const date = `${month.getFullYear()}-${String(month.getMonth() + 1).padStart(2, '0')}-${String(day).padStart(2, '0')}`;
      const page = await get(`/duties/plan?type=${type.id}&date=${date}`);
      if (page.status === 200 && (page.body.match(/class="plan-day-box"/g) || []).length >= 2) found = { date, page };
    }
    if (found) break;
  }
  if (!found) { t.ok(true, 'приказа на несколько суток нет — пропущено'); return; }

  const boxes = [...found.page.body.matchAll(/<details class="plan-day-box" data-day="([\d-]+)"\s*([^>]*)>/g)];
  const opened = boxes.filter((m) => /\bopen\b/.test(m[2])).map((m) => m[1]);
  t.ok(boxes.length >= 2, `суток в приказе — ${boxes.length}`);
  t.is(opened.length, 1, 'раскрыты одни сутки');
  const focus = boxes.find((m) => m[1] === found.date) ? found.date : null;
  if (focus) t.is(opened[0], focus, 'и это те, по которым щелкнули');
  t.ok(found.page.body.includes('Назначить автоматически'), 'есть «Назначить автоматически»');

  // Заголовок суток — один (он же сворачивает): внутри раскрытых суток дата
  // не повторяется.
  const section = found.page.body.slice(found.page.body.indexOf(`id="day-${boxes[0][1]}"`));
  const inside = section.slice(0, section.indexOf('<table'));
  t.is(/<h2/.test(inside), false, 'дата суток внутри не повторяется');
  t.ok(/<summary class="plan-day-summary[^"]*">[\s\S]*?заступление/.test(found.page.body),
    'заступление и сдача — в заголовке-сворачивателе');

  // Сутки одни — раскрыты.
  const single = await get(`/duties/plan?type=${(await duty.listDutyTypes()).find((x) => x.kind === 'daily').id}&date=${found.date}`);
  if (single.status === 200 && (single.body.match(/class="plan-day-box"/g) || []).length === 1) {
    t.ok(/class="plan-day-box" data-day="[\d-]+"\s*open/.test(single.body), 'одни сутки — раскрыты');
  }
};
