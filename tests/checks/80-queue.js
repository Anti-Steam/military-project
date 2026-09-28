'use strict';

// Очередь заступления и автоматический подбор.

const queue = require('../../services/app/modules/duty/queue');
const duty = require('../../services/app/modules/duty/service');
const queries = require('../../services/app/modules/duty/queries');
const db = require('../../services/app/db/pool');

const settings = queue.DEFAULTS;

/** Готовность растёт каждые сутки простоя до потолка. */
exports.готовность_растет_до_потолка = async (t) => {
  t.is(queue.readiness('2026-10-10', '2026-10-10', settings), 0, 'в день заступления — ноль');
  t.is(queue.readiness('2026-10-10', '2026-10-11', settings), 1, 'через сутки — единица');
  t.is(queue.readiness('2026-10-10', '2026-10-20', settings), 10, 'через десять суток — десять');

  // Потолок обязателен: иначе вернувшийся из отпуска месяцами вытесняет всех.
  t.is(queue.readiness('2026-01-01', '2026-10-20', settings),
    settings['queue.ready_max_days'], 'дольше потолка очередь не растёт');

  // Ни разу не заступавший готов полностью: иначе новичок не попал бы в наряд
  // никогда, а его очередь как раз первая.
  t.is(queue.readiness(null, '2026-10-20', settings),
    settings['queue.ready_max_days'], 'не заступавший готов полностью');

  // Будущая дата последнего наряда трактуется как «только что»: назначенный
  // вперёд человек не должен считаться отдохнувшим.
  t.is(queue.readiness('2026-10-25', '2026-10-20', settings), 0, 'наряд впереди — готовности нет');
};

/** Очередь складывается из готовности, нагрузки и соответствия посту. */
exports.очередь_складывается_из_трех_частей = async (t) => {
  const base = queue.queueValue(
    { lastDate: '2026-10-10', workload: 0 }, {}, '2026-10-20', settings,
  );
  t.is(base.value, 10, 'без нагрузки и поправок очередь равна готовности');

  const loaded = queue.queueValue(
    { lastDate: '2026-10-10', workload: 10 }, {}, '2026-10-20', settings,
  );
  t.ok(loaded.value < base.value, 'нагрузка понижает очередь');
  t.is(loaded.workload, 10 * settings['queue.workload_factor'], 'нагрузка взята с коэффициентом');

  const fitted = queue.queueValue(
    { lastDate: '2026-10-10', workload: 0 }, { rank: 5, personal: -2 }, '2026-10-20', settings,
  );
  t.is(fitted.fit, 3, 'вес звания и личная поправка складываются');
  t.is(fitted.value, 13, 'и попадают в очередь');

  // Порог считается по ПРОСТОЮ, а не по итоговой очереди: иначе накопленная
  // нагрузка отодвигала бы возврат в списки на третьи сутки.
  const fresh = queue.queueValue(
    { lastDate: '2026-10-20', workload: 3 }, {}, '2026-10-20', settings,
  );
  t.is(queue.passes(fresh, settings), false, 'в сутки сдачи человек не предлагается');
  t.is(queue.passes(base, settings), true, 'отдохнувший порог проходит');

  // Главное правило: нельзя только сразу после смены, а на следующие сутки
  // уже можно — сколько бы нагрузки ни накопилось.
  const tired = queue.queueValue(
    { lastDate: '2026-10-19', workload: 60 }, {}, '2026-10-20', settings,
  );
  t.is(tired.readiness, 1, 'простой — одни сутки');
  t.ok(tired.value < 0, 'очередь при большой нагрузке отрицательная');
  t.is(queue.passes(tired, settings), true, 'и всё равно предлагается: сутки прошли');
};

