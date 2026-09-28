'use strict';

// Виды нарядов: справочник целиком правится из интерфейса, новый вид сразу
// работает в графике, заступление подряд разрешается настройкой.

const { get, post: send } = require('../lib');
const duty = require('../../services/app/modules/duty/service');
const queries = require('../../services/app/modules/duty/queries');
const db = require('../../services/app/db/pool');

const CODE = 'ЧК';

async function dropCheckType() {
  const { rows } = await db.query('SELECT id FROM duty.duty_types WHERE code = $1', [CODE]);
  for (const row of rows) {
    await db.query('DELETE FROM duty.duty_assignments a USING duty.duties d '
      + 'WHERE a.duty_id = d.id AND d.duty_type_id = $1', [row.id]);
    await db.query('DELETE FROM duty.duties WHERE duty_type_id = $1', [row.id]);
    await db.query('DELETE FROM duty.duty_posts WHERE duty_type_id = $1', [row.id]);
    await db.query('DELETE FROM duty.duty_types WHERE id = $1', [row.id]);
  }
}

/** Все настройки вида наряда правятся, включая заведенные наполнением. */
exports.карточка_вида_наряда = async (t, ctx) => {
  if (!ctx.alive) { t.ok(true, 'приложение не запущено — пропущено'); return; }

  const type = (await duty.listDutyTypes()).find((x) => x.code === 'OO');
  const card = await get(`/duty-types/${type.id}/edit`);

  t.is(card.status, 200, 'карточка вида, заведенного наполнением, открывается');

  for (const field of ['code', 'name', 'kind', 'startTime', 'sleepDays', 'offDays',
    'baseWeight', 'excludeWeekends', 'allowConsecutive', 'permitTypeIds', 'startWeekday']) {
    t.ok(card.body.includes(`name="${field}"`), `правится: ${field}`);
  }

  // Вид, по которому выпускались наряды, удалить нельзя — только снять
  // с применения.
  const refused = await send(`/duty-types/${type.id}/delete`, {});
  t.is(refused.status, 400, 'используемый вид не удаляется');
  t.ok((await duty.listDutyTypes()).some((x) => x.id === type.id), 'и остается на месте');
};

/** Новый вид заводится из интерфейса и сразу работает в графике. */
exports.новый_вид_наряда = async (t, ctx) => {
  if (!ctx.alive) { t.ok(true, 'приложение не запущено — пропущено'); return; }

  await dropCheckType();

  try {
    const created = await send('/duty-types', {
      code: CODE,
      name: 'Наряд проверки',
      kind: 'daily',
      startTime: '08:00',
      durationHours: '12',
      sleepDays: '0',
      offDays: '0',
      baseWeight: '0.5',
      allowConsecutive: 'on',
      isActive: 'on',
    });
    t.is(created.status, 302, 'вид наряда заведен');

    const made = (await duty.listAllDutyTypes()).find((x) => x.code === CODE);
    t.ok(Boolean(made), 'и виден в справочнике');
    if (!made) return;

    t.is(made.kind, 'daily', 'ежедневный');
    t.is(made.start_time, '08:00:00', 'час заступления сохранен');
    t.is(made.duration_hours, 12, 'длительность сохранена');
    t.is(made.allow_consecutive, true, 'заступление подряд разрешено');
    t.is(String(made.base_weight), '0.50', 'вес наряда сохранен');

    // Логика к кодам видов не привязана: новый вид сразу дает сутки в графике.
    const now = new Date();
    const month = new Date(now.getFullYear(), now.getMonth() + 1, 1);
    const schedule = await duty.getMonthSchedule(
      made.id, month.getFullYear(), month.getMonth() + 1, null, null,
    );
    const days = schedule.grid.flat().filter((d) => d.cell && !d.outside && !d.cell.continuation);
    t.ok(days.length >= 28, `в графике положены сутки: ${days.length}`);

    const page = await get(`/duties?type=${made.id}`);
    t.is(page.status, 200, 'график нового вида открывается');
    t.ok(page.body.includes(CODE), 'и у него своя вкладка');

    // Пока постов нет, удалить вид можно.
    const removed = await send(`/duty-types/${made.id}/delete`, {});
    t.is(removed.status, 302, 'неиспользованный вид удаляется');
    t.is((await duty.listAllDutyTypes()).some((x) => x.code === CODE), false, 'и его больше нет');
  } finally {
    await dropCheckType();
  }
};

