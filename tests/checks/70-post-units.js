'use strict';

// Закрепление поста за подразделением: постоянное, цикличное, точечное.

const duty = require('../../services/app/modules/duty/service');
const queries = require('../../services/app/modules/duty/queries');
const org = require('../../services/app/modules/org/service');
const db = require('../../services/app/db/pool');

async function unitId(shortName) {
  const { rows } = await db.query('SELECT id FROM core.units WHERE short_name = $1', [shortName]);
  return rows[0].id;
}

async function postId(name) {
  const { rows } = await db.query('SELECT id FROM duty.duty_posts WHERE name = $1', [name]);
  return rows[0].id;
}

/**
 * Сохранение поста одной общей формой — как это делает кнопка «Сохранить».
 *
 * Очередь и закрепленные люди входят в ту же форму, поэтому форма
 * отправляется целиком: текущие настройки поста плюс то, что меняем.
 */
async function saveForm(id, changes) {
  const { post: send } = require('../lib');
  const p = await duty.getPost(id);
  const queueIds = (await duty.postQueue(id)).map((r) => String(r.unit_id));
  const boundIds = (await duty.postEmployees(id)).map(String);
  return send(`/posts/${id}`, {
    dutyTypeId: String(p.duty_type_id),
    shortName: p.short_name || '',
    name: p.name,
    requiredPermitTypeId: p.required_permit_type_id ? String(p.required_permit_type_id) : '',
    requiredWeaponKind: p.required_weapon_kind || '',
    allowConsecutive: p.allow_consecutive === true ? 'yes' : (p.allow_consecutive === false ? 'no' : ''),
    isActive: p.is_active ? 'on' : '',
    rotationSince: p.rotation_since || '',
    // Пустая строка в конце — как незаполненная строка выбора в форме.
    unitIds: [...queueIds, ''],
    employeeIds: [...boundIds, ''],
    ...changes,
  });
}

/**
 * Пост с нужным видом закрепления, найденный ПО СВОЙСТВУ, а не по названию.
 *
 * Закрепления на стенде — данные, и они меняются вместе с наполнением.
 * Проверка должна держаться за правило, а не за то, как сегодня назван пост.
 *
 * @param {string} kind 'постоянно' | 'по очереди' | 'без закрепления'
 */
async function postWith(kind) {
  const { rows } = await db.query(`
    SELECT p.id, p.name, p.duty_type_id, count(pu.unit_id)::int AS turns
    FROM duty.duty_posts p
    JOIN duty.duty_types dt ON dt.id = p.duty_type_id AND dt.code = 'SN'
    LEFT JOIN duty.post_units pu ON pu.post_id = p.id
    WHERE p.is_active
    GROUP BY p.id, p.name, p.duty_type_id
    ORDER BY p.sort_order
  `);

  const want = {
    'постоянно': (r) => r.turns === 1,
    'по очереди': (r) => r.turns > 1,
    'без закрепления': (r) => r.turns === 0,
  }[kind];

  return rows.find(want) || null;
}

/**
 * Готовый расчет ответственных для суточного наряда.
 *
 * Окно задается явно: закрепления выбираются за период, и спрашивать о
 * сутках вне окна бессмысленно — их просто не загружали.
 */
async function resolver(fromDate, toDate) {
  const type = (await duty.listDutyTypes()).find((x) => x.code === 'SN');
  const [schedules, posts] = await Promise.all([
    queries.getSchedules(type.id), queries.listPosts(type.id),
  ]);

  const now = new Date();
  const key = (d) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
  const from = fromDate || key(new Date(now.getFullYear(), now.getMonth() + 1, 1));
  const to = toDate || key(new Date(now.getFullYear(), now.getMonth() + 2, 0));

  const responsibility = await duty.postResponsibility(
    type, schedules, posts, from, to, new Map(),
  );

  return { type, posts, responsibility, from, to };
}