/** Порядок устойчив: одинаковые кандидаты не перетасовываются. */
exports.порядок_кандидатов = async (t) => {
  const make = (id, value, readiness) => ({ id, queue: { value, readiness } });

  const list = [make(3, 5, 5), make(1, 9, 9), make(2, 5, 7)];
  list.sort(queue.compare);

  t.is(list.map((x) => x.id), [1, 2, 3], 'выше очередь — раньше; при равной раньше отдохнувший');

  const same = [make(7, 4, 4), make(2, 4, 4)];
  same.sort(queue.compare);
  t.is(same.map((x) => x.id), [2, 7], 'при полном равенстве порядок устойчив');
};

/** Соответствие посту разводит сержантов и рядовых. */
exports.вес_звания_на_посту = async (t) => {
  const type = (await duty.listDutyTypes()).find((x) => x.code === 'SN');
  const now = new Date();
  const date = require('../../services/app/modules/duty/calendar').dayKey(
    new Date(now.getFullYear(), now.getMonth() + 1, 15));

  const selection = await duty.findCandidatesByPost(type.id, date, null);

  const commander = selection.posts.find((p) => p.post.name === 'Дежурный по 1-й роте');
  const orderly = selection.posts.find((p) => p.post.name === 'Дневальный по 1-й роте — 1');

  t.ok(commander.candidates.length > 0, 'кандидаты на дежурного есть');
  t.ok(orderly.candidates.length > 0, 'кандидаты на дневального есть');

  // Первый в списке дежурного по роте — сержантский состав, дневального —
  // рядовой: так заданы веса званий в справочнике.
  t.ok(commander.candidates[0].seniority >= 30, 'на дежурного первым идёт сержантский состав');
  t.ok(orderly.candidates[0].seniority <= 20, 'на дневального первым идёт рядовой состав');

  // У каждого кандидата очередь разложена на части — иначе непонятно, почему
  // он стоит именно здесь.
  const first = commander.candidates[0];
  t.ok(first.queue && typeof first.queue.value === 'number', 'очередь посчитана');
  t.is(first.queue.value,
    Math.round((first.queue.readiness - first.queue.workload + first.queue.fit) * 100) / 100,
    'значение сходится со слагаемыми');
};

/** Подбор заполняет пустые места и не трогает назначенных. */
exports.подбор_месяца = async (t) => {
  const type = (await duty.listDutyTypes()).find((x) => x.code === 'SN');
  const now = new Date();
  const month = new Date(now.getFullYear(), now.getMonth() + 3, 1);
  const [year, index] = [month.getFullYear(), month.getMonth() + 1];

  // Месяц далеко впереди: чужую работу проверка не портит.
  const from = `${year}-${String(index).padStart(2, '0')}-01`;
  const to = `${year}-${String(index).padStart(2, '0')}-28`;

  try {
    await db.query('DELETE FROM duty.duties WHERE duty_type_id = $1 AND start_date BETWEEN $2::date AND $3::date',
      [type.id, from, to]);

    const before = await duty.getMonthSchedule(type.id, year, index, null, null);
    const emptyBefore = before.grid.flat()
      .filter((d) => d.cell && !d.outside && !d.cell.continuation && d.cell.assigned === 0);
    t.ok(emptyBefore.length > 0, `до подбора пустых суток: ${emptyBefore.length}`);

    const result = await duty.autoFill(type.id, year, index, null);
    t.ok(result.filled > 0, `подбор занял мест: ${result.filled}`);

    const after = await duty.getMonthSchedule(type.id, year, index, null, null);
    const cells = after.grid.flat().filter((d) => d.cell && !d.outside && !d.cell.continuation);
    const closed = cells.filter((d) => d.cell.assigned >= d.cell.postCount);

    t.ok(closed.length >= cells.length - 3,
      `закрыто суток: ${closed.length} из ${cells.length}`);

    // Подобранное помечено источником: в графике такие сутки оранжевые и ждут
    // подтверждения начальником.
    t.ok(closed.every((d) => d.cell.status === 'auto'), 'подобранные сутки ждут подтверждения');

    // Повторный подбор ничего не портит: занятые места он не трогает.
    const again = await duty.autoFill(type.id, year, index, null);
    t.ok(again.filled <= 3, `повторный подбор добирает только остаток: ${again.filled}`);

    // Люди в подобранном составе не повторяются в одних сутках.
    const duties = await queries.findDutiesOnDates(type.id, [`${year}-${String(index).padStart(2, '0')}-15`]);
    if (duties.length > 0) {
      const roster = await queries.getAssignments(duties[0].id);
      t.is(new Set(roster.map((r) => r.employee_id)).size, roster.length,
        'в одних сутках каждый человек один раз');
    }
  } finally {
    await db.query('DELETE FROM duty.duties WHERE duty_type_id = $1 AND start_date BETWEEN $2::date AND $3::date',
      [type.id, from, to]);
  }
};