/** Многосуточная смена требует расписания, ежедневный наряд — нет. */
exports.расписание_смены = async (t, ctx) => {
  if (!ctx.alive) { t.ok(true, 'приложение не запущено — пропущено'); return; }

  await dropCheckType();

  try {
    const base = {
      code: CODE, name: 'Смена проверки', kind: 'multiday', startTime: '17:30',
      sleepDays: '2', offDays: '0', excludeWeekends: 'on', baseWeight: '2', isActive: 'on',
    };

    const refused = await send('/duty-types', base);
    t.is(refused.status, 400, 'смена без расписания не заводится');

    const created = await send('/duty-types', {
      ...base, startWeekday: ['5', '2'], endWeekday: ['2', '5'],
    });
    t.is(created.status, 302, 'смена с расписанием заведена');

    const made = (await duty.listAllDutyTypes()).find((x) => x.code === CODE);
    const schedules = await queries.getSchedules(made.id);
    t.is(schedules.length, 2, 'оба заступления сохранены');
    t.is(schedules.map((s) => s.start_weekday).sort(), [2, 5], 'по дням недели');
    t.is(made.rest_excludes_weekends, true, 'отдых до рабочего дня сохранен');

    // Сутки в графике идут по расписанию, а не ежедневно.
    const now = new Date();
    const month = new Date(now.getFullYear(), now.getMonth() + 1, 1);
    const schedule = await duty.getMonthSchedule(
      made.id, month.getFullYear(), month.getMonth() + 1, null, null,
    );
    const starts = schedule.grid.flat().filter((d) => d.cell && d.cell.isStart && !d.outside);
    t.ok(starts.length >= 6 && starts.length <= 10,
      `заступлений в месяце по расписанию: ${starts.length}`);
  } finally {
    await dropCheckType();
  }
};

/**
 * Заступление подряд: разрешение снимает запрет по отдыху и порог очереди,
 * но только для отдыха от этого же наряда.
 */
exports.заступление_подряд = async (t) => {
  const type = (await duty.listDutyTypes()).find((x) => x.code === 'SN');
  const now = new Date();
  const month = String(now.getMonth() + 2).padStart(2, '0');
  const first = `${now.getFullYear()}-${month}-17`;
  const second = `${now.getFullYear()}-${month}-18`;

  const before = await duty.findCandidatesByPost(type.id, first, null);
  const slot = before.posts.find((p) => p.candidates.length > 1);
  if (!slot) { t.ok(true, 'кандидатов на стенде нет — пропущено'); return; }

  const person = slot.candidates[0];

  try {
    // Человек заступает в первые сутки.
    await duty.saveBlock({
      dutyTypeId: type.id,
      date: first,
      byDate: new Map([[first, new Map([[slot.post.id, person.id]])]]),
      userId: null,
    });

    // На следующие сутки он не предлагается: отсыпной и порог очереди.
    const next = await duty.findCandidatesByPost(type.id, second, null);
    const sameSlot = next.posts.find((p) => p.post.id === slot.post.id);
    t.is(sameSlot.candidates.some((c) => c.id === person.id), false,
      'сменившийся на следующие сутки не предлагается');

    // Разрешаем заступать подряд на этом посту.
    await db.query('UPDATE duty.duty_posts SET allow_consecutive = true WHERE id = $1',
      [slot.post.id]);

    const allowed = await duty.findCandidatesByPost(type.id, second, null);
    const openSlot = allowed.posts.find((p) => p.post.id === slot.post.id);
    t.is(openSlot.candidates.some((c) => c.id === person.id), true,
      'с разрешением он снова в списке');

    // ОТСЫПНОЙ ПРИ ЭТОМ НИКУДА НЕ ДЕЛСЯ: человек его отбывает и в строевой
    // записке числится отдыхающим. Разрешение снимает не отдых, а фильтр.
    const state = await duty.getDutyState(second);
    t.ok(state.resting.has(person.id), 'на эти сутки он числится в отсыпном');

    // На другом посту того же вида разрешения нет — там он по-прежнему скрыт.
    const other = allowed.posts.find((p) => p.post.id !== slot.post.id
      && before.posts.find((x) => x.post.id === p.post.id
        && x.candidates.some((c) => c.id === person.id)));
    if (other) {
      t.is(other.candidates.some((c) => c.id === person.id), false,
        'на посту без разрешения отдых по-прежнему держит');
    }

    // И состав с повтором принимается без нарушения.
    await duty.saveBlock({
      dutyTypeId: type.id,
      date: second,
      byDate: new Map([[second, new Map([[slot.post.id, person.id]])]]),
      userId: null,
    });

    const plan = await duty.getBlockPlan(type.id, second, null);
    t.is(plan.brokenTotal, 0, 'повтор подряд нарушением не считается');
  } finally {
    await db.query('UPDATE duty.duty_posts SET allow_consecutive = NULL WHERE id = $1',
      [slot.post.id]);
    for (const date of [first, second]) {
      await db.query('DELETE FROM duty.duties WHERE duty_type_id = $1 AND start_date = $2::date',
        [type.id, date]);
    }
  }
};