/** Одно подразделение в очереди — постоянное закрепление. */
exports.постоянное_закрепление = async (t) => {
  const { responsibility, from } = await resolver(undefined, '2027-01-31');
  const post = await postWith('постоянно');
  t.ok(Boolean(post), 'есть пост с постоянным закреплением');

  const answer = responsibility.at(post.id, from, from);
  t.ok(Boolean(answer), `у поста «${post.name}» есть ответственный`);
  t.is(answer.source, 'постоянно', 'источник — постоянное закрепление');

  // И так каждые сутки: постоянное закрепление от дня не зависит.
  const later = responsibility.at(post.id, '2027-01-15', '2027-01-15');
  t.is(later.unitId, answer.unitId, 'и через три месяца — то же подразделение');
};

/** Несколько подразделений — цикл по номеру заступления. */
exports.цикл_подразделений = async (t) => {
  const { responsibility } = await resolver();
  const post = await postWith('по очереди');
  t.ok(Boolean(post), 'есть пост с очередью подразделений');

  // Суточный наряд положен ежедневно, поэтому очередь чередуется по дням.
  const days = ['2026-10-01', '2026-10-02', '2026-10-03', '2026-10-04'];
  const answers = days.map((d) => responsibility.at(post.id, d, d));

  t.ok(answers.every(Boolean), 'ответственный найден на каждые сутки');
  t.ok(answers.every((a) => a.source === 'по очереди'), 'источник — очередь');

  const units = answers.map((a) => a.unitId);
  t.ok(units[0] !== units[1], 'соседние сутки достаются разным подразделениям');
  t.is(units[0], units[2], `через ${post.turns} смены очередь возвращается`);
  t.is(units[1], units[3], 'и так по кругу');
};

/** Точечное закрепление сильнее очереди и постоянного. */
exports.точечное_сильнее = async (t) => {
  const kpp = (await postWith('постоянно')).id;
  const second = await unitId('2 рота');
  const date = '2027-02-17';

  await db.query('DELETE FROM duty.post_responsibilities WHERE post_id = $1 AND on_date = $2::date',
    [kpp, date]);

  try {
    const window = () => resolver(date, '2027-02-19');
    const before = (await window()).responsibility.at(kpp, date, date);
    t.is(before.source, 'постоянно', 'до правки действует постоянное закрепление');

    await duty.setPostResponsibility(kpp, date, second, 'подмена по проверке', null);

    const after = (await window()).responsibility.at(kpp, date, date);
    t.is(after.unitId, second, 'точечное закрепление перебило постоянное');
    t.is(after.source, 'точечно', 'источник — ручное решение');
    t.is(after.note, 'подмена по проверке', 'причина сохранена');

    // Соседние сутки не затронуты: правится один день, а не порядок.
    const neighbour = (await window()).responsibility.at(kpp, '2027-02-18', '2027-02-18');
    t.is(neighbour.source, 'постоянно', 'соседние сутки идут прежним порядком');

    await duty.setPostResponsibility(kpp, date, null, null, null);
    t.is((await window()).responsibility.at(kpp, date, date).source, 'постоянно',
      'снятие точечного возвращает общий порядок');
  } finally {
    await db.query('DELETE FROM duty.post_responsibilities WHERE post_id = $1 AND on_date = $2::date',
      [kpp, date]);
  }
};

/**
 * Закрепления всего наряда нет: ответственный задается только по постам.
 *
 * Уровень «весь наряд» упразднен (решение 121) — он дублировал закрепление
 * постов и путал, откуда взялся ответственный. Пост без своей очереди —
 * общий, ответственного у него нет.
 */