/** Подбор берёт людей из ответственного подразделения поста. */
exports.подбор_уважает_закрепление = async (t) => {
  const type = (await duty.listDutyTypes()).find((x) => x.code === 'SN');
  const now = new Date();
  const month = new Date(now.getFullYear(), now.getMonth() + 3, 1);
  const [year, index] = [month.getFullYear(), month.getMonth() + 1];
  const date = `${year}-${String(index).padStart(2, '0')}-10`;

  try {
    await db.query('DELETE FROM duty.duties WHERE duty_type_id = $1 AND start_date = $2::date',
      [type.id, date]);

    await duty.autoFill(type.id, year, index, null);

    const duties = await queries.findDutiesOnDates(type.id, [date]);
    if (duties.length === 0) { t.ok(true, 'на эти сутки наряд не положен — пропущено'); return; }

    const roster = await queries.getAssignments(duties[0].id);
    const posts = await queries.listPosts(type.id);
    const byPost = new Map(posts.map((p) => [p.id, p]));

    // Для постов с закреплением проверяется, что человек из своего
    // подразделения: иначе закрепления не имели бы смысла.
    const { rows } = await db.query(`
      WITH RECURSIVE tree AS (
        SELECT pu.post_id, pu.unit_id AS root, pu.unit_id FROM duty.post_units pu
        UNION ALL
        SELECT t.post_id, t.root, u.id FROM core.units u JOIN tree t ON u.parent_id = t.unit_id
      )
      SELECT post_id, unit_id FROM tree
    `);

    const allowed = new Map();
    for (const row of rows) {
      if (!allowed.has(row.post_id)) allowed.set(row.post_id, new Set());
      allowed.get(row.post_id).add(row.unit_id);
    }

    let checked = 0;
    for (const item of roster) {
      const permitted = allowed.get(item.post_id);
      if (!permitted) continue;

      const { rows: who } = await db.query(
        'SELECT unit_id FROM personnel.employees WHERE id = $1', [item.employee_id],
      );
      checked += 1;
      t.ok(permitted.has(who[0].unit_id),
        `${byPost.get(item.post_id).short_name || item.post_id}: человек из закреплённого подразделения`);
    }

    t.ok(checked > 0, `постов с закреплением проверено: ${checked}`);
  } finally {
    await db.query('DELETE FROM duty.duties WHERE duty_type_id = $1 AND start_date = $2::date',
      [type.id, date]);
  }
};

/**
 * Кнопка «Назначить автоматически» в графике.
 *
 * Делает то же, что подбор при открытии месяца, но по требованию: добирает
 * незамещенные места впереди и не трогает назначенных.
 */