/**
 * Дни недели задаются и ежедневному наряду: наряд на выходные, включая
 * понедельник, задается отметкой трех дней, а не отдельным видом графика.
 */
exports.дни_недели_у_ежедневного = async (t, ctx) => {
  if (!ctx.alive) { t.ok(true, 'приложение не запущено — пропущено'); return; }

  await dropCheckType();

  try {
    const created = await send('/duty-types', {
      code: CODE, name: 'Наряд выходных дней', kind: 'daily', startTime: '09:00',
      durationHours: '24', sleepDays: '1', offDays: '0', baseWeight: '1', isActive: 'on',
      startWeekday: ['6', '7', '1'],
    });
    t.is(created.status, 302, 'вид заведен с отмеченными днями');

    const made = (await duty.listAllDutyTypes()).find((x) => x.code === CODE);
    const schedules = await queries.getSchedules(made.id);
    t.is(schedules.map((s) => s.start_weekday), [1, 6, 7], 'сохранены суббота, воскресенье и понедельник');

    const now = new Date();
    const month = new Date(now.getFullYear(), now.getMonth() + 1, 1);
    const schedule = await duty.getMonthSchedule(
      made.id, month.getFullYear(), month.getMonth() + 1, null, null,
    );
    const days = schedule.grid.flat().filter((d) => d.cell && !d.outside && !d.cell.continuation);
    const weekdays = new Set(days.map((d) => new Date(`${d.cell.startDate}T12:00:00`).getDay()));

    t.is([...weekdays].sort(), [0, 1, 6], 'в графике только эти дни недели');
    t.ok(days.length >= 11 && days.length <= 15, `суток в месяце: ${days.length}`);

    // Страница карточки предлагает отметить дни, а не заполнять расписание смены.
    const page = await get(`/duty-types/${made.id}/edit`);
    t.ok(page.body.includes('В какие дни наряд положен'), 'в карточке есть выбор дней');
    t.ok(page.body.includes('name="holidayRule"'), 'и правило нерабочих дней');
  } finally {
    await dropCheckType();
  }
};

/** Правило нерабочих дней: только в них, никогда в них, как обычно. */
exports.правило_нерабочих_дней = async (t, ctx) => {
  if (!ctx.alive) { t.ok(true, 'приложение не запущено — пропущено'); return; }

  const now = new Date();
  const month = new Date(now.getFullYear(), now.getMonth() + 1, 1);

  const countDays = async (rule) => {
    await dropCheckType();
    await send('/duty-types', {
      code: CODE, name: 'Проверка нерабочих', kind: 'daily', startTime: '09:00',
      durationHours: '24', sleepDays: '0', offDays: '0', baseWeight: '1', isActive: 'on',
      holidayRule: rule,
    });
    const made = (await duty.listAllDutyTypes()).find((x) => x.code === CODE);
    const schedule = await duty.getMonthSchedule(
      made.id, month.getFullYear(), month.getMonth() + 1, null, null,
    );
    const days = schedule.grid.flat().filter((d) => d.cell && !d.outside && !d.cell.continuation);
    const weekend = days.filter((d) => [0, 6]
      .includes(new Date(`${d.cell.startDate}T12:00:00`).getDay())).length;
    return { total: days.length, weekend, rule: made.holiday_rule };
  };

  try {
    const any = await countDays('any');
    t.is(any.rule, 'any', 'правило сохранено: как обычно');
    t.ok(any.total >= 28, `положены все сутки месяца: ${any.total}`);

    const only = await countDays('only');
    t.is(only.rule, 'only', 'правило сохранено: только в нерабочие');
    t.is(only.total, only.weekend, 'все положенные сутки — нерабочие');
    t.ok(only.total > 0 && only.total < any.total, `нерабочих суток: ${only.total}`);

    const never = await countDays('never');
    t.is(never.rule, 'never', 'правило сохранено: никогда в нерабочие');
    t.is(never.weekend, 0, 'в выходные наряд не положен');
    t.is(only.total + never.total, any.total, 'вместе оба правила дают полный месяц');
  } finally {
    await dropCheckType();
  }
};