exports.закрепления_всего_наряда_нет = async (t, ctx) => {
  const free = await postWith('без закрепления');
  const date = '2027-02-24';

  if (free) {
    const { responsibility } = await resolver(date, '2027-02-25');
    t.is(responsibility.at(free.id, date, date), null,
      `у поста «${free.name}» без очереди ответственного нет`);
  }

  // Закрепление постов работает как прежде.
  const kept = await postWith('постоянно');
  const { responsibility } = await resolver(date, '2027-02-25');
  t.is(responsibility.at(kept.id, date, date).source, 'постоянно',
    'очередь поста действует');

  if (!ctx.alive) { t.ok(true, 'страницы не проверены — приложение не запущено'); return; }

  const { get, post: send } = require('../lib');
  const type = (await duty.listDutyTypes()).find((x) => x.code === 'SN');

  // Маршрута закрепления всего наряда больше нет.
  const gone = await send('/duties/responsibility',
    { dutyTypeId: String(type.id), date, unitId: String(await unitId('1 рота')) });
  t.is(gone.status, 404, 'закрепить весь наряд больше нельзя');

  // В форме назначения нет «Закрепить за приказом», а закрепление поста есть.
  const page = await get(`/duties/plan?type=${type.id}&date=${date}`);
  t.is(page.status, 200, 'страница назначения открывается');
  t.is(page.body.includes('Закрепить за приказом'), false, 'формы закрепления наряда нет');
  t.ok(page.body.includes('/duties/post-responsibility'), 'точечное закрепление поста осталось');
};

/** Очередь правится целиком и проверяется на повторы. */
exports.правка_очереди = async (t) => {
  const post = await postId('Дневальный по 1-й роте — 1');
  const restore = (await duty.listPostUnits(null)).filter((q) => q.post_id === post);
  const [first, second] = [await unitId('1 рота'), await unitId('2 рота')];

  try {
    await t.fails(
      () => duty.setPostUnits(post, [first, first], '2026-09-01'),
      'одно подразделение дважды в очереди',
    );
    await t.fails(
      () => duty.setPostUnits(post, [first, second], null),
      'цикл без опорных суток',
    );

    // Одно подразделение — опорные сутки не нужны: очередь не сдвигается.
    await duty.setPostUnits(post, [first], null);
    let queue = (await duty.listPostUnits(null)).filter((q) => q.post_id === post);
    t.is(queue.length, 1, 'постоянное закрепление задано');

    await duty.setPostUnits(post, [second, first], '2026-09-01');
    queue = (await duty.listPostUnits(null)).filter((q) => q.post_id === post);
    t.is(queue.map((q) => q.unit_id), [second, first], 'порядок очереди сохранен');

    await duty.setPostUnits(post, [], null);
    queue = (await duty.listPostUnits(null)).filter((q) => q.post_id === post);
    t.is(queue.length, 0, 'очередь снимается целиком');
  } finally {
    // Стенд возвращается в прежнее состояние: закрепления — данные, на
    // которых держится подбор, и проверка не должна их стирать.
    await duty.setPostUnits(post,
      restore.sort((a, b) => a.turn - b.turn).map((q) => q.unit_id), '2026-09-01');
  }
};

/**
 * Очередь настраивается со страницы поста, и график ее подхватывает.
 *
 * Это и есть смысл настройки: начальник службы задает, кто заступает, а
 * график уже сам показывает эти сутки командиру и предлагает людей оттуда.
 */