exports.назначить_автоматически_по_кнопке = async (t, ctx) => {
  if (!ctx.alive) { t.ok(true, 'приложение не запущено — пропущено'); return; }

  const { get, post: send } = require('../lib');

  const type = (await duty.listDutyTypes()).find((x) => x.code === 'SN');
  const now = new Date();
  const month = new Date(now.getFullYear(), now.getMonth() + 2, 1);
  const [year, index] = [month.getFullYear(), month.getMonth() + 1];
  const monthKey = `${year}-${String(index).padStart(2, '0')}`;
  const from = `${monthKey}-01`;
  const to = `${monthKey}-28`;

  try {
    // В графике есть кнопка.
    const page = await get(`/duties?type=${type.id}&month=${monthKey}`);
    t.is(page.status, 200, 'график открылся');
    t.ok(page.body.includes('Назначить автоматически'), 'в графике есть кнопка');

    // Освобождаем сутки: подбору есть что закрывать.
    await db.query('DELETE FROM duty.duties WHERE duty_type_id = $1 AND start_date BETWEEN $2::date AND $3::date',
      [type.id, from, to]);

    const pressed = await send('/duties/autofill', { type: String(type.id), month: monthKey });
    t.is(pressed.status, 302, 'кнопка сработала');
    t.ok((pressed.location || '').includes(`month=${monthKey}`), 'и вернула в тот же месяц');

    const filled = Number((/filled=(\d+)/.exec(pressed.location || '') || [])[1]);
    t.ok(filled > 0, `подобрано мест: ${filled}`);

    // Итог показан пользователю.
    const after = await get(pressed.location);
    t.ok(after.body.includes('Система подобрала состав'), 'итог подбора показан');

    // Повторное нажатие не переделывает назначенное: подбирать уже нечего.
    const again = await send('/duties/autofill', { type: String(type.id), month: monthKey });
    const second = Number((/filled=(\d+)/.exec(again.location || '') || [])[1]);
    t.ok(second <= 3, `повторно добрано только остатка: ${second}`);

    if (second === 0) {
      const quiet = await get(again.location);
      t.ok(quiet.body.includes('Подбирать нечего'), 'и об этом сказано прямо');
    }
  } finally {
    await db.query('DELETE FROM duty.duties WHERE duty_type_id = $1 AND start_date BETWEEN $2::date AND $3::date',
      [type.id, from, to]);
  }
};

/**
 * Открытие месяца ничего не назначает: подбор — только кнопкой.
 *
 * Иначе простой просмотр графика менял данные, и пролистать месяцы вперед
 * значило заполнить их составом.
 */
exports.открытие_месяца_не_назначает = async (t, ctx) => {
  if (!ctx.alive) { t.ok(true, 'приложение не запущено — пропущено'); return; }

  const { get } = require('../lib');

  const type = (await duty.listDutyTypes()).find((x) => x.code === 'SN');
  const now = new Date();
  const month = new Date(now.getFullYear(), now.getMonth() + 3, 1);
  const [year, index] = [month.getFullYear(), month.getMonth() + 1];
  const monthKey = `${year}-${String(index).padStart(2, '0')}`;
  const from = `${monthKey}-01`;
  const to = `${monthKey}-28`;

  const count = async () => (await db.query(
    'SELECT count(*)::int AS n FROM duty.duties WHERE duty_type_id = $1 AND start_date BETWEEN $2::date AND $3::date',
    [type.id, from, to])).rows[0].n;

  try {
    await db.query('DELETE FROM duty.duties WHERE duty_type_id = $1 AND start_date BETWEEN $2::date AND $3::date',
      [type.id, from, to]);
    t.is(await count(), 0, 'месяц пуст');

    const page = await get(`/duties?type=${type.id}&month=${monthKey}`);
    t.is(page.status, 200, 'график открылся');
    t.is(await count(), 0, 'открытие месяца не создало ни одного наряда');
    t.is(page.body.includes('Система подобрала состав'), false, 'и не сообщает о подборе');
    t.ok(page.body.includes('Назначить автоматически'), 'подобрать можно кнопкой');
  } finally {
    await db.query('DELETE FROM duty.duties WHERE duty_type_id = $1 AND start_date BETWEEN $2::date AND $3::date',
      [type.id, from, to]);
  }
};