/** Вид наряда удаляется вместе с данными — по отдельному подтверждению. */
exports.удаление_вида_с_данными = async (t, ctx) => {
  if (!ctx.alive) { t.ok(true, 'приложение не запущено — пропущено'); return; }

  await dropCheckType();

  try {
    await send('/duty-types', {
      code: CODE, name: 'Вид на удаление', kind: 'daily', startTime: '09:00',
      durationHours: '24', sleepDays: '0', offDays: '0', baseWeight: '1', isActive: 'on',
    });
    const made = (await duty.listAllDutyTypes()).find((x) => x.code === CODE);
    t.ok(Boolean(made), 'вид заведен');
    if (!made) return;

    await send('/posts', {
      dutyTypeId: String(made.id), name: `Пост вида ${CODE}`,
    });
    const posts = (await duty.listAllPosts()).filter((p) => p.duty_type_id === made.id);
    t.is(posts.length, 1, 'у вида появился пост');

    // Без подтверждения — отказ с указанием, что именно держит вид.
    const refused = await send(`/duty-types/${made.id}/delete`, {});
    t.is(refused.status, 400, 'без подтверждения вид с данными не удаляется');
    t.ok((await duty.listAllDutyTypes()).some((x) => x.id === made.id), 'и остается на месте');

    // С подтверждением уходит вместе с постами.
    const removed = await send(`/duty-types/${made.id}/delete`, { withData: 'on' });
    t.is(removed.status, 302, 'с подтверждением удаляется');
    t.is((await duty.listAllDutyTypes()).some((x) => x.id === made.id), false, 'вида больше нет');
    t.is((await duty.listAllPosts()).some((p) => p.duty_type_id === made.id), false,
      'и его постов тоже');
  } finally {
    await dropCheckType();
  }
};

/**
 * Вкладка «Наряды»: виды нарядов, внутри — их посты.
 *
 * Отдельной вкладки постов нет: пост существует только внутри вида наряда.
 * Снятые с применения посты — внизу списка своего вида.
 */
exports.вкладка_наряды = async (t, ctx) => {
  if (!ctx.alive) { t.ok(true, 'приложение не запущено — пропущено'); return; }

  const type = (await duty.listDutyTypes()).find((x) => x.code === 'SN');
  const name = `Пост вкладки ${Date.now()}`;

  // Старый адрес вкладки постов ведет в «Наряды».
  const old = await get('/posts');
  t.is(old.status, 302, 'вкладка «Посты» перенаправляет');

  const page = await get(`/duty-types?open=${type.id}`);
  t.is(page.status, 200, 'вкладка «Наряды» открывается');
  t.ok(page.body.includes(`id="type-${type.id}"`), 'вид наряда — раскрывающийся раздел');
  t.ok(page.body.includes(`/duty-types/${type.id}/edit`), 'у вида есть «изменить»');
  t.ok(page.body.includes(`/posts/new?type=${type.id}`), 'и «+» для нового поста');

  // «+» открывает форму с уже выбранным видом.
  const form = await get(`/posts/new?type=${type.id}`);
  t.ok(new RegExp(`value="${type.id}"\\s+selected`).test(form.body), 'вид в форме уже выбран');

  const created = await send('/posts', { dutyTypeId: String(type.id), name });
  t.is(created.status, 302, 'пост добавлен');
  t.ok((created.location || '').includes(`open=${type.id}`), 'и вернул к своему виду, раскрытым');

  const fresh = (await duty.listAllPosts()).find((p) => p.name === name);
  if (!fresh) { t.ok(false, 'пост не найден после добавления'); return; }

  const position = async () => {
    const body = (await get(`/duty-types?open=${type.id}`)).body;
    const start = body.indexOf(`id="type-${type.id}"`);
    const part = body.slice(start, body.indexOf('</details>', start));
    const divider = part.indexOf('Сняты с применения');
    const own = part.indexOf(name);
    return {
      active: own !== -1 && (divider === -1 || own < divider),
      below: divider !== -1 && own > divider,
    };
  };

  try {
    // Новый пост встает в конец действующих: порядок потом перетаскивается.
    const active = await duty.listPosts(type.id);
    t.is(active[active.length - 1].id, fresh.id, 'новый пост — последним среди действующих');
    t.ok((await position()).active, 'и стоит над чертой снятых');

    // Отключение — пост уходит вниз, под черту «Сняты с применения».
    await send(`/posts/${fresh.id}/active`, {});
    t.is((await duty.listAllPosts()).find((p) => p.id === fresh.id).is_active, false, 'пост отключен');
    t.ok((await position()).below, 'и опустился под черту снятых');

    // Возврат — снова наверху.
    await send(`/posts/${fresh.id}/active`, { active: 'on' });
    t.is((await duty.listAllPosts()).find((p) => p.id === fresh.id).is_active, true, 'пост возвращен');
    t.ok((await position()).active, 'и снова среди действующих');

    // Неиспользованный пост удаляется прямо из списка.
    const removed = await send(`/posts/${fresh.id}/delete`, {});
    t.is(removed.status, 302, 'пост удален из списка');
    t.is((await duty.listAllPosts()).some((p) => p.id === fresh.id), false, 'и его больше нет');
  } finally {
    await db.query('DELETE FROM duty.duty_posts WHERE name = $1', [name]);
  }
};