exports.настройка_очереди_со_страницы_поста = async (t, ctx) => {
  if (!ctx.alive) { t.ok(true, 'приложение не запущено — пропущено'); return; }

  const { get, post: send } = require('../lib');

  const target = await postWith('постоянно');
  t.ok(Boolean(target), 'есть пост с закреплением');
  if (!target) return;

  const restore = await duty.postQueue(target.id);
  const second = await unitId('2 рота');
  const first = await unitId('1 рота');
  const other = restore.some((r) => r.unit_id === second) ? first : second;

  try {
    // Очередь правится прямо в общей форме поста, отдельных форм под ней нет.
    const page = await get(`/posts/${target.id}/edit`);
    t.is(page.status, 200, 'страница поста открылась');
    t.ok(page.body.includes('Кто заступает на пост'), 'в форме есть раздел заступающих');
    t.ok(/<select name="unitIds">/.test(page.body), 'подразделения выбираются в самой форме');
    t.is(/\/posts\/\d+\/(units|employees)\//.test(page.body), false,
      'отдельных форм очереди и состава под основной нет');
    t.ok(page.body.includes('+ ещё подразделение'), 'строку очереди можно добавить');

    // Перечень постов (внутри вкладки «Наряды») называет заступающие
    // подразделения и не показывает ни очереди в таблице, ни состояния поста.
    const list = await get(`/duty-types?open=${target.duty_type_id || ''}`);
    t.ok(list.body.includes('Подразделения'), 'в перечне графа «Подразделения»');
    t.is(list.body.includes('Очередь подразделений'), false, 'таблица очереди убрана');
    t.is(list.body.includes('применяется</span>'), false, 'графа состояния убрана');

    const current = restore.map((r) => String(r.unit_id));
    const added = await saveForm(target.id, { unitIds: [...current, String(other), ''] });
    t.is(added.status, 302, 'подразделение добавлено в очередь');

    const queue = await duty.postQueue(target.id);
    t.is(queue.length, restore.length + 1, 'очередь стала длиннее на одно');
    t.is(queue[queue.length - 1].unit_id, other, 'добавленное встало в конец');

    // Повтор отклоняется: одно подразделение не может стоять в очереди дважды.
    const again = await saveForm(target.id,
      { unitIds: [...current, String(other), String(other)] });
    t.is(again.status, 400, 'то же подразделение второй раз не добавляется');
    t.is((await duty.postQueue(target.id)).length, restore.length + 1,
      'отказ ничего не сломал: очередь прежняя');

    // Опорные сутки для цикла проставлены сами — иначе настройка требовала бы
    // указать дату отсчета цикла, которого еще нет.
    const { rows } = await db.query(
      "SELECT to_char(rotation_since,'YYYY-MM-DD') AS since FROM duty.duty_posts WHERE id = $1",
      [target.id],
    );
    t.ok(Boolean(rows[0].since), 'сутки отсчета очереди заданы');

    const since = await saveForm(target.id, { rotationSince: '2026-09-01' });
    t.is(since.status, 302, 'сутки отсчета правятся');

    // ГЛАВНОЕ: график считает ответственных по этой настройке.
    const { responsibility } = await resolver('2026-10-01', '2026-10-05');
    const answers = ['2026-10-01', '2026-10-02'].map((d) => responsibility.at(target.id, d, d));

    t.ok(answers.every((a) => a && a.source === 'по очереди'),
      'в графике пост пошел по очереди');
    t.ok(answers[0].unitId !== answers[1].unitId,
      'и соседние сутки достались разным подразделениям');
    t.ok(answers.some((a) => a.unitId === other),
      'добавленное подразделение попало в очередь графика');

    const removed = await saveForm(target.id, { unitIds: [...current, ''] });
    t.is(removed.status, 302, 'подразделение исключается');
    t.is((await duty.postQueue(target.id)).length, restore.length, 'очередь вернулась к прежней');
  } finally {
    await duty.setPostUnits(target.id, restore.map((r) => r.unit_id),
      restore.length > 1 ? '2026-09-01' : null);
  }
};

/**
 * Подразделение поста — следствие очереди, а не отдельная настройка.
 *
 * Два поля об одном расходились при первой же правке: на стенде нашелся пост
 * с подразделением, но без очереди.
 */
exports.подразделение_следует_за_очередью = async (t) => {
  const target = await postWith('постоянно');
  t.ok(Boolean(target), 'есть пост с закреплением');
  if (!target) return;

  const restore = await duty.postQueue(target.id);
  const [first, second] = [await unitId('1 рота'), await unitId('2 рота')];
  const post = async () => (await duty.listAllPosts()).find((p) => p.id === target.id);

  try {
    await duty.setPostUnits(target.id, [first], null);
    t.is((await post()).unit_id, first, 'одно подразделение стало подразделением поста');

    await duty.setPostUnits(target.id, [first, second], '2026-09-01');
    t.is((await post()).unit_id, null, 'при очереди пост становится общим');

    await duty.setPostUnits(target.id, [], null);
    t.is((await post()).unit_id, null, 'без очереди подразделения у поста нет');

    // Ни одного расхождения по всей базе: правило одно для всех постов.
    const { rows } = await db.query(`
      SELECT count(*)::int AS n FROM duty.duty_posts p
      WHERE (p.unit_id IS NOT NULL)
         <> ((SELECT count(*) FROM duty.post_units q WHERE q.post_id = p.id) = 1)
    `);
    t.is(rows[0].n, 0, 'подразделение и очередь согласованы у всех постов');
  } finally {
    await duty.setPostUnits(target.id, restore.map((r) => r.unit_id),
      restore.length > 1 ? '2026-09-01' : null);
  }
};

/** Пост удаляется, пока он нигде не использован. */
exports.удаление_поста = async (t, ctx) => {
  if (!ctx.alive) { t.ok(true, 'приложение не запущено — пропущено'); return; }

  const { get, post: send } = require('../lib');

  const type = (await duty.listDutyTypes()).find((x) => x.code === 'SN');
  const name = `Пост проверки ${Date.now()}`;

  // Очередь задается сразу при создании — той же формой.
  const created = await send('/posts', {
    dutyTypeId: String(type.id), name,
    unitIds: [String(await unitId('1 рота')), ''],
  });
  t.is(created.status, 302, 'пост заведен');

  const fresh = (await duty.listAllPosts()).find((p) => p.name === name);
  t.ok(Boolean(fresh), 'и виден в справочнике');
  if (!fresh) return;

  try {
    t.is((await duty.postQueue(fresh.id)).length, 1, 'очередь задана при создании');

    const page = await get(`/posts/${fresh.id}/edit`);
    t.ok(page.body.includes(`/posts/${fresh.id}/delete`), 'на странице есть удаление');

    const removed = await send(`/posts/${fresh.id}/delete`, {});
    t.is(removed.status, 302, 'пост удален');
    t.ok((removed.location || '').startsWith('/duty-types'),
      'и открылась вкладка «Наряды» со своим видом');

    t.is((await duty.listAllPosts()).some((p) => p.id === fresh.id), false, 'поста больше нет');

    const { rows } = await db.query('SELECT count(*)::int AS n FROM duty.post_units WHERE post_id = $1',
      [fresh.id]);
    t.is(rows[0].n, 0, 'его настройки удалены вместе с ним');
  } finally {
    await db.query('DELETE FROM duty.duty_posts WHERE name = $1', [name]);
  }
};

/** Пост, стоявший в нарядах, не удаляется: приказы должны остаться читаемыми. */
exports.использованный_пост_не_удаляется = async (t, ctx) => {
  if (!ctx.alive) { t.ok(true, 'приложение не запущено — пропущено'); return; }

  const { get, post: send } = require('../lib');

  const { rows } = await db.query(`
    SELECT p.id, p.name, count(*)::int AS n
    FROM duty.duty_posts p JOIN duty.duty_assignments a ON a.post_id = p.id
    GROUP BY p.id, p.name LIMIT 1
  `);
  if (rows.length === 0) { t.ok(true, 'назначений на стенде нет — пропущено'); return; }

  const used = rows[0];
  const refused = await send(`/posts/${used.id}/delete`, {});
  t.is(refused.status, 400, `пост «${used.name}» удалить нельзя`);

  const page = await get(`/posts/${used.id}/edit`);
  t.is(page.body.includes(`/posts/${used.id}/delete`), false, 'и кнопки удаления нет');
  t.ok(page.body.includes('снимается с применения'), 'вместо нее сказано, что делать');

  t.ok((await duty.listAllPosts()).some((p) => p.id === used.id), 'пост на месте');
};

/** Пост переносится в другой вид наряда, настройки при этом остаются. */
exports.смена_вида_наряда = async (t, ctx) => {
  if (!ctx.alive) { t.ok(true, 'приложение не запущено — пропущено'); return; }

  const { get, post: send } = require('../lib');

  const types = await duty.listDutyTypes();
  const from = types.find((x) => x.code === 'SN');
  const to = types.find((x) => x.code === 'OD');
  const name = `Пост переноса ${Date.now()}`;

  await send('/posts', {
    dutyTypeId: String(from.id), name,
    unitIds: [String(await unitId('1 рота'))],
  });
  const fresh = (await duty.listAllPosts()).find((p) => p.name === name);
  t.ok(Boolean(fresh), 'пост заведен');
  if (!fresh) return;

  try {
    // Вид наряда правится наравне с остальным: в карточке это список, а не
    // запись для чтения.
    const page = await get(`/posts/${fresh.id}/edit`);
    t.ok(/select name="dutyTypeId"/.test(page.body), 'вид наряда — выбор, а не надпись');
    t.is(/field-label">Подразделение/.test(page.body), false,
      'отдельного поля подразделения в карточке нет');

    const moved = await saveForm(fresh.id, { dutyTypeId: String(to.id) });
    t.is(moved.status, 302, 'вид наряда изменен');

    const after = (await duty.listAllPosts()).find((p) => p.id === fresh.id);
    t.is(after.duty_code, to.code, `пост перешел в ${to.code}`);
    t.is(after.is_active, true, 'и остался применяемым');

    // Настройки поста перенос переживают: заводить их заново незачем.
    t.is((await duty.postQueue(fresh.id)).length, 1, 'очередь подразделений сохранилась');

    // Пост виден в новом виде наряда и пропал из прежнего.
    const now = (await duty.listPosts(to.id)).some((p) => p.id === fresh.id);
    const was = (await duty.listPosts(from.id)).some((p) => p.id === fresh.id);
    t.is(now, true, 'в новом виде наряда пост есть');
    t.is(was, false, 'в прежнем его больше нет');
  } finally {
    await db.query('DELETE FROM duty.duty_posts WHERE name = $1', [name]);
  }
};

/**
 * Закрепление личного состава за постом сужает круг кандидатов.
 *
 * Допущенных больше, чем тех, кто ходит: допуск говорит «этому можно», а
 * закрепление — «ходят эти».
 */
exports.закрепление_состава_за_постом = async (t, ctx) => {
  if (!ctx.alive) { t.ok(true, 'приложение не запущено — пропущено'); return; }

  const { get, post: send } = require('../lib');

  const type = (await duty.listDutyTypes()).find((x) => x.code === 'SN');
  const now = new Date();
  const date = `${now.getFullYear()}-${String(now.getMonth() + 2).padStart(2, '0')}-19`;

  const selection = await duty.findCandidatesByPost(type.id, date, null);
  const slot = selection.posts.find((p) => p.candidates.length > 3);
  if (!slot) { t.ok(true, 'поста с запасом кандидатов нет — пропущено'); return; }

  // Закрепляются люди из заступающих подразделений: чужих пост не принимает.
  const queue = await duty.postQueue(slot.post.id);
  const allowed = new Set();
  for (const row of queue) for (const id of await org.subtreeIds(row.unit_id)) allowed.add(id);

  const own = queue.length === 0 ? slot.candidates
    : slot.candidates.filter((c) => allowed.has(c.unit_id));
  if (own.length < 2) { t.ok(true, 'кандидатов из своих подразделений мало — пропущено'); return; }

  const chosen = own.slice(0, 2);

  try {
    const page = await get(`/posts/${slot.post.id}/edit`);
    t.ok(page.body.includes('Кто ходит на пост'), 'в карточке поста есть раздел состава');
    t.ok(/<select name="employeeIds">/.test(page.body), 'люди выбираются в самой форме');
    t.is(page.body.includes('/employees/add'), false, 'отдельной формы закрепления нет');

    const added = await saveForm(slot.post.id,
      { employeeIds: [...chosen.map((x) => String(x.id)), ''] });
    t.is(added.status, 302, 'закреплены двое одним сохранением');

    t.is((await duty.postEmployees(slot.post.id)).length, chosen.length, 'оба в перечне');

    // Кандидатами стали только они — при том что допущенных было больше.
    const after = await duty.findCandidatesByPost(type.id, date, null);
    const narrowed = after.posts.find((p) => p.post.id === slot.post.id);

    t.ok(narrowed.candidates.length <= chosen.length,
      `кандидатов стало ${narrowed.candidates.length} из ${slot.candidates.length}`);
    t.ok(narrowed.candidates.every((c) => chosen.some((x) => x.id === c.id)),
      'и все они из закрепленных');

    // Подбор берет оттуда же: настройка действует и на автоматический выбор.
    const picked = narrowed.candidates[0];
    t.ok(Boolean(picked), 'кандидат для подбора остался');
    if (picked) {
      t.ok(chosen.some((x) => x.id === picked.id), 'подбор предложит закрепленного');
    }

    // Человек из чужого подразделения за пост не закрепляется: две настройки
    // об одном посте не должны противоречить друг другу.
    if (queue.length > 0) {
      const { rows } = await db.query(`
        SELECT id FROM personnel.employees
        WHERE is_active AND NOT (unit_id = ANY($1::int[])) LIMIT 1
      `, [[...allowed]]);
      if (rows.length > 0) {
        const refused = await saveForm(slot.post.id,
          { employeeIds: [...chosen.map((x) => String(x.id)), String(rows[0].id)] });
        t.is(refused.status, 400, 'чужой для поста человек не закрепляется');
        t.is((await duty.postEmployees(slot.post.id)).length, chosen.length,
          'и отказ не тронул перечень');
      }
    }

    const removed = await saveForm(slot.post.id, { employeeIds: [''] });
    t.is(removed.status, 302, 'перечень очищен');

    // Пустой перечень возвращает прежнее поведение — предлагаются все допущенные.
    const restored = await duty.findCandidatesByPost(type.id, date, null);
    const back = restored.posts.find((p) => p.post.id === slot.post.id);
    t.is(back.candidates.length, slot.candidates.length, 'без закрепления снова все допущенные');
  } finally {
    await db.query('DELETE FROM duty.post_employees WHERE post_id = $1', [slot.post.id]);
  }
};

/**
 * Порядок постов меняется перетаскиванием и хранится в базе — значит, виден
 * всем и в следующих сеансах, а не только в браузере того, кто тянул.
 */
exports.порядок_постов_перетаскиванием = async (t, ctx) => {
  if (!ctx.alive) { t.ok(true, 'приложение не запущено — пропущено'); return; }

  const { get, post: send } = require('../lib');

  const type = (await duty.listDutyTypes()).find((x) => x.code === 'SN');
  const before = await duty.listPosts(type.id);
  t.ok(before.length > 2, 'у вида есть что переставлять');
  if (before.length < 2) return;

  const saved = before.map((p) => [p.id, p.sort_order]);

  try {
    const page = await get(`/duty-types?open=${type.id}`);
    t.ok(page.body.includes(`data-sortable="/duty-types/${type.id}/posts/order"`),
      'перечень постов умеет перетаскивание');
    t.ok(page.body.includes(`data-sort-id="${before[0].id}"`), 'строка поста — элемент списка');
    t.ok(page.body.includes('drag-handle'), 'у строк есть ручка');

    // Как после броска: последний пост поднят наверх.
    const wanted = [before[before.length - 1], ...before.slice(0, -1)].map((p) => p.id);
    const moved = await send(`/duty-types/${type.id}/posts/order`, { ids: wanted.map(String) });
    t.is(moved.status, 200, 'порядок сохранен');

    const after = await duty.listPosts(type.id);
    t.is(after.map((p) => p.id).join(','), wanted.join(','), 'посты идут в новом порядке');
    t.is(after[0].sort_order, 10, 'нумерация с шагом 10');

    // Неполный перечень отклоняется: пропущенный пост остался бы со старым
    // номером вперемешку с новыми.
    const partial = await send(`/duty-types/${type.id}/posts/order`,
      { ids: wanted.slice(1).map(String) });
    t.is(partial.status, 400, 'неполный перечень не принимается');

    const doubled = await send(`/duty-types/${type.id}/posts/order`,
      { ids: [...wanted.slice(0, -1), wanted[0]].map(String) });
    t.is(doubled.status, 400, 'повтор поста не принимается');

    t.is((await duty.listPosts(type.id)).map((p) => p.id).join(','), wanted.join(','),
      'отказы порядок не тронули');
  } finally {
    for (const [id, order] of saved) {
      await db.query('UPDATE duty.duty_posts SET sort_order = $2 WHERE id = $1', [id, order]);
    }
  }
};
