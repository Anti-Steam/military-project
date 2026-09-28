'use strict';

// Публичный интерфейс модуля «Наряды».
//
// Данные о людях запрашиваются ТОЛЬКО через personnel/service.js.
// Прямых обращений к таблицам схемы personnel здесь нет — это условие
// делает последующее выделение МС-1 и МС-2 в отдельные сервисы дешевым.

const queries = require('./queries');
const filter = require('./candidateFilter');
const cal = require('./calendar');
const queue = require('./queue');
const personnel = require('../personnel/service');
const declension = require('../../lib/declension');
const orderTemplate = require('./order-template');
const org = require('../org/service');
const db = require('../../db/pool');
const v = require('../../lib/validation');
const access = require('../access/service');

async function listDutyTypes() {
  return queries.listDutyTypes();
}

async function listUnits() {
  return queries.listUnits();
}

/** Наряды человека за период — для «Моих данных». */
async function employeeAssignments(employeeId, from, to) {
  return queries.employeeAssignments(v.id(employeeId), v.date(from), v.date(to));
}

async function listDuties() {
  return queries.listDuties();
}

// ----------------------------------------------------------------------------
// Справочник видов нарядов
//
// Вид наряда задает правила, по которым живет весь график: когда заступают,
// сколько несут службу, сколько отдыхают, чем этот наряд весит при
// балансировке и какие допуски нужны. Логика к конкретным видам не привязана
// — она работает через признак kind и расписание, — поэтому новый вид
// включается в работу сразу, как только заведен.
// ----------------------------------------------------------------------------

const KINDS = new Set(['daily', 'multiday']);
const HOLIDAY_RULES = new Set(['any', 'only', 'never']);

async function listAllDutyTypes() {
  return queries.listAllDutyTypes();
}

async function getDutyTypeCard(id) {
  const type = await queries.getDutyType(v.id(id));
  if (!type) return null;

  const [schedules, permits, usage, allPermitTypes] = await Promise.all([
    queries.getSchedules(type.id),
    queries.getGeneralPermits(type.id),
    queries.dutyTypeUsage(type.id),
    personnel.listPermitTypes(),
  ]);

  return { type, schedules, permits, usage, allPermitTypes };
}

/**
 * Разбор и проверка настроек вида наряда.
 *
 * Отказ здесь дешевле странного графика потом: наряд без часа заступления
 * или смена без расписания не сломают систему, но дадут сутки, которых никто
 * не ждал.
 */
function checkDutyType(data) {
  const code = String(data.code || '').trim().toUpperCase();
  const name = String(data.name || '').trim();

  if (!code) v.fail('Укажите обозначение вида наряда.');
  if (code.length > 16) v.fail('Обозначение длиннее 16 знаков.');
  if (!name) v.fail('Укажите наименование вида наряда.');
  if (!KINDS.has(data.kind)) v.fail('Выберите, ежедневный это наряд или многосуточная смена.');

  const startTime = String(data.startTime || '').trim();
  if (!/^(?:[01]\d|2[0-3]):[0-5]\d(?::[0-5]\d)?$/.test(startTime)) v.fail('Укажите час заступления.');

  const number = (value, label, { min = 0, max = 99 } = {}) => {
    const n = Number(String(value).replace(',', '.'));
    if (!Number.isFinite(n)) v.fail(`${label}: нужно число.`);
    if (n < min || n > max) v.fail(`${label}: значение вне пределов (${min}–${max}).`);
    return n;
  };

  const kind = data.kind;
  const durationHours = kind === 'multiday' ? null
    : number(data.durationHours || 24, 'Длительность', { min: 1, max: 24 * 14 });

  return {
    code,
    name,
    kind,
    startTime,
    durationHours,
    sleepDays: number(data.sleepDays || 0, 'Отсыпной', { max: 30 }),
    offDays: number(data.offDays || 0, 'Выходной', { max: 30 }),
    excludeWeekends: Boolean(data.excludeWeekends),
    baseWeight: number(data.baseWeight || 1, 'Вес наряда', { min: 0, max: 100 }),
    allowConsecutive: Boolean(data.allowConsecutive),
    holidayRule: HOLIDAY_RULES.has(data.holidayRule) ? data.holidayRule : 'any',
    isActive: data.isActive === undefined ? true : Boolean(data.isActive),
  };
}

/**
 * Расписание многосуточной смены: пары «день заступления — день сдачи».
 *
 * Для ежедневного наряда расписание не нужно: он положен каждые сутки, и
 * хранить для него семь одинаковых строк незачем.
 */
function checkSchedules(kind, items, startTime) {
  // У ежедневного наряда строка расписания означает «в этот день недели наряд
  // положен»; день сдачи в ней тот же и не используется. Пустой перечень —
  // наряд положен каждые сутки, как было всегда.
  if (kind !== 'multiday') {
    const days = [...new Set((items || [])
      .map((i) => Number(i.startWeekday))
      .filter((n) => Number.isInteger(n) && n >= 1 && n <= 7))];
    return days.sort().map((day) => ({ startWeekday: day, endWeekday: day, startTime }));
  }

  const rows = items
    .filter((i) => i.startWeekday && i.endWeekday)
    .map((i) => ({
      startWeekday: v.id(i.startWeekday),
      endWeekday: v.id(i.endWeekday),
      startTime,
    }));

  for (const row of rows) {
    if (row.startWeekday > 7 || row.endWeekday > 7) v.fail('День недели вне пределов.');
  }

  if (rows.length === 0) {
    v.fail('У многосуточной смены должно быть хотя бы одно заступление в расписании.');
  }

  const seen = new Set();
  for (const row of rows) {
    if (seen.has(row.startWeekday)) v.fail('Два заступления в один и тот же день недели.');
    seen.add(row.startWeekday);
  }

  return rows;
}

async function createDutyType(data) {
  const checked = checkDutyType(data);
  const schedules = checkSchedules(checked.kind, data.schedules || [], checked.startTime);

  const id = await queries.createDutyType(checked);
  await queries.setSchedules(id, schedules);
  await queries.setGeneralPermits(id, (data.permitTypeIds || []).map((x) => v.id(x)));
  return id;
}

async function updateDutyType(id, data) {
  const typeId = v.id(id);
  const current = await queries.getDutyType(typeId);
  if (!current) v.fail('Вид наряда не найден.', 404);

  const checked = checkDutyType(data);
  const schedules = checkSchedules(checked.kind, data.schedules || [], checked.startTime);

  const oldSchedules = await queries.getSchedules(typeId);
  const scheduleKey = rows => JSON.stringify(rows.map(r => [Number(r.startWeekday ?? r.start_weekday), Number(r.endWeekday ?? r.end_weekday)]).sort((a,b) => a[0]-b[0]));
  const changed = current.kind !== checked.kind
    || String(current.start_time).padEnd(8, ':00') !== checked.startTime.padEnd(8, ':00')
    || Number(current.duration_hours) !== Number(checked.durationHours)
    || current.holiday_rule !== checked.holidayRule
    || scheduleKey(oldSchedules) !== scheduleKey(schedules);
  if (changed) {
    const { rows } = await db.query('SELECT 1 FROM duty.duties WHERE duty_type_id=$1 AND ends_at > now() LIMIT 1', [typeId]);
    if (rows.length) v.fail('Сначала удалите будущие наряды; график действующих нарядов изменять нельзя.');
  }

  await queries.updateDutyType(typeId, checked);
  await queries.setSchedules(typeId, schedules);
  await queries.setGeneralPermits(typeId, (data.permitTypeIds || []).map((x) => v.id(x)));

  // Правила изменились — подписанный состав должен быть пересмотрен: он
  // утверждался по прежним часам, отдыху и допускам.
  await invalidateType(typeId);
}

/**
 * Удаление вида наряда.
 *
 * Вид, по которому уже выпускались наряды, не удаляется: приказы на него
 * ссылаются. Такой вид снимается с применения — он исчезает из графика, а
 * прошлое остается читаемым.
 */
async function removeDutyType(id, { withData = false } = {}) {
  const typeId = v.id(id);
  const type = await queries.getDutyType(typeId);
  if (!type) v.fail('Вид наряда не найден.', 404);

  const usage = await queries.dutyTypeUsage(typeId);

  // Вид с нарядами и постами удаляется ТОЛЬКО по отдельному подтверждению:
  // вместе с ним уходят приказы прошлых периодов, и случайного щелчка для
  // этого мало. Обычный путь для отжившего вида — снять с применения.
  if (!withData && (usage.duties > 0 || usage.posts > 0)) {
    v.fail(`Вид используется: нарядов ${usage.duties}, постов ${usage.posts}. `
      + 'Снимите его с применения либо подтвердите удаление вместе с данными.');
  }

  await queries.deleteDutyType(typeId);
  return { type, usage };
}

// ----------------------------------------------------------------------------
// Справочник постов
// ----------------------------------------------------------------------------

async function listPosts(dutyTypeId) {
  return queries.listPosts(dutyTypeId);
}

async function listAllPosts() {
  return queries.listAllPosts();
}

async function getPost(id) {
  return queries.getPost(id);
}

async function createPost(data) {
 await validatePost(data);
 const id=await queries.createPost(data);
 await invalidateType(data.dutyTypeId);return id;
}

/**
 * Правка поста, включая ПЕРЕНОС В ДРУГОЙ ВИД НАРЯДА.
 *
 * Перенос разрешен: пост заводят и ошибаются видом, а заводить его заново
 * значит терять настройки. Прошлые наряды при этом не портятся — они хранят
 * назначения, и приказ печатается по ним. Утверждение будущих приказов
 * снимается у ОБОИХ видов: у прежнего пост из состава ушел, у нового
 * появился, и подписанный состав должен быть пересмотрен.
 */
async function updatePost(id,data) {
 v.id(id);const post=await queries.getPost(id);if(!post) v.fail('Пост не найден.',404);
 const dutyTypeId=data.dutyTypeId ? v.id(data.dutyTypeId) : post.duty_type_id;
 if(dutyTypeId!==post.duty_type_id
    && !(await queries.listDutyTypes()).some(t=>t.id===dutyTypeId)) v.fail('Неизвестный вид наряда.');
 await validatePost({...data,dutyTypeId});
 await queries.updatePost(id,{...data,dutyTypeId});
 await invalidateType(post.duty_type_id);
 if(dutyTypeId!==post.duty_type_id) await invalidateType(dutyTypeId);
}

// ----------------------------------------------------------------------------
// Подбор состава
// ----------------------------------------------------------------------------

/**
 * Кандидаты по каждому посту наряда.
 *
 * Порядок отбора:
 *   1. Определяется период заступления и сдачи.
 *   2. Берется перечень действующих постов вида наряда.
 *   3. Выясняются общие допуски, обязательные для этого вида наряда.
 *   4. Модуль «Личный состав» возвращает кандидатов по каждому посту:
 *      в наличии, с общими допусками и с постовым допуском именно к нему.
 *   5. Исключаются уже занятые в пересекающемся наряде.
 */
/**
 * @param {?number} exceptDutyId  наряд, назначения которого не считать
 *   занятостью. Нужен при правке состава существующего наряда: иначе уже
 *   назначенные в него попадали бы в занятые и не могли быть ни оставлены
 *   на своем посту, ни переставлены на другой.
 */
async function findCandidatesByPost(dutyTypeId, startDate, exceptDutyId) {
  const dutyType = await queries.getDutyType(dutyTypeId);
  if (!dutyType) throw new Error(`Вид наряда не найден: ${dutyTypeId}`);

  const [schedules, posts, generalPermits] = await Promise.all([
    queries.getSchedules(dutyTypeId),
    queries.listPosts(dutyTypeId),
    queries.getGeneralPermits(dutyTypeId),
  ]);

  const period = filter.computePeriod(dutyType, schedules, startDate);

  // Посты со своим графиком отбираются не на весь наряд, а на каждый свой
  // выход: ПТСО и ПУД сменяются ежедневно, и занятость, отдых и допуски у
  // них считаются на часы выхода, а не на трое суток смены.
  const permanentPosts = posts.filter((p) => !cal.isShiftPost(p));
  const shiftPosts = posts.filter(cal.isShiftPost);
  const shifts = cal.shiftsByDate(period, shiftPosts);

  const permitTypeIds = generalPermits.map((p) => p.permit_type_id);
  const exceptIds = exceptDutyId ? [exceptDutyId] : [];

  // Нагрузка считается за 30 суток до заступления: балансировка ведется
  // циклами (раздел 8.6), и вес прошлогоднего наряда к текущему распределению
  // отношения не имеет.
  const workloadFrom = cal.addDays(startDate, -30);

  const [calendarDays, workload, settingRows, lastStarts, rankWeights, personalWeights,
    postEmployeeRows]
    = await Promise.all([
      queries.listCalendarDays(cal.addDays(startDate, -740), cal.addDays(startDate, 740)),
      queries.employeeWorkload(workloadFrom, startDate),
      queries.listSettings(),
      queries.lastDutyEnds(period.startsAt),
      queries.listPostRankWeights(dutyTypeId),
      queries.listEmployeePostWeights(dutyTypeId),
      queries.listPostEmployees(null),
    ]);

  // Закрепленный за постом состав: если он задан, кандидатами считаются
  // только эти люди. Допущенных бывает вдвое больше, чем тех, кто реально
  // ходит, и предлагать всех — значит каждый раз отсеивать лишних глазами.
  const boundToPost = new Map();
  for (const row of postEmployeeRows) {
    if (!boundToPost.has(row.post_id)) boundToPost.set(row.post_id, new Set());
    boundToPost.get(row.post_id).add(row.employee_id);
  }

  const exceptions = new Map(calendarDays.map((d) => [d.day, d.kind]));
  const load = new Map(workload.map((w) => [w.employee_id, w]));

  // Очередь заступления: кто дольше не был, тот и первый, с поправкой на
  // накопленную нагрузку и на соответствие посту.
  const settings = queue.settingsFrom(settingRows);
  const lastByEmployee = new Map(lastStarts.map((r) => [r.employee_id, r.last_date]));
  const rankWeight = new Map(rankWeights.map((w) => [`${w.post_id}|${w.rank_id}`, w.weight]));
  const personalWeight = new Map(
    personalWeights.map((w) => [`${w.post_id}|${w.employee_id}`, w.weight]),
  );

  let unfilled = 0;
  // Считаются люди, а не вхождения: один человек допущен к нескольким постам
  // и иначе учитывался бы несколько раз.
  const restingSeen = new Set();
  const justRestedAll = new Map();

  /**
   * Подбор по набору постов на один интервал.
   *
   * Один и тот же порядок отбора служит и постоянному составу смены, и
   * отдельному выходу посменного поста — меняются только интервал и норма
   * отдыха. Второй реализации правил, способной разойтись с первой, нет.
   */
  async function select(subset, interval, onDate, sleepDays, excludeWeekends) {
    if (subset.length === 0) return [];

    const [byPost, busyIds, recentEnds] = await Promise.all([
      personnel.findCandidatesForPosts(
        onDate, permitTypeIds, subset, interval.startsAt, interval.endsAt,
      ),
      queries.findBusyEmployeeIds(interval.startsAt, interval.endsAt, exceptDutyId),
      queries.findRecentDutyEnds(interval.startsAt, exceptIds),
    ]);

    // Отсыпной проверяется в обе стороны.
    //
    // Назад: отсыпной от ранее сданного наряда накрывает день заступления.
    // Заодно выясняется, кто выходит в наряд в первый же день после отсыпного:
    // запрета нет — отдых выдержан, — но человека привлекают при первой
    // возможности, и это должно быть видно до нажатия «создать».
    const { resting, justRested, restingSource } = cal.restState(recentEnds, exceptions, onDate);

    // Вперед: отсыпной от создаваемого наряда накрывает наряд, в который
    // человек уже назначен. Без этой проверки наряд, вставленный в пропуск
    // задним числом, о завтрашнем назначении не узнает.
    const ownRest = cal.restDays(
      cal.dayKey(interval.endsAt), sleepDays, excludeWeekends, exceptions,
    );
    for (const id of await queries.findEmployeesStartingOn(ownRest, exceptIds)) {
      if (!resting.has(id)) resting.set(id, dutyType.code);
    }

    for (const [id, code] of justRested) justRestedAll.set(id, code);

    return subset.map((post) => {
      // Заступление подряд. Отсыпной человек ОТБЫВАЕТ — он спит положенные
      // часы и в строевой записке числится отдыхающим, — но на это место его
      // разрешено поставить снова. Отдых от ЧУЖОГО наряда по-прежнему не
      // отпускает: там человека ждут в другом месте.
      const repeat = post.allow_consecutive ?? dutyType.allow_consecutive;
      const ownRest = (id) => {
        const from = restingSource.get(id);
        if (!from) return false;
        // Разрешение на посту — только со своего поста; разрешение на виде
        // наряда — с любого поста этого же вида.
        return post.allow_consecutive === true
          ? from.postId === post.id
          : from.dutyTypeId === dutyType.id;
      };

      const bound = boundToPost.get(post.id);

      const available = filter.excludeBusy(byPost.get(post.id) || [], busyIds)
        // Закрепление СУЖАЕТ: допуск, отсутствие, отдых и оружие проверяются
        // по-прежнему, и закрепленный без допуска кандидатом не станет.
        .filter((c) => !bound || bound.has(c.id))
        .filter((c) => {
          if (!resting.has(c.id)) return true;
          if (repeat && ownRest(c.id)) return true;
          restingSeen.add(c.id);
          return false;
        })
        .map((c) => {
          const value = queue.queueValue(
            {
              lastDate: lastByEmployee.get(c.id) || null,
              workload: load.get(c.id) ? load.get(c.id).weight : 0,
            },
            {
              rank: rankWeight.get(`${post.id}|${c.rank_id}`) || 0,
              personal: personalWeight.get(`${post.id}|${c.id}`) || 0,
            },
            onDate, settings,
          );

          return {
            ...c,
            weight: load.get(c.id) ? load.get(c.id).weight : 0,
            dutyCount: load.get(c.id) ? load.get(c.id).duties : 0,
            justRested: justRested.get(c.id) || null,
            queue: value,
          };
        })
        // Порог предложения жесткий: сразу после смены человек ниже порога и
        // в списке не показывается вовсе — как и отсутствующий. Там, где
        // заступление подряд разрешено, порога нет: он выражает то же самое
        // правило, которое разрешением и снимается.
        .filter((c) => repeat || queue.passes(c.queue, settings));

      // Первым предлагается тот, чья очередь выше: это и подсказка при ручном
      // выборе, и порядок, по которому система подбирает состав сама.
      available.sort(queue.compare);

      if (available.length === 0) unfilled += 1;
      return { post, candidates: available };
    });
  }

  // Постоянный состав подбирается группами по норме отдыха: у ПУД она своя,
  // и отбор с чужой нормой отсеивал бы кандидатов сверх положенного.
  const byNorm = new Map();
  for (const post of permanentPosts) {
    const norm = post.recovery_sleep_days ?? dutyType.recovery_sleep_days;
    if (!byNorm.has(norm)) byNorm.set(norm, []);
    byNorm.get(norm).push(post);
  }

  const permanentRows = [];
  for (const [norm, subset] of byNorm) {
    permanentRows.push(...await select(
      subset, period, startDate, norm, dutyType.rest_excludes_weekends,
    ));
  }
  permanentRows.sort((a, b) => a.post.sort_order - b.post.sort_order);
  const postsWithCandidates = permanentRows;

  // Выходы посменных постов: по суткам, а внутри суток — группами с
  // одинаковыми часами, потому что интервал отбора у них общий.
  const shiftDays = [];
  for (const [date, items] of shifts) {
    const groups = new Map();
    for (const item of items) {
      const key = `${item.post.start_time}|${item.post.duration_hours}|${item.post.recovery_sleep_days ?? dutyType.recovery_sleep_days}`;
      if (!groups.has(key)) groups.set(key, { interval: item, posts: [] });
      groups.get(key).posts.push(item.post);
    }

    const rows = [];
    for (const group of groups.values()) {
      rows.push(...await select(
        group.posts, group.interval, date,
        // Отдых у посменного поста свой: после ночного ПТСО заняты сутки
        // сдачи, после вечернего и дневного — нет. Выходные его не
        // растягивают: это свойство многосуточной смены.
        group.posts[0].recovery_sleep_days ?? dutyType.recovery_sleep_days, false,
      ));
    }

    rows.sort((a, b) => a.post.sort_order - b.post.sort_order);
    shiftDays.push({
      date,
      posts: rows,
      nonWorking: cal.isNonWorking(date, exceptions),
    });
  }

  return {
    dutyType,
    period,
    generalPermits,
    posts: postsWithCandidates,
    shiftDays,
    unfilled,
    restingCount: restingSeen.size,
    justRestedCount: justRestedAll.size,
    workloadFrom,
    settings,
    nonWorking: cal.isNonWorking(startDate, exceptions),
  };
}

// ----------------------------------------------------------------------------
// График нарядов
// ----------------------------------------------------------------------------

/**
 * Назначения, переставшие быть действительными.
 *
 * Проверяются две группы причин:
 *   • отдых и занятость — данные нарядов. Отсыпной пересчитывается тем же
 *     calendar.restDays, что и при отборе кандидатов, поэтому второй
 *     реализации правила, способной разойтись с первой, не появляется;
 *   • отсутствие и допуски — данные личного состава, запрашиваются через
 *     personnel/service одним вызовом на весь период.
 *
 * @returns {Map<number, Array<{employeeId:number, postId:number, reason:string}>>}
 *   наряд → нарушения в его составе
 */
async function findBrokenAssignments(dutyTypeId, from, to, knownExceptions) {
  const exceptions = knownExceptions || new Map(
    (await queries.listCalendarDays(cal.addDays(from, -740), cal.addDays(to, 740)))
      .map((d) => [d.day, d.kind]),
  );

  const rows = await queries.listAssignmentsInRange(from, to);

  // Где разрешение заступать подряд задано на самом ПОСТУ, а где унаследовано
  // от вида наряда: от этого зависит, с какого места человека можно поставить
  // снова — только с того же поста или с любого поста этого вида.
  const postRule = new Map((await queries.listAllPosts())
    .map((p) => [p.id, p.allow_consecutive !== null && p.allow_consecutive !== undefined]));
  const broken = new Map();

  // Место в наряде — это пост И сутки выхода: посменный пост занимает
  // несколько мест внутри одной смены, и нарушение на одном из них не
  // относится к остальным.
  const add = (dutyId, item) => {
    if (!broken.has(dutyId)) broken.set(dutyId, []);
    const row = rows.find((r) => r.duty_id === dutyId && r.post_id === item.postId
      && (r.on_date || null) === (item.onDate || null));
    if(row && row.is_override && row.override_checks?.includes(item.reason) && OVERRIDABLE.has(item.reason)) return;
    const list = broken.get(dutyId);
    if (!list.some((x) => x.employeeId === item.employeeId && x.postId === item.postId
        && (x.onDate || null) === (item.onDate || null))) {
      list.push(item);
    }
  };

  // Отдых и занятость: назначения одного человека сравниваются попарно.
  const byEmployee = new Map();
  for (const row of rows) {
    if (!byEmployee.has(row.employee_id)) byEmployee.set(row.employee_id, []);
    byEmployee.get(row.employee_id).push(row);
  }

  for (const list of byEmployee.values()) {
    for (let i = 0; i < list.length; i += 1) {
      const rest = cal.restDays(
        cal.dayKey(list[i].ends_at),
        list[i].recovery_sleep_days,
        list[i].rest_excludes_weekends,
        exceptions,
      );

      for (let j = i + 1; j < list.length; j += 1) {
        const overlaps = list[j].starts_at < list[i].ends_at;
        const inRest = rest.includes(list[j].start_date);
        if (!overlaps && !inRest) continue;

        // Отдых не мешает там, где заступать подряд разрешено: человек его
        // отбывает, но на это место его можно поставить снова. Пересечение по
        // времени остается нарушением всегда.
        if (!overlaps && list[j].allow_consecutive) {
          const samePlace = postRule.get(list[j].post_id)
            ? list[j].post_id === list[i].post_id
            : list[j].duty_type_id === list[i].duty_type_id;
          if (samePlace) continue;
        }


        // Нарушение отмечается у ПОЗЖЕ заступающего наряда: именно он
        // назначен вопреки уже существующему.
        add(list[j].duty_id, {
          employeeId: list[j].employee_id,
          postId: list[j].post_id,
          onDate: list[j].on_date || null,
          reason: overlaps ? 'overlap' : 'rest',
          against: list[i].duty_code,
        });
      }
    }
  }

  // Отсутствия и допуски — только по нарядам нужного вида, чтобы не
  // запрашивать состав чужих нарядов.
  const own = rows.filter((r) => r.duty_type_id === dutyTypeId);

  if (own.length > 0) {
    const generalPermits = await queries.getGeneralPermits(dutyTypeId);
    const postMap = new Map((await queries.listPosts(dutyTypeId)).map(p=>[p.id,p]));

    const unfit = await personnel.findUnfitAssignments(
      own.filter(r=>postMap.has(r.post_id)).map((r) => ({ employeeId: r.employee_id, postId: r.post_id, onDate: r.start_date, startsAt:r.starts_at,endsAt:r.ends_at,requiredPermit:postMap.get(r.post_id).required_permit_type_id,weaponKind:postMap.get(r.post_id).required_weapon_kind })),
      generalPermits.map((p) => p.permit_type_id),
    );

    const dutyByKey = new Map(own.map((r) => [`${r.employee_id}:${r.post_id}:${r.start_date}`, r]));

    for (const u of unfit) {
      const row = dutyByKey.get(`${u.employee_id}:${u.post_id}:${u.on_date}`);
      if (!row) continue;
      add(row.duty_id, {
        employeeId: u.employee_id, postId: u.post_id,
        onDate: row.on_date || null, reason: u.reason,
      });
    }
  }

  const activePosts=new Set((await queries.listPosts(dutyTypeId)).map(p=>p.id));
  for(const [id,items] of broken) broken.set(id,items.filter(b=>activePosts.has(b.postId)));
  return broken;
}

// ----------------------------------------------------------------------------
// Оружие на наряд
//
// Своего оружия у человека может не быть — назначению это не мешает. Такому
// человеку выбирают оружие другого, свободного в эти и следующие сутки;
// выбор хранится в назначении, а в приказе после состава идут строки
// «получить личное оружие» и пофамильное временное закрепление.
// ----------------------------------------------------------------------------

const WEAPON_KIND = { rifle: 'автомат', pistol: 'пистолет' };

function weaponLabel(w) {
  return `${WEAPON_KIND[w.kind] || ''} ${w.name} № ${w.serial} (${w.year} г.)`.trim();
}

/**
 * Оружие места по строке weaponStatus. null — пост оружия не требует.
 * state: own — свое годное; loan — выбрано чужое; missing — не выбрано.
 */
function weaponOf(st) {
  if (!st || !st.kind) return null;
  if (st.own_id) {
    const weapon = { kind: st.kind, name: st.own_name, serial: st.own_serial, year: st.own_year };
    return { kind: st.kind, state: 'own', weapon, label: weaponLabel(weapon), problem: null };
  }
  if (st.loan_id) {
    const weapon = { id: st.loan_id, kind: st.loan_kind, name: st.loan_name, serial: st.loan_serial,
      year: st.loan_year, owner: st.loan_owner };
    let problem = null;
    if (!st.loan_active) problem = 'оружие выведено из применения';
    else if (st.loan_kind !== st.kind) problem = `посту нужен ${WEAPON_KIND[st.kind]}`;
    else if (st.owner_busy) problem = `владелец (${st.owner_busy}) сам несет его в наряде в эти или следующие сутки`;
    else if (st.given_to) problem = `это оружие уже выдано: ${st.given_to}`;
    return { kind: st.kind, state: 'loan', weapon, label: weaponLabel(weapon), problem };
  }
  return { kind: st.kind, state: 'missing', weapon: null, label: null, problem: null };
}

/** Оружие по назначениям: id назначения → weaponOf. */
async function weaponsByAssignment(assignmentIds) {
  const rows = await queries.weaponStatus(assignmentIds);
  return new Map(rows.map((r) => [r.assignment_id, weaponOf(r)]));
}

/**
 * Строка приказа о временном закреплении: «За лейтенантом Ивановым И.И. на
 * время несения дежурства закрепить пистолет № АА000000 1999 г.»
 */
function weaponOrderLine(employee, weapon) {
  const person = declension.instrumental({
    rankName: employee.rank_name, lastName: employee.last_name,
    firstName: employee.first_name, middleName: employee.middle_name,
  });
  return `За ${person} на время несения дежурства закрепить `
    + `${WEAPON_KIND[weapon.kind]} № ${weapon.serial} ${weapon.year} г.`;
}

/** Группа выбора оружия: вид и окно «сутки заступления — сутки после сдачи». */
function weaponGroup(kind, interval) {
  const from = cal.dayKey(interval.startsAt);
  const to = cal.dayKey(interval.endsAt);
  return { key: `${kind}|${from}|${to}`, kind, from, to };
}

const BROKEN_REASON = {
  inactive: 'сотрудник не состоит в действующем списке',
  rest: 'не выдержан отсыпной',
  overlap: 'занят в пересекающемся наряде',
  absent: 'отсутствует',
  post_permit: 'нет действующего допуска к посту',
  general_permit: 'нет действующего общего допуска',
};

// ----------------------------------------------------------------------------
// Автоматический подбор
// ----------------------------------------------------------------------------

/**
 * Заполнение незамещенных мест месяца по очереди заступления.
 *
 * Запускается при открытии месяца и добирает ВСЕ пустые места впереди —
 * сколько бы раз график ни открывали. Уже назначенных и утвержденные приказы
 * не трогает: подбор дополняет работу человека, а не переделывает ее.
 *
 * Люди берутся ИЗ ОТВЕТСТВЕННОГО подразделения поста, если оно закреплено:
 * иначе закрепления не имели бы смысла. Если ответственного нет, кандидаты
 * берутся из всей части.
 *
 * Работа ограничена по числу блоков за один заход: открытие графика не должно
 * превращаться в минутное ожидание. Недобранное достанется следующему
 * открытию — порядок от этого не страдает, очередь считается заново.
 *
 * @returns {{filled:number, blocks:number, left:number}}
 */
const AUTOFILL_BLOCK_LIMIT = 40;

async function autoFill(dutyTypeId, year, month, userId, known) {
  const schedule = known || await getMonthSchedule(dutyTypeId, year, month, null, null);
  const today = cal.dayKey(new Date());

  // Блоки, в которых есть что замещать: только впереди и только те, где
  // приказ еще не подписан.
  const pending = [...new Map(schedule.grid.flat()
    .filter((d) => d.cell && !d.outside && !d.cell.continuation
      && d.cell.startDate > today
      && d.cell.assigned < d.cell.postCount
      && (!d.cell.duty || d.cell.duty.status !== 'approved'))
    .map((d) => [d.cell.deadline || d.cell.startDate, d.cell.startDate])).values()].sort();

  let filled = 0;
  let blocks = 0;
  let processed = 0;

  for (const date of pending) {
    if (processed >= AUTOFILL_BLOCK_LIMIT) break;
    processed += 1;
    // Подбор и сохранение сериализованы с ручной правкой и утверждением.
    const added = await db.transaction(() => autoFillBlock(dutyTypeId, date, userId));
    if (added > 0) { filled += added; blocks += 1; }
  }

  return { filled, blocks, left: Math.max(0, pending.length - processed) };
}

/**
 * Автоподбор со страницы назначения: только этот приказной блок (сутки
 * страницы). Уже назначенных не трогает, утвержденный и прошедшее не меняет.
 */
async function autoFillPlan(dutyTypeId, date, userId) {
  v.id(dutyTypeId);
  v.date(date);
  return db.transaction(() => autoFillBlock(Number(dutyTypeId), date, userId));
}

/** Подбор состава одного приказного блока. Возвращает число занятых мест. */
async function autoFillBlock(dutyTypeId, date, userId) {
  const plan = await getBlockPlan(dutyTypeId, date, null);
  if (!plan) return 0;
  if (plan.days.some(day => day.duty?.status === 'approved')) return 0;

  // Область видимости ответственного подразделения разворачивается один раз
  // на блок: поддерево у роты одно и то же для всех ее постов.
  const subtrees = new Map();
  const subtreeOf = async (unitId) => {
    if (!subtrees.has(unitId)) subtrees.set(unitId, new Set(await org.subtreeIds(unitId)));
    return subtrees.get(unitId);
  };

  // Один человек — одно место в блоке: сутки блока идут подряд, и отдых от
  // первых накрывает вторые. Занятые в этом же блоке исключаются сразу, а не
  // отказом при сохранении.
  const taken = new Set();
  for (const day of plan.days) {
    for (const row of [...day.rows, ...(day.shiftDays || []).flatMap((sd) => sd.rows)]) {
      if (row.current) taken.add(row.current.id);
    }
  }

  const byDate = new Map();
  let filled = 0;

  const fill = async (row, formDate) => {
    if (row.current) return;

    let candidates = row.candidates.filter((c) => !taken.has(c.id));

    if (row.responsible) {
      const own = await subtreeOf(row.responsible.unitId);
      candidates = candidates.filter((c) => own.has(c.unit_id));
    }

    const pick = candidates[0];
    if (!pick) return;

    taken.add(pick.id);
    if (!byDate.has(formDate)) byDate.set(formDate, new Map());
    byDate.get(formDate).set(row.post.id, pick.id);
    filled += 1;
  };

  for (const day of plan.days) {
    if (day.startDate <= cal.dayKey(new Date())) continue;
    for (const row of day.rows) await fill(row, day.startDate);
    for (const sd of day.shiftDays || []) {
      for (const row of sd.rows) await fill(row, sd.date);
    }
  }

  if (filled === 0) return 0;

  await saveBlock({ dutyTypeId, date, byDate, userId, source: 'auto' });
  return filled;
}

// ----------------------------------------------------------------------------
// Ответственное подразделение поста
// ----------------------------------------------------------------------------

/**
 * Кто отвечает за пост в конкретные сутки.
 *
 * Три уровня, от сильного к слабому:
 *   1. точечное закрепление поста на эти сутки — ручное решение начальника
 *      службы, оно сильнее любого порядка;
 *   2. очередь поста: одно подразделение — постоянное закрепление, несколько —
 *      цикл. Чья очередь, считается по НОМЕРУ ЗАСТУПЛЕНИЯ поста от опорных
 *      суток: пропущенные дни, когда наряд не положен, очередь не сдвигают;
 *
 * Закрепления ВСЕГО наряда за подразделением нет (решение 121): ответственный
 * определяется только по постам, и пост без своей очереди — общий.
 *
 * @returns {{at: function(number, string, string): ?object}}
 */
async function postResponsibility(dutyType, schedules, posts, from, to, exceptions) {
  const [queue, pointwise] = await Promise.all([
    queries.listPostUnits(dutyType.id),
    queries.listPostResponsibilities(dutyType.id, from, to),
  ]);

  const queueByPost = new Map();
  for (const row of queue) {
    if (!queueByPost.has(row.post_id)) queueByPost.set(row.post_id, []);
    queueByPost.get(row.post_id).push(row);
  }

  const pointByKey = new Map(pointwise.map((r) => [`${r.post_id}|${r.on_date}`, r]));

  const postById = new Map(posts.map(post => [post.id, post]));

  const at = (postId, date, periodStart) => {
    const point = pointByKey.get(`${postId}|${date}`);
    if (point) {
      return { unitId: point.unit_id, short: point.unit_short, source: 'точечно', note: point.note };
    }

    const list = queueByPost.get(postId);
    if (list && list.length === 1) {
      return { unitId: list[0].unit_id, short: list[0].unit_short, source: 'постоянно' };
    }

    if (list && list.length > 1) {
      const post = postById.get(postId);
      const turn = post
        ? cal.rotationTurn(dutyType, schedules, post, post.rotation_since, date, exceptions)
        : null;
      if (turn !== null) {
        const item = list[(turn - 1) % list.length];
        return { unitId: item.unit_id, short: item.unit_short, source: 'по очереди' };
      }
    }

    return null;
  };

  return { at, queueByPost, pointByKey };
}

/**
 * График нарядов одного вида на месяц.
 *
 * Возвращается сетка недель, где у каждого дня — состояние положенного на
 * этот день наряда. Положенные наряды вычисляются из расписания вида наряда,
 * а не берутся из БД: непоставленный наряд записи не оставляет, и показать
 * его можно только расчетом.
 *
 * @param {number} dutyTypeId
 * @param {number} year
 * @param {number} month   1..12
 * @param {?number} unitId фильтр по подразделению; null — все
 */
async function getMonthSchedule(dutyTypeId, year, month, unitId, scopeIds) {
  const dutyType = await queries.getDutyType(dutyTypeId);
  if (!dutyType) throw new Error(`Вид наряда не найден: ${dutyTypeId}`);

  const { weeks, gridStart, gridEnd } = cal.monthGrid(year, month);

  // Справочник запрашивается с запасом назад: срок выпуска приказа на первый
  // день сетки может приходиться на предыдущий месяц.
  const [schedules, posts, calendarDays, duties] = await Promise.all([
    queries.getSchedules(dutyTypeId),
    queries.listPosts(dutyTypeId),
    queries.listCalendarDays(cal.addDays(gridStart, -740), cal.addDays(gridEnd,740)),
    queries.listDutiesInRange(dutyTypeId, cal.addDays(gridStart, -7), gridEnd, unitId),
  ]);

  // Ответственный считается ПО ПОСТАМ: по КПП ходит одна рота, на остальные
  // посты подразделения заступают по очереди, а отдельные сутки начальник
  // службы правит точечно.
  const assignedSlots = await queries.listAssignedSlots(
    dutyTypeId, cal.addDays(gridStart, -7), gridEnd,
  );
  const assignedSet = new Set(
    assignedSlots.map((r) => `${r.start_date}|${r.post_id}|${r.on_date || ''}`),
  );

  // Командир видит красным только СВОИ сутки — те, где есть места, закрепленные
  // за его подразделением (очередь поста или точечное закрепление). Чужой
  // незакрытый наряд — не его забота, и окрашивать его тревожно значит
  // приучать не смотреть на красное.

  const exceptions = new Map(calendarDays.map((d) => [d.day, d.kind]));
  const holidayNames = new Map(
    calendarDays.filter((d) => d.kind === 'holiday').map((d) => [d.day, d.name]),
  );
  const dutyByStart = new Map(duties.map((d) => [d.start_date, d]));

  // Назначенный состав проверяется заново. Отбор кандидатов проверяет
  // человека в момент назначения, но условия меняются позже: объявляется
  // нерабочий день и отсыпной, считаемый без учета выходных, удлиняется;
  // истекает допуск; человек уходит в отпуск. Назначение при этом остается,
  // и без повторной проверки наряд выглядит укомплектованным.
  const brokenByDuty = await findBrokenAssignments(
    dutyTypeId, cal.addDays(gridStart, -7), gridEnd, exceptions,
  );

  const today = cal.dayKey(new Date());
  const expected = cal.expectedDuties(dutyType, schedules, gridStart, gridEnd, exceptions);

  // День → сведения о занимающем его наряде. Многодневная смена занимает
  // несколько дней, и все они ссылаются на одну и ту же запись.
  const byDay = new Map();

  const permanentPosts = posts.filter((p) => !cal.isShiftPost(p));
  const permanentCount = permanentPosts.length;
  const shiftPosts = posts.filter(cal.isShiftPost);
  const postCount = posts.length;

  const responsibility = await postResponsibility(
    dutyType, schedules, posts, cal.addDays(gridStart, -7), gridEnd, exceptions,
  );

  // В одни сутки могут сходиться места ДВУХ приказов: смена, сдающая в
  // пятницу в 17:30, держит дневные ПТСО и ПУД, заступающие в пятницу в
  // 08:00, а вечером того же дня заступает следующая смена. Поэтому день
  // собирается из вкладов всех периодов, а не принадлежит одному.
  const parts = new Map();
  const contribute = (day, item) => {
    if (!parts.has(day)) parts.set(day, []);
    parts.get(day).push(item);
  };

  for (const period of expected) {
    const duty = dutyByStart.get(period.startDate) || null;
    const past = cal.isPast(period, today);
    const brokenAll = duty && !past ? brokenByDuty.get(duty.id) || [] : [];
    const historical=duty?.approved_snapshot;
    const deadline = cal.orderDeadline(period.startDate, exceptions);

    // Выходы посменных постов внутри смены: каждые сутки замещаются
    // отдельно, и в графике у каждых суток свое заполнение.
    const shifts = cal.shiftsByDate(period, shiftPosts);
    const shiftCounts = (duty && duty.shift_counts) || {};
    const days = [...new Set([...period.covers, ...shifts.keys()])].sort();

    for (const day of days) {
      const isStart = day === period.startDate;
      const dayShifts = shifts.get(day) || [];

      // Постоянный состав относится к суткам заступления; выход посменного
      // поста — к своим суткам.
      const broken = brokenAll.filter((b) => (b.onDate || period.startDate) === day);

      // Места этих суток: постоянный состав относится к суткам заступления,
      // выход посменного поста — к своим.
      const places = [
        ...(isStart ? permanentPosts.map((p) => ({ post: p, date: period.startDate })) : []),
        ...dayShifts.map((s) => ({ post: s.post, date: day })),
      ].map((place) => ({
        ...place,
        responsible: responsibility.at(place.post.id, place.date, period.startDate),
        assigned: Boolean(duty)
          && assignedSet.has(`${period.startDate}|${place.post.id}|${place.date === period.startDate && !cal.isShiftPost(place.post) ? '' : place.date}`),
      }));

      const ours = scopeIds
        ? places.filter((pl) => pl.responsible && scopeIds.includes(pl.responsible.unitId))
        : places;

      const visibleBroken = scopeIds ? broken.filter(b => ours.some(pl => pl.post.id === b.postId)) : broken;
      const historicalAssigned = historical
        ? historical.roster.filter(r => (r.onDate || period.startDate) === day).length : 0;
      contribute(day, {
        duty, past, deadline, isStart, broken: visibleBroken,
        units: [...new Set(places.map((pl) => pl.responsible && pl.responsible.short).filter(Boolean))],
        mineRequired: ours.length,
        mineAssigned: ours.filter((pl) => pl.assigned).length,
        startDate: period.startDate,
        days: period.days,
        required: past && historical
          ? historicalAssigned + (isStart ? Math.max(0, historical.postCount - historical.roster.length) : 0)
          : (isStart ? permanentCount : 0) + dayShifts.length,
        assignedRaw: past && historical
          ? historicalAssigned
          : (isStart && duty ? duty.permanent_assigned : 0) + (shiftCounts[day] || 0),
        shiftCount: dayShifts.length,
      });
    }
  }

  for (const [day, items] of parts) {
    // Главный вклад — тот, чья смена в эти сутки заступает: на его приказ
    // ведет ячейка. Остальные показываются дополнительной ссылкой.
    const main = items.find((i) => i.isStart) || items[0];
    const broken = items.flatMap((i) => i.broken);

    // У пользователя с закрепленным подразделением счет идет ПО ЕГО постам:
    // чужие места он видит, но отвечает не за них.
    const ownScope = Boolean(scopeIds);
    const required = ownScope
      ? items.reduce((sum, i) => sum + i.mineRequired, 0)
      : items.reduce((sum, i) => sum + i.required, 0);
    const assigned = (ownScope
      ? items.reduce((sum, i) => sum + i.mineAssigned, 0)
      : items.reduce((sum, i) => sum + i.assignedRaw, 0)) - broken.length;

    // Пост, занятый человеком, который больше не пригоден, считается
    // незамещенным: иначе наряд с назначенным, но отсутствующим человеком
    // показывался бы готовым, а обнаружилось бы это в день заступления.
    const effective = items.every((i) => i.duty)
      ? {
        status: items.every((i) => i.duty.status === 'approved') ? 'approved' : 'draft',
        auto_count: items.reduce((sum, i) => sum + (i.duty.auto_count || 0), 0),
        assigned_count: assigned,
      }
      : null;

    const status = cal.dutyStatus(effective, required, main.past);

    // Сутки, в которых у пользователя нет ни одного своего поста, показываются
    // спокойно: они требуют действия не от него.
    const foreign = ownScope && required === 0;

    byDay.set(day, {
      duty: main.duty,
      status,
      past: main.past,
      deadline: main.deadline,
      postCount: required,
      broken: broken.length,
      brokenReasons: [...new Set(broken.map((b) => BROKEN_REASON[b.reason] || b.reason))],
      // Показывается ДЕЙСТВИТЕЛЬНОЕ число замещенных мест.
      assigned,
      // Замены, внесенные при утверждении, отмечаются в графике: отступление
      // от подбора должно быть видно там же, где смотрят на месяц целиком.
      notes: main.duty && main.duty.notes ? main.duty.notes : [],
      urgent: !foreign && cal.isUrgent(status, { startDate: day }, main.deadline, today),
      foreign,
      units: [...new Set(items.flatMap((i) => i.units))],
      totalRequired: items.reduce((sum, i) => sum + i.required, 0),
      // Назначение открывается страницей всего приказа, поэтому ссылка
      // ведет на сутки ЗАСТУПЛЕНИЯ смены, а якорь — на выбранный день.
      startDate: main.startDate,
      anchorDate: day,
      days: main.days,
      isStart: main.isStart,
      // Сутки продолжающейся смены, в которые никто не сменяется:
      // замещать в них нечего, показывать заполнение не нужно.
      continuation: !main.isStart && required === 0,
      // Места этих суток, входящие в ДРУГОЙ приказ.
      others: items.filter((i) => i !== main).map((i) => ({
        startDate: i.startDate, required: i.required,
      })),
      title: cal.STATUS_TITLE[status],
    });
  }

  const grid = weeks.map((week) => week.map((day) => {
    const cell = byDay.get(day.key) || null;
    return {
      ...day,
      dayNumber: cal.dayDate(day.key).getDate(),
      isToday: day.key === today,
      nonWorking: cal.isNonWorking(day.key, exceptions),
      holidayName: holidayNames.get(day.key) || null,
      cell,
      // Приказ на этот наряд положено выпустить сегодня.
      orderToday: Boolean(cell) && cell.deadline === today,
    };
  }));

  // Сетка захватывает края соседних месяцев, чтобы оставаться прямоугольной,
  // но в сводку они не входят: иначе в тридцатидневном месяце насчитывается
  // тридцать пять нарядов.
  const monthPrefix = `${year}-${String(month).padStart(2, '0')}`;
  const summary = {
    missing: 0, incomplete: 0, overdue: 0,
    auto: 0, pending: 0, approved: 0, urgent: 0,
  };

  // Считаются сутки, в которые есть что замещать: у многосуточной смены
  // это день заступления и каждый день смены посменных постов.
  for (const [day, cell] of byDay) {
    if (!day.startsWith(monthPrefix) || cell.continuation || cell.foreign) continue;
    if (cell.status in summary) summary[cell.status] += 1;
    if (cell.urgent) summary.urgent += 1;
  }

  return { dutyType, year, month, grid, postCount, summary, today };
}

/**
 * Кто на указанный день занят нарядом: несет службу, отдыхает после нее либо
 * вышел из отсыпного накануне.
 *
 * Публичный интерфейс для модуля «Личный состав»: сведения о нарядах живут
 * здесь, и обращаться к таблицам нарядов напрямую тому модулю нельзя. В
 * строевой записке наряд и отсыпной — причины ОТСУТСТВИЯ (раздел 9.2), и
 * состояние личного состава без этих сведений не посчитать.
 *
 * @returns {{onDuty: Map<number,string>, resting: Map<number,string>,
 *            justRested: Map<number,string>}}
 *   значение — код вида наряда, которым человек занят либо после которого
 *   отдыхает.
 */
async function getDutyState(onDate) {
  const [onDuty, recentEnds, calendarDays] = await Promise.all([
    queries.findEmployeesOnDuty(onDate),
    queries.findRecentDutyEnds(`${onDate} 23:59:59`),
    queries.listCalendarDays(cal.addDays(onDate, -740), cal.addDays(onDate, 740)),
  ]);

  const exceptions = new Map(calendarDays.map((d) => [d.day, d.kind]));
  const rest = cal.restState(recentEnds, exceptions, onDate);

  return {
    // В значении — ПОСТ, а не код вида наряда: строевая записка и списки
    // называют человека по тому, что он несет, а не по номеру приказа.
    onDuty: new Map(onDuty.map((r) => [r.employee_id, r.post_name || r.duty_code])),
    ...rest,
  };
}

/**
 * Снятие человека с наряда как привлеченного к работам, которых в системе нет.
 *
 * Начальник службы знает о привлечении из приказа, до системы не дошедшего:
 * временный караул, работы, командирование внутри части. Одного удаления из
 * состава мало — на следующий день человек снова окажется первым в списке
 * кандидатов. Поэтому снятие оформляется отсутствием категории «прочее» на
 * указанные даты: оно и убирает человека из состава, и исключает его из
 * подбора на весь период, и попадает в строевую записку отдельной строкой.
 *
 * Порядок действий важен. Сначала записывается отсутствие: оно и есть факт
 * о человеке. Снятие с нарядов — следствие, и если оно не выполнится, повтор
 * операции его завершит. Обратный порядок оставил бы человека снятым с
 * наряда без указания причины.
 *
 * @returns {{absenceId:number, dutyIds:number[]}} затронутые наряды
 */
/**
 * Исключенный из списков снимается со всех будущих нарядов; их приказы
 * возвращаются в проект — состав изменился. Прошлые наряды не трогаются.
 */
async function dropFromFutureDuties(employeeId, userId) {
  const rows = await queries.dropFutureAssignments(v.id(employeeId));
  const blocks = new Set();
  for (const row of rows) {
    const key = `${row.duty_type_id}|${row.start_date}`;
    if (blocks.has(key)) continue;
    blocks.add(key);
    await unapproveBlock(row.duty_type_id, row.start_date, null, userId);
  }
  return rows.length;
}

async function withdrawEmployee({employeeId,dateFrom,dateTo,documentRef,note,userId}) {
 v.id(employeeId);v.future(dateFrom);v.date(dateTo);
 if(dateTo<dateFrom) v.fail('Окончание периода раньше начала.');
 if(!String(documentRef||'').trim()) v.fail('Укажите приказ-основание.');
 const rows=await queries.listAssignmentsInRange(cal.addDays(dateFrom,-7),dateTo);
 const affected=rows.filter(r=>r.employee_id===employeeId && r.starts_at<new Date(cal.addDays(dateTo,1)+'T00:00:00')&&r.ends_at>new Date(dateFrom+'T00:00:00'));
 for(const r of affected) v.future(r.duty_start_date);
 const absenceId=await personnel.addAbsence({employeeId,typeCode:'OTHER',dateFrom,dateTo,documentRef,note,createdBy:userId});
 const dutyIds=await queries.withdrawEmployee(employeeId,dateFrom,dateTo,userId);
 for(const row of affected) await unapproveBlock(row.duty_type_id,row.duty_start_date,null,userId);
 return {absenceId,dutyIds};
}

// ----------------------------------------------------------------------------
// Справочник празднично-выходных дней
// ----------------------------------------------------------------------------

async function listCalendarDays(from, to) {
  return queries.listCalendarDays(from, to);
}

/**
 * Перечень, свернутый в периоды.
 *
 * Хранение посуточное — перенос отдельного дня внутри периода обычное дело,
 * — но читать перечень посуточно нельзя: одни новогодние каникулы дают
 * восемь строк. Подряд идущие сутки одного вида и с одним наименованием
 * показываются одной строкой.
 */
async function listCalendarRanges(from, to) {
  const days = await queries.listCalendarDays(from, to);
  const ranges = [];

  for (const day of days) {
    const last = ranges[ranges.length - 1];

    const continues = last
      && last.kind === day.kind
      && (last.name || '') === (day.name || '')
      && cal.addDays(last.dateTo, 1) === day.day;

    if (continues) {
      last.dateTo = day.day;
      last.days += 1;
    } else {
      ranges.push({ dateFrom: day.day, dateTo: day.day, kind: day.kind, name: day.name, days: 1 });
    }
  }

  return ranges;
}

// Ограничение отсекает опечатку в годе: без него «с 2026-01-01 по 2036-01-08»
// объявит нерабочими десять лет, и обнаружится это далеко не сразу.
const MAX_RANGE_DAYS = 366;

async function setCalendarRange(dateFrom,dateTo,kind,name,userId) {
 v.future(dateFrom);v.date(dateTo);
 if(dateTo<dateFrom || cal.daysBetween(dateFrom,dateTo).length>366) v.fail('Период должен содержать от 1 до 366 суток.');
 if(!['holiday','workday'].includes(kind)) v.fail('Некорректный вид дня.');
 const before=await calendarSignatures();
 const result=await queries.setCalendarRange(dateFrom,dateTo,kind,name);
 await invalidateCalendarChanges(before,userId);
 return result;
}

async function deleteCalendarRange(dateFrom,dateTo,userId) {
 v.future(dateFrom);v.date(dateTo);if(dateTo<dateFrom) v.fail('Некорректный период.');
 const before=await calendarSignatures();
 const result=await queries.deleteCalendarRange(dateFrom,dateTo);
 await invalidateCalendarChanges(before,userId);return result;
}

// ----------------------------------------------------------------------------
// Наряды
// ----------------------------------------------------------------------------

/**
 * @param {Array<{postId:number, employeeId:number}>} assignments
 * @returns {{dutyId:?number, problems:string[]}}
 */
async function createDuty({ dutyTypeId, startDate, assignments, note, userId }) {
 v.id(dutyTypeId); v.future(startDate);
 const dutyType=await queries.getDutyType(dutyTypeId);
 if(!dutyType) v.fail('Вид наряда не найден.',404);
 const schedules=await queries.getSchedules(dutyTypeId);
 const period=filter.computePeriod(dutyType,schedules,startDate);
 if(period.noSchedule) v.fail('На эту дату смена не предусмотрена расписанием.');
 if((await queries.findDutiesOnDates(dutyTypeId,[startDate])).length) v.fail('На эти сутки наряд уже существует. Откройте его состав.',409);
 const posts=await queries.listPosts(dutyTypeId);
 assignments=assignments.map(a=>({...a,...slotInterval(dutyType,
   {starts_at:period.startsAt,ends_at:period.endsAt},posts.find(p=>p.id===a.postId),a.onDate)}));
 await validateRoster(dutyType,startDate,period,assignments,posts,[]);
 const dutyId=await queries.createDuty({dutyTypeId,unitId:await queries.rootUnit(),startsAt:period.startsAt,endsAt:period.endsAt,assignments,note,userId});
 await unapproveBlock(dutyTypeId,startDate,null,userId);
 return {dutyId,problems:[]};
}

// ----------------------------------------------------------------------------
// Приказной блок
//
// Приказ выпускается на весь блок нерабочих дней вместе с первым рабочим днем
// после него. Поэтому назначение, утверждение и печать работают не над одними
// сутками, а над блоком целиком: назначать по одному дню, а подписывать одним
// документом — значит держать в голове, какие сутки уже вошли в приказ.
// ----------------------------------------------------------------------------

/** Даты заступления и срок выпуска приказа для блока, содержащего дату. */
async function getBlockDates(dutyTypeId, date) {
  const dutyType = await queries.getDutyType(dutyTypeId);
  if (!dutyType) throw new Error(`Вид наряда не найден: ${dutyTypeId}`);

  const [schedules, calendarDays] = await Promise.all([
    queries.getSchedules(dutyTypeId),
    queries.listCalendarDays(cal.addDays(date, -740), cal.addDays(date, 740)),
  ]);

  const exceptions = new Map(calendarDays.map((d) => [d.day, d.kind]));

  return {
    dutyType,
    schedules,
    exceptions,
    deadline: cal.orderDeadline(date, exceptions),
    periods: cal.orderBlock(dutyType, schedules, date, exceptions),
  };
}

/**
 * Блок, подготовленный к назначению.
 *
 * По каждым суткам блока — все действующие посты с кандидатами и уже
 * назначенными. Существующие наряды показываются вместе с новыми: приказ
 * может дополняться, а не только создаваться с нуля.
 */
async function getBlockPlan(dutyTypeId, date, unitId) {
  const { dutyType, periods, deadline, exceptions } = await getBlockDates(dutyTypeId, date);
  if (periods.length === 0) return null;

  const dates = periods.map((p) => p.startDate);
  const existing = await queries.findDutiesOnDates(dutyTypeId, dates, unitId);
  const dutyByDate = new Map(existing.map((d) => [d.start_date, d]));

  const assignments = await queries.getAssignmentsForDuties(existing.map((d) => d.id));
  const byDuty = new Map();
  for (const a of assignments) {
    if (!byDuty.has(a.duty_id)) byDuty.set(a.duty_id, []);
    byDuty.get(a.duty_id).push(a);
  }

  // Назначенный человек называется по имени даже тогда, когда выпал из
  // кандидатов: «назначен ранее» без фамилии не позволяет ни проверить
  // состав, ни осознанно его менять.
  const people = await personnel.getByIds([...new Set(assignments.map((a) => a.employee_id))]);
  const personById = new Map(people.map((p) => [p.id, p]));

  // Места блока, несовместимые между собой, определяются ДО показа формы и
  // отдаются ей: выбранный человек должен исчезать из остальных списков
  // сразу, а не после отказа при сохранении.
  //
  // Сравниваются не сутки, а ИНТЕРВАЛЫ: у ПТСО 1 (08:00–20:00) и ПТСО 2
  // (20:00–08:00) одни сутки, но разные интервалы, и запрет нужен именно на
  // их пару, а не на сутки целиком — иначе ПТСО 1 два дня подряд, который
  // правилами разрешен, тоже пропал бы из списка.
  //
  // Места с одинаковым интервалом и одинаковой нормой отдыха неразличимы,
  // поэтому в таблицу попадают не места, а их РАЗРЯДЫ: для суточного наряда
  // разряд один на сутки, и таблица остается такой же короткой, как прежде.
  const slotClasses = new Map();
  const classOf = (interval) => {
    const key = `${interval.startsAt.valueOf()}:${interval.endsAt.valueOf()}`
      + `:${interval.sleepDays}:${interval.excludeWeekends}`;
    if (!slotClasses.has(key)) slotClasses.set(key, { key, ...interval, employeeId: 1 });
    return key;
  };

  // Нарушения в уже назначенном составе берутся тем же расчетом, что и в
  // календаре. Иначе страница и график расходились бы в том, какой наряд
  // считать испорченным: нарушение принадлежит ПОЗЖЕ заступающему наряду —
  // именно он назначен вопреки уже существующему.
  const broken = await findBrokenAssignments(
    dutyTypeId, cal.addDays(dates[0], -7), cal.addDays(dates[dates.length - 1], 7),
  );

  // Ответственное подразделение показывается у каждого поста: командир должен
  // видеть, какие места его, а начальник службы — править их точечно.
  const allPosts = await queries.listPosts(dutyTypeId);
  const { schedules } = await getBlockDates(dutyTypeId, date);
  const responsibility = await postResponsibility(
    dutyType, schedules, allPosts, dates[0], cal.addDays(dates[dates.length - 1], 7), exceptions,
  );

  // Места с оружием: у каждого своя группа выбора (вид оружия и окно
  // «сутки заступления — сутки после сдачи»); состояние оружия назначенных
  // заполняется одним запросом после обхода всех суток.
  const armedRows = [];
  const weaponGroups = new Map();

  // Подбор ведется по каждым суткам отдельно: состав в каждый день свой,
  // и отдых, отсутствия и занятость на эти сутки тоже свои.
  const days = [];
  for (const period of periods) {
    const duty = dutyByDate.get(period.startDate) || null;
    if(duty && period.startDate<=cal.dayKey(new Date())) {
      const historical=await getDutyWithMembers(duty.id);
      if(historical) {
        const rows=historical.roster.map(r=>({post:r.post,candidates:[],current:{id:r.employee?.id,name:r.employee?.full_name,fullName:r.employee?.full_name,rank:r.employee?.rank_name,unit:r.employee?.unit_short,note:r.note,broken:null,inCandidates:true}}));
        days.push({startDate:period.startDate,period,duty,nonWorking:cal.isNonWorking(period.startDate,exceptions),conflictsWith:[],rows,
          assignedCount:rows.length,brokenCount:0,postCount:historical.postCount,workloadFrom:cal.addDays(period.startDate,-30)});
        continue;
      }
    }
    const selection = await findCandidatesByPost(
      dutyTypeId, period.startDate, duty ? duty.id : null,
    );

    // Место в наряде — пост И сутки выхода: у постоянного состава сутки
    // пустые, у посменного поста своя запись на каждый день смены.
    const slotKey = (postId, onDate) => `${postId}|${onDate || ''}`;

    const assigned = new Map(
      (duty ? byDuty.get(duty.id) || [] : []).map((a) => [slotKey(a.post_id, a.on_date), a]),
    );

    const brokenBySlot = new Map(
      (duty ? broken.get(duty.id) || [] : []).map((b) => [slotKey(b.postId, b.onDate), b.reason]),
    );

    const rowOf = (post, candidates, onDate) => {
      const a = assigned.get(slotKey(post.id, onDate)) || null;
      const reason = a ? brokenBySlot.get(slotKey(post.id, onDate)) : null;
      const person = a ? personById.get(a.employee_id) : null;
      const interval = slotInterval(dutyType, {
        starts_at: period.startsAt, ends_at: period.endsAt,
      }, post, onDate);

      let weapon = null;
      if (post.required_weapon_kind) {
        const group = weaponGroup(post.required_weapon_kind, interval);
        weaponGroups.set(group.key, group);
        weapon = { kind: post.required_weapon_kind, group: group.key, current: null };
      }

      const row = {
        post,
        weapon,
        candidates,
        onDate: onDate || null,
        responsible: responsibility.at(post.id, onDate || period.startDate, period.startDate),
        // Разряд места: по нему форма понимает, какие списки очищать после
        // выбора человека.
        slotClass: classOf(interval),
        current: a === null ? null : {
          id: a.employee_id,
          name: person ? person.short_name : `№ ${a.employee_id}`,
          fullName: person ? person.full_name : null,
          rank: person ? person.rank_name : null,
          unit: person ? person.unit_short : null,
          note: a.note || null,
          inCandidates: candidates.some((c) => c.id === a.employee_id),
          broken: reason ? BROKEN_REASON[reason] || reason : null,
        },
      };
      if (weapon && a) armedRows.push({ row, assignmentId: a.id });
      return row;
    };

    // Сутки посменных постов внутри этой смены: свой раздел на каждый день.
    const shiftDays = selection.shiftDays.map((sd) => {
      const rows = sd.posts.map(({ post, candidates }) => rowOf(post, candidates, sd.date));
      return {
        date: sd.date,
        nonWorking: sd.nonWorking,
        rows,
        assignedCount: rows.filter((r) => r.current).length,
        brokenCount: rows.filter((r) => r.current && r.current.broken).length,
        postCount: rows.length,
      };
    });

    const rows = selection.posts.map(({ post, candidates }) => rowOf(post, candidates, null));

    days.push({
      startDate: period.startDate,
      period: selection.period,
      duty,
      nonWorking: selection.nonWorking,
      rows,
      shiftDays,
      assignedCount: rows.filter((r) => r.current).length,
      brokenCount: rows.filter((r) => r.current && r.current.broken).length,
      postCount: rows.length,
      workloadFrom: selection.workloadFrom,
    });
  }

  // Оружие назначенных и свободное оружие для выбора — по группам.
  const statuses = await weaponsByAssignment(armedRows.map((x) => x.assignmentId));
  for (const { row, assignmentId } of armedRows) row.weapon.current = statuses.get(assignmentId) || null;

  const weaponOptions = {};
  for (const item of await queries.freeWeapons([...weaponGroups.values()])) {
    if (!weaponOptions[item.key]) weaponOptions[item.key] = [];
    weaponOptions[item.key].push({
      id: item.id, owner: item.owner_id, ownerOnDuty: item.owner_on_duty,
      label: `${weaponLabel({ ...item, serial: item.serial_number })} — ${item.owner || 'не закреплено'}`
        + (item.owner_on_duty ? ' (владелец в наряде без этого оружия — выдать в первую очередь)' : ''),
    });
  }

  // Приказ подписывается только на полностью замещенный состав, поэтому
  // число пустых и испорченных постов считается по блоку целиком — вместе с
  // выходами посменных постов.
  const sections = days.flatMap((d) => [d, ...(d.shiftDays || [])]);
  const unfilledTotal = sections.reduce(
    (sum, s) => sum + (s.postCount - s.assignedCount) + s.brokenCount, 0,
  );

  // Несовместимость разрядов считается ТЕМ ЖЕ правилом, что и проверка при
  // сохранении: форма и сервер не могут разойтись в том, что запрещено.
  const slotConflicts = {};
  for (const pair of cal.findSlotConflicts([...slotClasses.values()], exceptions)) {
    for (const [from, to] of [[pair.first.key, pair.second.key], [pair.second.key, pair.first.key]]) {
      if (!slotConflicts[from]) slotConflicts[from] = [];
      if (!slotConflicts[from].includes(to)) slotConflicts[from].push(to);
    }
  }

  return {
    dutyType,
    deadline,
    days,
    dutyIds: existing.map((d) => d.id),
    postCount: days.length > 0 ? days[0].postCount : 0,
    assignedTotal: sections.reduce((sum, s) => sum + s.assignedCount, 0),
    brokenTotal: sections.reduce((sum, s) => sum + s.brokenCount, 0),
    requiredTotal: sections.reduce((sum, s) => sum + s.postCount, 0),
    unfilledTotal,
    slotConflicts,
    weaponOptions,
    armedOwners: await queries.armedOwners(),
    // Назначенные на пост с оружием, у кого оружия нет или выбрано с нарушением.
    weaponTotal: armedRows.filter(({ row }) => row.weapon.current
      && (row.weapon.current.state === 'missing' || row.weapon.current.problem)).length,
    approved: existing.length === periods.length && existing.every((d) => d.status === 'approved'),
  };
}

/**
 * Оружие, выбранное на странице назначения, — после записи состава, в той
 * же транзакции: замененный человек получил новую строку назначения, и
 * выбор ложится уже на нее. Проверка идет по записанному состоянию, поэтому
 * видит и людей, назначенных этим же сохранением.
 *
 * Выбор у человека со своим годным оружием снимается молча: список выбора
 * ему и не показывается. Нарушение (владелец в наряде в эти или следующие
 * сутки, оружие уже выдано, не тот вид) отклоняет сохранение целиком.
 *
 * @param {Map<string, Map<number, ?number>>} weapons  сутки → (пост → оружие)
 * @returns {boolean} изменилось ли что-нибудь
 */
async function saveBlockWeapons(final, weapons) {
  let changed = false;
  const checked = [];

  for (const day of final) {
    const dutyId = day.old ? day.old.id : day.createdId;
    if (!dutyId) continue;

    const items = [];
    for (const slot of day.slots) {
      const form = weapons.get(slot.formDate);
      if (!form || !form.has(slot.postId)) continue;
      const raw = form.get(slot.postId);
      const weaponId = raw === null ? null : v.id(raw);
      items.push({ postId: slot.postId, onDate: slot.onDate,
        weaponId: slot.post.required_weapon_kind ? weaponId : null });
    }

    if (await queries.setAssignmentWeapons(dutyId, items) > 0) {
      // Прошедшие сутки не правятся — ни составом, ни оружием.
      v.future(day.period.startDate);
      changed = true;
    }
    checked.push(dutyId);
  }

  const rows = (await queries.getAssignmentsForDuties(checked)).filter((r) => r.weapon_id);
  const statuses = await weaponsByAssignment(rows.map((r) => r.id));

  for (const row of rows) {
    const weapon = statuses.get(row.id);
    if (!weapon) continue;
    const place = `«${row.post_name}»${row.on_date ? `, ${row.on_date}` : ''}`;

    if (weapon.state === 'own') {
      await queries.setAssignmentWeapons(row.duty_id,
        [{ postId: row.post_id, onDate: row.on_date, weaponId: null }]);
    } else if (!weapon.kind) {
      v.fail(`${place}: пост оружия не требует.`);
    } else if (weapon.problem) {
      v.fail(`${place}: ${weapon.label} — ${weapon.problem}. Выберите другое оружие.`);
    }
  }

  return changed;
}

/**
 * Сохранение состава всего блока.
 *
 * @param {Map<string, Map<number, ?number>>} byDate  сутки → (пост → сотрудник)
 * @returns {{problems:string[], dutyIds:number[]}}
 */
async function saveBlock({dutyTypeId,date,byDate,weapons=null,userId,source='manual'}) {
 v.id(dutyTypeId);v.date(date);
 const {dutyType,periods,exceptions}=await getBlockDates(dutyTypeId,date);
 if(!periods.length) v.fail('На эту дату наряд не положен.');
 const posts=await queries.listPosts(dutyTypeId);
 const existing=await queries.findDutiesOnDates(dutyTypeId,periods.map(p=>p.startDate));
 const existingByDate=new Map(existing.map(d=>[d.start_date,d]));
 const exceptIds=existing.map(d=>d.id);
 const key=(postId,onDate)=>`${postId}|${onDate||''}`;
 const final=[];
 // Места блока: постоянный состав на весь период смены и выходы посменных
 // постов на каждые свои сутки. Форма присылает их одинаково — полем
 // post_<сутки>_<пост>, — а сутками места распоряжается расписание поста.
 const valid=new Set();
 for(const period of periods) {
   const old=existingByDate.get(period.startDate);
   const current=old ? await queries.getAssignments(old.id):[];
   const slots=[];
   for(const post of posts.filter(p=>!cal.isShiftPost(p)))
     slots.push({post,postId:post.id,onDate:null,formDate:period.startDate,
       startsAt:period.startsAt,endsAt:period.endsAt,
       // Норма отдыха поста сильнее нормы вида наряда: у ПУД она своя, и
       // подбор кандидатов считает ее так же. Иначе человек предлагался бы
       // по одной норме, а отклонялся по другой.
       sleepDays:post.recovery_sleep_days ?? dutyType.recovery_sleep_days,
       allowRepeat:Boolean(post.allow_consecutive ?? dutyType.allow_consecutive),
       allowRepeatKind:post.allow_consecutive===true ? 'post':'type',
       excludeWeekends:dutyType.rest_excludes_weekends});
   for(const [shiftDate,items] of cal.shiftsByDate(period,posts.filter(cal.isShiftPost)))
     for(const item of items)
       slots.push({post:item.post,postId:item.post.id,onDate:shiftDate,formDate:shiftDate,
         startsAt:item.startsAt,endsAt:item.endsAt,
         sleepDays:item.post.recovery_sleep_days ?? dutyType.recovery_sleep_days,
         allowRepeat:Boolean(item.post.allow_consecutive ?? dutyType.allow_consecutive),
         allowRepeatKind:item.post.allow_consecutive===true ? 'post':'type',
         excludeWeekends:false});
   for(const slot of slots) valid.add(`${slot.formDate}|${slot.postId}`);

   const currentBySlot=new Map(current.map(a=>[key(a.post_id,a.on_date),a.employee_id]));
   const desired=new Map(currentBySlot);
   let incoming=false;
   for(const slot of slots) {
     const form=byDate.get(slot.formDate);
     if(!form || !form.has(slot.postId)) continue;
     const employeeId=form.get(slot.postId);
     if(employeeId!==null) v.id(employeeId);
     desired.set(key(slot.postId,slot.onDate),employeeId);
     incoming=true;
   }
   const changed=incoming && slots.some(s=>{
     const k=key(s.postId,s.onDate);
     return (desired.get(k) ?? null)!==(currentBySlot.get(k) ?? null);
   });
   if(changed || (!old && incoming)) v.future(period.startDate);
   const assignments=slots
     .filter(s=>(desired.get(key(s.postId,s.onDate)) ?? null)!==null)
     .map(s=>({postId:s.postId,employeeId:desired.get(key(s.postId,s.onDate)),onDate:s.onDate,
       startsAt:s.startsAt,endsAt:s.endsAt,sleepDays:s.sleepDays,excludeWeekends:s.excludeWeekends,
       allowRepeat:s.allowRepeat,allowRepeatKind:s.allowRepeatKind}));
   final.push({period,old,current,slots,desired,assignments,changed,incoming,currentBySlot});
 }
 for(const [formDate,form] of byDate)
   for(const postId of form.keys())
     if(!valid.has(`${formDate}|${postId}`)) v.fail('Неизвестный или отключённый пост. Обновите форму.');

 // Удалённые из формы даты не исчезают из проверки итогового блока.
 const conflicts=cal.findSlotConflicts(final.flatMap(d=>d.assignments.map(a=>({...a,
   label:`${posts.find(p=>p.id===a.postId)?.short_name || a.postId} ${a.onDate || d.period.startDate}`}))),exceptions);
 for(const c of conflicts) {
   const touched=final.some(d=>d.changed && d.assignments.some(a=>a.employeeId===c.employeeId));
   if(touched) v.fail(`Сотрудник № ${c.employeeId}: ${c.reason==='overlap' ? 'назначен в пересекающиеся' : 'не выдержан отдых между'} «${c.first.label}» и «${c.second.label}».`);
 }
 for(const day of final) if(day.incoming && (day.changed || !day.old)) {
   const changedAssignments=day.assignments.filter(a=>day.currentBySlot.get(key(a.postId,a.onDate))!==a.employeeId);
   await validateRoster(dutyType,day.period.startDate,day.period,day.assignments,posts,exceptIds,{checkOnly:changedAssignments});
 }
 let changed=false;
 for(const day of final) {
   if(!day.incoming) continue;
   if(day.old) {
     if(day.changed) {
       await queries.updateAssignments(day.old.id,
         day.slots.map(s=>({postId:s.postId,onDate:s.onDate,employeeId:day.desired.get(key(s.postId,s.onDate)) ?? null})),
         userId, source);
       changed=true;
     }
   } else {
     day.createdId=await queries.createDuty({dutyTypeId,unitId:await queries.rootUnit(),startsAt:day.period.startsAt,endsAt:day.period.endsAt,assignments:day.assignments,note:null,userId,source});
     changed=true;
   }
 }
 if(weapons && await saveBlockWeapons(final,weapons)) changed=true;
 if(changed) await unapproveBlock(dutyTypeId,date,null,userId);
 return {problems:[],dutyIds:(await queries.findDutiesOnDates(dutyTypeId,periods.map(p=>p.startDate))).map(d=>d.id)};
}

// ----------------------------------------------------------------------------
// Ответственное подразделение
// ----------------------------------------------------------------------------


/** Точечное закрепление поста на сутки. */
async function setPostResponsibility(postId, onDate, unitId, note, userId) {
  v.id(postId);
  v.date(onDate);
  return queries.setPostResponsibility(postId, onDate, unitId ? v.id(unitId) : null, note, userId);
}

/**
 * Очередь подразделений на посту.
 *
 * Одно подразделение — постоянное закрепление, несколько — цикл. Опорные
 * сутки обязательны при очереди из нескольких: без них неизвестно, с кого
 * счет начинается.
 */
async function setPostUnits(postId, unitIds, rotationSince) {
  v.id(postId);
  const ids = unitIds.map((id) => v.id(id));

  if (new Set(ids).size !== ids.length) {
    v.fail('Одно подразделение не может стоять в очереди дважды.');
  }

  if (ids.length > 1) {
    if (!rotationSince) v.fail('Укажите сутки, с которых считается очередь.');
    v.date(rotationSince);
  }

  return queries.setPostUnits(postId, ids, rotationSince || null);
}

async function listPostUnits(dutyTypeId) {
  return queries.listPostUnits(dutyTypeId);
}

/**
 * Удаление поста.
 *
 * Пост, который уже стоял в приказах, не удаляется: прошлые наряды на него
 * ссылаются, и стереть его значило бы стереть историю. Такой пост снимается с
 * применения — он перестает предлагаться в новых нарядах, а старые остаются
 * читаемыми. Удаление оставлено для заведенного по ошибке.
 */
async function removePost(postId) {
  const id = v.id(postId);
  const post = await queries.getPost(id);
  if (!post) v.fail('Пост не найден.', 404);

  const usage = await queries.postUsage(id);

  if (usage.assignments > 0) {
    v.fail(`Пост стоял в нарядах (назначений: ${usage.assignments}). `
      + 'Такой пост не удаляется, а снимается с применения: приказы прошлых '
      + 'периодов должны оставаться читаемыми.');
  }

  if (usage.permits > 0) {
    v.fail(`К посту выданы допуски (${usage.permits}). Сначала отзовите их.`);
  }

  await queries.deletePost(id);
  await invalidateType(post.duty_type_id);
  return post;
}

/** Закрепленный за постом личный состав. */
async function postEmployees(postId) {
  return (await queries.listPostEmployees(v.id(postId))).map((r) => r.employee_id);
}

/** Снятие поста с применения и возврат — без захода в карточку. */
/**
 * Порядок постов вида наряда — перетаскиванием в перечне.
 *
 * Принимается только ПОЛНЫЙ перечень постов вида: частичный оставил бы
 * пропущенные посты со старыми номерами вперемешку с новыми. Состав приказа
 * порядок не меняет, поэтому утверждение приказов не снимается.
 */
async function reorderPosts(typeId, rawIds) {
  const type = v.id(typeId);
  const own = (await queries.listPosts(type)).map((p) => p.id);
  await queries.setPostOrder(type, v.order(rawIds, own));
}

/**
 * Порядок видов нарядов — перетаскиванием во вкладке «Наряды». Тянутся
 * только действующие виды: снятые стоят внизу отдельно. В этом же порядке
 * виды идут в графике.
 */
async function reorderDutyTypes(rawIds) {
  const own = (await queries.listDutyTypes()).map((t) => t.id);
  await queries.setDutyTypeOrder(v.order(rawIds, own));
}

async function setPostActive(postId, active) {
  const id = v.id(postId);
  const post = await queries.getPost(id);
  if (!post) v.fail('Пост не найден.', 404);

  await queries.setPostActive(id, Boolean(active));
  // Состав постов изменился — подписанные будущие приказы пересматриваются.
  await invalidateType(post.duty_type_id);
  return post;
}

/**
 * Кто заступает на пост: очередь подразделений и закрепленный состав —
 * одним сохранением вместе с остальной формой поста.
 *
 * Правила те же, что были у поштучной правки:
 *   • подразделение в очереди один раз, порядок — порядок строк формы;
 *   • сутки отсчета нужны только циклу и, если не заданы, ставятся сами —
 *     иначе форма требовала бы дату отсчета цикла, которого еще нет;
 *   • закрепленный человек — из заступающих подразделений: две настройки
 *     поста не должны противоречить друг другу.
 */
async function savePostStaffing(postId, { unitIds, rotationSince, employeeIds }, userId) {
  const id = v.id(postId);
  const post = await queries.getPost(id);
  if (!post) v.fail('Пост не найден.', 404);

  const units = [];
  for (const raw of unitIds || []) {
    if (raw === '' || raw === null || raw === undefined) continue;
    const unit = v.id(raw);
    if (units.includes(unit)) v.fail('Одно подразделение не может стоять в очереди дважды.');
    units.push(unit);
  }

  let since = String(rotationSince || '').trim() || null;
  if (since) v.date(since);
  if (units.length > 1 && !since) since = post.rotation_since || cal.dayKey(new Date());

  await queries.setPostUnits(id, units, units.length > 1 ? since : null);

  const people = [...new Set((employeeIds || [])
    .filter((x) => x !== '' && x !== null && x !== undefined)
    .map((x) => v.id(x)))];

  if (people.length > 0 && units.length > 0) {
    const allowed = new Set();
    for (const unit of units) for (const sub of await org.subtreeIds(unit)) allowed.add(sub);

    const found = await personnel.getByIds(people);
    const stranger = found.find((person) => !allowed.has(person.unit_id));
    if (stranger) {
      v.fail(`${stranger.short_name} не из подразделения, заступающего на пост. `
        + 'Добавьте его подразделение в очередь или уберите человека из перечня.');
    }
  }

  await queries.setPostEmployees(id, people, userId);
}

/** Очередь подразделений одного поста, по порядку заступления. */
async function postQueue(postId) {
  const rows = await queries.listPostUnits(null);
  return rows.filter((r) => r.post_id === Number(postId)).sort((a, b) => a.turn - b.turn);
}

async function listSettings() {
  return queries.listSettings();
}

/**
 * Правка настройки подбора.
 *
 * Значения проверяются на осмысленность: отрицательный потолок готовности или
 * буквы вместо числа сделали бы подбор необъяснимым, а разбираться пришлось бы
 * по поведению, а не по сообщению.
 */
async function setSetting(key, value, userId) {
  if (!Object.hasOwn(queue.DEFAULTS, key)) v.fail('Неизвестная настройка подбора.');
  if (String(value).trim() === '') v.fail('Укажите значение настройки.');
  const number = Number(String(value).replace(',', '.'));
  if (!Number.isFinite(number)) v.fail(`Настройка «${key}»: нужно число.`);
  if (key === 'queue.ready_max_days' && number < 1) v.fail('Потолок готовности меньше суток.');
  if (key === 'queue.workload_factor' && number < 0) v.fail('Вес нагрузки не может быть отрицательным.');
  if (['queue.ready_max_days', 'queue.min_days_off'].includes(key)
      && (!Number.isInteger(number) || number < 0)) v.fail('Сутки задаются целым неотрицательным числом.');
  if (key === 'queue.unassigned_bonus' && number < 0) v.fail('Надбавка не может быть отрицательной.');

  return queries.setSetting(key, number, userId);
}

async function listPostRankWeights(dutyTypeId) {
  return queries.listPostRankWeights(dutyTypeId);
}

async function setPostRankWeights(postId, items) {
  v.id(postId);
  for (const item of items) {
    v.id(item.rankId);
    if (!Number.isFinite(item.weight)) v.fail('Вес звания: нужно число.');
    // Та же граница, что у личной поправки: больше — уже не предпочтение, а
    // негласный запрет целому званию.
    if (Math.abs(item.weight) > WEIGHT_LIMIT) {
      v.fail(`Вес звания больше ${WEIGHT_LIMIT} по модулю: он перевесит любую очередь.`);
    }
  }
  return queries.setPostRankWeights(postId, items);
}

/**
 * Личные поправки к постам.
 *
 * @param {?number} dutyTypeId  null — по всем видам нарядов
 * @param {?number} employeeId  null — по всем людям
 */
async function listEmployeePostWeights(dutyTypeId, employeeId) {
  const rows = await queries.listEmployeePostWeights(dutyTypeId || null);
  if (!employeeId) return rows;
  return rows.filter((w) => w.employee_id === Number(employeeId));
}

// Поправка сравнима с готовностью, а ее потолок — тридцать суток. Сотня
// перевешивает любую очередь, и такая правка означает уже не предпочтение, а
// негласный запрет: запреты задаются допусками и отсутствиями, а не весами.
const WEIGHT_LIMIT = 100;

/**
 * Личная поправка человека к посту.
 *
 * Пустое значение СНИМАЕТ поправку, а не приравнивает ее к нулю. Для расчета
 * это одно и то же, но в перечне исключений нуль выглядел бы решением,
 * которого никто не принимал, и разбираться в нем пришлось бы заново.
 */
async function setEmployeePostWeight({ employeeId, postId, weight, note, userId }) {
  v.id(employeeId);
  v.id(postId);

  const raw = weight === null || weight === undefined ? '' : String(weight).trim();
  if (raw === '') return queries.setEmployeePostWeight(employeeId, postId, null, null, userId);

  const number = Number(raw.replace(',', '.'));
  if (!Number.isFinite(number)) v.fail('Личная поправка: нужно число.');
  if (Math.abs(number) > WEIGHT_LIMIT) {
    v.fail(`Личная поправка больше ${WEIGHT_LIMIT} по модулю: она перевесит любую очередь.`);
  }

  const text = String(note || '').trim();
  return queries.setEmployeePostWeight(employeeId, postId, number, text || null, userId);
}

/**
 * Очередь одного человека на дату: из чего она складывается.
 *
 * Нужна карточке, чтобы ответить на вопрос «почему его не предлагают». Счет
 * ведется тем же кодом, что и подбор: иначе карточка объясняла бы одно, а
 * система делала другое.
 */
async function employeeQueueState(employeeId, onDate) {
  const workloadFrom = cal.addDays(onDate, -30);

  const [settingRows, lastStarts, workload] = await Promise.all([
    queries.listSettings(),
    queries.lastDutyEnds(`${onDate}T00:00:00`),
    queries.employeeWorkload(workloadFrom, onDate),
  ]);

  const settings = queue.settingsFrom(settingRows);
  const last = lastStarts.find((r) => r.employee_id === Number(employeeId));
  const load = workload.find((r) => r.employee_id === Number(employeeId));

  const value = queue.queueValue(
    { lastDate: last ? last.last_date : null, workload: load ? load.weight : 0 },
    {}, onDate, settings,
  );

  return {
    onDate,
    workloadFrom,
    lastDate: last ? last.last_date : null,
    duties: load ? load.duties : 0,
    // Нагрузка до умножения на коэффициент — чтобы в карточке было видно,
    // из чего вычтенное число получилось.
    workloadRaw: load ? load.weight : 0,
    queue: value,
    settings,
    ready: queue.passes(value, settings),
  };
}

/** Наряды вида, заступающие в указанные дни. */
async function findDutiesOnDates(dutyTypeId, dates, unitId) {
  return queries.findDutiesOnDates(dutyTypeId, dates, unitId);
}

async function getDuty(id) {
  return queries.getDuty(id);
}

/**
 * Утверждение всего приказа: подписывается документ, а не отдельные сутки.
 *
 * Неполный состав утвердить нельзя. Утвержденный приказ — это подписанный
 * документ, и пустой пост в нем означал бы, что в наряд заступать некому, а
 * подпись под этим уже стоит. По той же причине не утверждается состав с
 * нарушением: назначенный, но непригодный человек — тот же пустой пост.
 *
 * @returns {{problems:string[], approved:number}}
 */
async function approveBlock(dutyTypeId,date,unitId,userId) {
 const plan=await getBlockPlan(dutyTypeId,date,null);
 if(!plan) v.fail('На эту дату наряд не положен.');
 if(!plan.postCount) v.fail('Вид наряда не содержит действующих постов.');
 for(const day of plan.days) {
   if(day.duty?.status==='approved' && day.startDate<=cal.dayKey(new Date())) continue;
   v.future(day.startDate);
   // Выходы посменных постов входят в тот же приказ, поэтому и утверждению
   // подлежат вместе с постоянным составом.
   const rows=[...day.rows,...(day.shiftDays||[]).flatMap(s=>s.rows)];
   if(!day.duty || rows.some(r=>!r.current || r.current.broken)) v.fail(`${day.startDate}: утвердить можно только полный состав без неразрешённых нарушений.`);
   // Приказ называет, кому какое оружие получить, — без оружия он неполон.
   const unarmed=rows.find(r=>r.current && r.weapon?.current
     && (r.weapon.current.state==='missing' || r.weapon.current.problem));
   if(unarmed) v.fail(`${day.startDate}: у ${unarmed.current.name} («${unarmed.post.name}») не выбрано оружие`
     +`${unarmed.weapon.current.problem ? ' — '+unarmed.weapon.current.problem : ''}. Выберите его на странице назначения.`);
 }
 const approved=await queries.approveDuties(plan.dutyIds,userId);
 const sections=[];
 for(const day of plan.days) sections.push(await getDutyWithMembers(day.duty.id,day.startDate>cal.dayKey(new Date())));
 // Шаблон и реквизиты части входят в сохраняемую форму: подписанный приказ
 // печатается так, как был утвержден, даже если шаблон потом поправят.
 const order={dutyType:{code:plan.dutyType.code,name:plan.dutyType.name},unitName:sections[0].duty.unit_name,
   sections,orderDate:plan.deadline,totalAssigned:sections.reduce((n,s)=>n+s.roster.length,0),
   template:templateOf(plan.dutyType),
   templateVersion:(await queries.orderTemplateVersions(plan.dutyType.id))[0]?.version || 0,
   context:await orderContextOn(plan.deadline)};
 for(const section of sections) if(cal.dayKey(new Date(section.duty.starts_at))>cal.dayKey(new Date())) await queries.saveSnapshot(section.duty.id,section,order,plan.deadline);
 return {problems:[],approved};
}

/**
 * Возврат приказа в состояние проекта.
 *
 * Отдельной кнопки нет: утверждение снимается САМО, как только меняется
 * состав. Отдельное «снять утверждение» означало бы, что приказ можно
 * оставить неутвержденным и с прежним составом — состояние, которому в
 * делопроизводстве ничего не соответствует.
 *
 * Снимается со всего блока: приказ один, и наполовину подписанным он быть
 * не может.
 */
async function unapproveBlock(dutyTypeId, date, unitId, userId) {
  const { periods } = await getBlockDates(dutyTypeId, date);
  const duties = await queries.findDutiesOnDates(
    dutyTypeId, periods.map((p) => p.startDate), unitId,
  );

  return queries.unapproveDuties(duties.map((d) => d.id), userId);
}

/**
 * Замена одного человека в составе при утверждении приказа.
 *
 * Начальник службы просматривает готовый состав и знает то, чего нет в
 * системе: этот заболел, того забрали на работы. Замена делается по одному
 * посту и с обязательным примечанием — оно попадает в карточку наряда и
 * отмечается в графике, чтобы отступление от подбора не потерялось.
 *
 * @returns {{problems:string[], changed:boolean}}
 */
async function replaceMember({dutyId,postId,employeeId,note,userId,override=false,onDate=null}) {
 const duty=await editableDuty(dutyId);v.id(postId);v.id(employeeId);
 if(onDate) v.date(onDate);
 if(!String(note||'').trim()) v.fail('Укажите причину замены.');
 if(override && !await access.authorizeUser(userId,'duty.override')) v.fail('Исключение может оформить только администратор.',403);
 const posts=await queries.listPosts(duty.duty_type_id);
 const byId=new Map(posts.map(p=>[p.id,p]));
 const type=await queries.getDutyType(duty.duty_type_id);
 if(onDate && !cal.isShiftPost(byId.get(postId))) v.fail('У этого поста нет посуточных выходов.');
 if(!onDate && cal.isShiftPost(byId.get(postId))) v.fail('Не указаны сутки выхода.');
 const current=await queries.getAssignments(dutyId);
 const same=a=>a.post_id===postId && (a.on_date||null)===(onDate||null);
 const assignments=current.filter(a=>!same(a)&&byId.has(a.post_id))
   .map(a=>({postId:a.post_id,employeeId:a.employee_id,...slotInterval(type,duty,byId.get(a.post_id),a.on_date)}));
 const replacement={postId,employeeId,...slotInterval(type,duty,byId.get(postId),onDate)};
 assignments.push(replacement);
 const checks=await validateRoster(type,cal.dayKey(duty.starts_at),{startsAt:duty.starts_at,endsAt:duty.ends_at},assignments,posts,[dutyId],{checkOnly:[replacement],override});
 const changed=await queries.replaceAssignment(dutyId,postId,employeeId,note,userId,onDate);
 if(override && checks.length) await queries.markOverride(dutyId,postId,note,checks,userId,onDate);
 if(changed || (override && checks.length)) await unapproveBlock(duty.duty_type_id,cal.dayKey(duty.starts_at),null,userId);
 return {problems:[],changed};
}

/**
 * Наряд, подготовленный к правке состава.
 *
 * Возвращаются ВСЕ действующие посты вида наряда, а не только замещенные:
 * пост, оставшийся пустым после снятия человека, иначе не из чего было бы
 * замещать. По каждому посту даются кандидаты, доступные на эти сутки, а
 * уже назначенный человек отмечен как текущий.
 */
async function getDutyForEdit(dutyId) {
  const duty = await queries.getDuty(dutyId);
  if (!duty) return null;

  const startDate = cal.dayKey(duty.starts_at);

  const [assignments, selection, broken] = await Promise.all([
    queries.getAssignments(dutyId),
    findCandidatesByPost(duty.duty_type_id, startDate, dutyId),
    // Тот же расчет нарушений, что и в графике: расходиться этим двум
    // представлениям одного наряда нельзя.
    findBrokenAssignments(
      duty.duty_type_id, cal.addDays(startDate, -7), cal.addDays(startDate, 7),
    ),
  ]);

  const slotKey = (postId, onDate) => `${postId}|${onDate || ''}`;
  const assignedBySlot = new Map(assignments.map((a) => [slotKey(a.post_id, a.on_date), a]));
  const assignedIds = new Set(assignments.map((a) => a.employee_id));
  const brokenBySlot = new Map(
    (broken.get(dutyId) || []).map((b) => [slotKey(b.postId, b.onDate), b.reason]),
  );

  const people = await personnel.getByIds([...assignedIds]);
  const personById = new Map(people.map((p) => [p.id, p]));

  const slotClasses = new Map();
  const classOf = (interval) => {
    const key = `${interval.startsAt.valueOf()}:${interval.endsAt.valueOf()}`
      + `:${interval.sleepDays}:${interval.excludeWeekends}`;
    if (!slotClasses.has(key)) slotClasses.set(key, { key, ...interval, employeeId: 1 });
    return key;
  };

  const rowOf = (post, candidates, onDate) => {
    const assigned = assignedBySlot.get(slotKey(post.id, onDate)) || null;
    const person = assigned ? personById.get(assigned.employee_id) : null;
    const reason = brokenBySlot.get(slotKey(post.id, onDate));

    return {
      post,
      candidates,
      onDate: onDate || null,
      slotClass: classOf(slotInterval(selection.dutyType, duty, post, onDate)),
      // Назначенный на пост может отсутствовать среди кандидатов: допуск мог
      // истечь, а человек — попасть в отсутствующие уже после назначения.
      // Снять его в таком случае нужно осознанно, поэтому он показывается —
      // и обязательно по фамилии, иначе снятие делается вслепую.
      current: assigned
        ? {
          id: assigned.employee_id,
          name: person ? person.short_name : `№ ${assigned.employee_id}`,
          note: assigned.note || null,
          inCandidates: candidates.some((c) => c.id === assigned.employee_id),
          broken: reason ? BROKEN_REASON[reason] || reason : null,
        }
        : null,
    };
  };

  const rows = selection.posts.map(({ post, candidates }) => rowOf(post, candidates, null));

  // Выходы посменных постов правятся здесь же, каждый своими сутками.
  const shiftDays = selection.shiftDays.map((sd) => ({
    date: sd.date,
    nonWorking: sd.nonWorking,
    rows: sd.posts.map(({ post, candidates }) => rowOf(post, candidates, sd.date)),
  }));

  const exceptions = new Map(
    (await queries.listCalendarDays(cal.addDays(startDate, -740), cal.addDays(startDate, 740)))
      .map((d) => [d.day, d.kind]),
  );

  const slotConflicts = {};
  for (const pair of cal.findSlotConflicts([...slotClasses.values()], exceptions)) {
    for (const [from, to] of [[pair.first.key, pair.second.key], [pair.second.key, pair.first.key]]) {
      if (!slotConflicts[from]) slotConflicts[from] = [];
      if (!slotConflicts[from].includes(to)) slotConflicts[from].push(to);
    }
  }

  return {
    duty,
    dutyType: selection.dutyType,
    period: selection.period,
    startDate,
    rows,
    shiftDays,
    slotConflicts,
    assignedCount: rows.filter(r => r.current).length
      + shiftDays.reduce((sum, day) => sum + day.rows.filter(r => r.current).length, 0),
    postCount: rows.length + shiftDays.reduce((sum, d) => sum + d.rows.length, 0),
    workloadFrom: selection.workloadFrom,
  };
}

/**
 * Правка состава существующего наряда.
 *
 * @param {Array<{postId:number, onDate:?string, employeeId:?number}>} incoming
 *   места из формы; onDate заполнен у выходов посменных постов
 * @returns {{changed:number, problems:string[]}}
 */
async function updateAssignments(dutyId, incoming, userId) {
 const duty=await editableDuty(dutyId);
 const startDate=cal.dayKey(duty.starts_at);
 const type=await queries.getDutyType(duty.duty_type_id);
 const posts=await queries.listPosts(duty.duty_type_id);
 const byId=new Map(posts.map(p=>[p.id,p]));
 const current=await queries.getAssignments(dutyId);
 const key=(postId,onDate)=>`${postId}|${onDate||''}`;
 const final=new Map(current.map(a=>[key(a.post_id,a.on_date),
   {postId:a.post_id,onDate:a.on_date||null,employeeId:a.employee_id}]));
 for(const s of incoming) {
   if(!byId.has(s.postId)) v.fail('Пост недоступен. Обновите форму.');
   if(s.employeeId!==null) v.id(s.employeeId);
   if(s.onDate) v.date(s.onDate);
   slotInterval(type,duty,byId.get(s.postId),s.onDate);
   final.set(key(s.postId,s.onDate),{postId:s.postId,onDate:s.onDate||null,employeeId:s.employeeId});
 }
 const slots=[...final.values()].filter(s=>byId.has(s.postId));
 const assignments=slots.filter(s=>s.employeeId!==null)
   .map(s=>({...s,...slotInterval(type,duty,byId.get(s.postId),s.onDate)}));
 const changedAssignments=assignments.filter(a=>!current.some(c=>c.post_id===a.postId
   && (c.on_date||null)===(a.onDate||null) && c.employee_id===a.employeeId));
 await validateRoster(type,startDate,{startsAt:duty.starts_at,endsAt:duty.ends_at},assignments,posts,[dutyId],{checkOnly:changedAssignments});
 const changed=await queries.updateAssignments(dutyId,slots,userId);
 if(changed) await unapproveBlock(duty.duty_type_id,startDate,null,userId);
 return {changed,problems:[]};
}

/** Наряд вместе с составом по постам. */
async function getDutyWithMembers(dutyId, live=false) {
  const duty = await queries.getDuty(dutyId);
  if (!duty) return null;

  if(!live && duty.approved_snapshot && cal.dayKey(duty.starts_at)<=cal.dayKey(new Date())) {
    return {...duty.approved_snapshot,duty:{...duty.approved_snapshot.duty,status:duty.status}};
  }
  const [assignments, posts] = await Promise.all([
    queries.getAssignments(dutyId),
    queries.listPosts(duty.duty_type_id),
  ]);
  const members = await personnel.getByIds(assignments.map((a) => a.employee_id));
  const byId = new Map(members.map((m) => [m.id, m]));
  const postById = new Map(posts.map((p) => [p.id, p]));

  // Требуется мест, а не постов: посменный пост занимает по месту на каждые
  // сутки смены, и «8 из 8» при незамещенных выходах ввело бы в заблуждение.
  const period = { startsAt: duty.starts_at, endsAt: duty.ends_at };
  const shiftCount = [...cal.shiftsByDate(period, posts.filter(cal.isShiftPost)).values()]
    .reduce((sum, items) => sum + items.length, 0);
  const postCount = posts.filter((p) => !cal.isShiftPost(p)).length + shiftCount;

  // Порядок постов задан запросом и определяет порядок вывода в приказе.
  const roster = assignments.map((a) => ({
    // Часы поста нужны приказу: ПУД заступает со всей сменой, но несет
    // службу с 08:00 до 18:00, и в документе это отдельный пункт.
    post: {
      id: a.post_id, name: a.post_name, short_name: a.post_short,
      start_time: a.start_time || null, duration_hours: a.duration_hours || null,
    },
    assignmentId: a.id,
    onDate: a.on_date || null,
    employee: byId.get(a.employee_id) || null,
    isOverride: a.is_override,
    overrideReason: a.override_reason,
    note: a.note || null,
  }));

  const broken=await findBrokenAssignments(duty.duty_type_id,cal.dayKey(duty.starts_at),cal.dayKey(duty.ends_at));
  const dutyType=await queries.getDutyType(duty.duty_type_id);
  const active=new Set(posts.map(p=>p.id));
  const activeRoster=roster.filter(r=>active.has(r.post.id));
  for(const r of activeRoster) {
    const problem=(broken.get(dutyId)||[]).find(b=>b.postId===r.post.id && (b.onDate||null)===r.onDate);
    r.broken=problem ? BROKEN_REASON[problem.reason] : null;
  }
  // Оружие: у своего — «получить личное», у выбранного чужого — строка
  // временного закрепления. Текст строки входит в сохраняемую форму приказа.
  const weapons=await weaponsByAssignment(activeRoster.map(r=>r.assignmentId));
  for(const r of activeRoster) {
    r.weapon=weapons.get(r.assignmentId) || null;
    if(r.weapon?.state==='loan' && r.employee) r.weapon.orderLine=weaponOrderLine(r.employee,r.weapon.weapon);
  }
  const {approved_snapshot,order_snapshot,...cleanDuty}=duty;
  return { duty:cleanDuty, roster:activeRoster, postCount, brokenCount:activeRoster.filter(r=>r.broken).length };
}

/**
 * Интервал одного места в наряде.
 *
 * У постоянного состава это период наряда, у выхода посменного поста — его
 * собственные часы. Одно определение на все проверки: занятость, отдых,
 * допуски и оружие берут интервал отсюда.
 */
function slotInterval(dutyType, duty, post, onDate) {
  if (!post) v.fail('Пост недоступен.');
  if (cal.isShiftPost(post)) {
    if (!onDate) v.fail('Не указаны сутки выхода посменного поста.');
    v.date(onDate);
    const shifts = cal.postShifts({ startsAt: duty.starts_at, endsAt: duty.ends_at }, post);
    if (!shifts.some(s => s.date === onDate)) v.fail('Сутки выхода не входят в смену.');
  } else if (onDate) {
    v.fail('У этого поста нет посуточных выходов.');
  }
  if (!post || !cal.isShiftPost(post) || !onDate) {
    return {
      onDate: null,
      startsAt: duty.starts_at,
      endsAt: duty.ends_at,
      // Норма отдыха поста сильнее нормы вида наряда: ПУД несет службу всю
      // смену, но по десять часов в день, и двое суток отдыха после нее не
      // положены.
      sleepDays: (post && post.recovery_sleep_days) ?? dutyType.recovery_sleep_days,
      excludeWeekends: dutyType.rest_excludes_weekends,
    };
  }

  const startsAt = new Date(`${onDate}T${post.start_time}`);
  return {
    onDate,
    startsAt,
    endsAt: new Date(startsAt.getTime() + post.duration_hours * 60 * 60 * 1000),
    sleepDays: post.recovery_sleep_days ?? dutyType.recovery_sleep_days,
    allowRepeat: Boolean(post.allow_consecutive ?? dutyType.allow_consecutive),
    allowRepeatKind: post.allow_consecutive === true ? 'post' : 'type',
    excludeWeekends: false,
  };
}

const OVERRIDABLE=new Set(['absent','post_permit','general_permit','rest']);
async function editableDuty(id) {
 v.id(id);const duty=await queries.getDuty(id);if(!duty) v.fail('Наряд не найден.',404);
 if(duty.status==='cancelled') v.fail('Отменённый наряд изменять нельзя.');
 v.future(cal.dayKey(duty.starts_at));return duty;
}
/**
 * Проверка состава.
 *
 * Назначение может нести СВОЙ интервал (выход посменного поста); если его
 * нет, берется период наряда. Занятость и отдых поэтому проверяются не один
 * раз на весь состав, а по каждому различному интервалу.
 */
async function validateRoster(type,startDate,period,assignments,posts,exceptIds,options={}) {
 const byPost=new Map(posts.map(p=>[p.id,p]));
 const checked=options.checkOnly || assignments;
 for(const a of assignments) {v.id(a.employeeId);if(!byPost.has(a.postId)) v.fail('Пост недоступен.');}
 const slotOf=a=>({startsAt:a.startsAt||period.startsAt,endsAt:a.endsAt||period.endsAt,
   onDate:a.onDate||startDate,
   sleepDays:a.sleepDays ?? byPost.get(a.postId).recovery_sleep_days ?? type.recovery_sleep_days,
   postId:a.postId,
   allowRepeat:Boolean(byPost.get(a.postId).allow_consecutive ?? type.allow_consecutive),
   allowRepeatKind:byPost.get(a.postId).allow_consecutive === true ? 'post' : 'type',
   excludeWeekends:a.excludeWeekends ?? type.rest_excludes_weekends});
 const exceptions=new Map((await queries.listCalendarDays(cal.addDays(startDate,-740),cal.addDays(startDate,740))).map(d=>[d.day,d.kind]));
 // Один человек на двух местах внутри самого наряда: на двух постах одних
 // суток либо на выходе внутри смены, в которой он уже стоит.
 const inner=cal.findSlotConflicts(assignments.map(a=>({...slotOf(a),employeeId:a.employeeId,
   label:byPost.get(a.postId).short_name || byPost.get(a.postId).name})),exceptions)
   .filter(c=>checked.some(a=>a.employeeId===c.employeeId));
 if(inner.length) v.fail(inner.map(c=>`Сотрудник № ${c.employeeId}: «${c.first.label}» и «${c.second.label}» — ${c.reason==='overlap' ? 'места пересекаются' : 'не выдержан отдых'}.`).join(' '));
 const general=await queries.getGeneralPermits(type.id);
 const violations=await personnel.findUnfitAssignments(checked.map(a=>{const s=slotOf(a);return {employeeId:a.employeeId,postId:a.postId,onDate:s.onDate,
   startsAt:s.startsAt,endsAt:s.endsAt,requiredPermit:byPost.get(a.postId).required_permit_type_id,weaponKind:byPost.get(a.postId).required_weapon_kind};}),general.map(p=>p.permit_type_id));
 const groups=new Map();
 for(const a of checked) {
   const s=slotOf(a);
   const k=`${s.startsAt.valueOf?s.startsAt.valueOf():s.startsAt}|${s.endsAt.valueOf?s.endsAt.valueOf():s.endsAt}|${s.sleepDays}|${s.excludeWeekends}`;
   if(!groups.has(k)) groups.set(k,{slot:s,items:[]});
   groups.get(k).items.push(a);
 }
 for(const {slot,items} of groups.values()) {
   const busy=new Set(await queries.findBusyEmployeeIds(slot.startsAt,slot.endsAt,exceptIds));
   const {resting,restingSource:source}=cal.restState(await queries.findRecentDutyEnds(slot.startsAt,exceptIds),exceptions,slot.onDate);
   const forward=new Set(await queries.findEmployeesStartingOn(cal.restDays(cal.dayKey(slot.endsAt),slot.sleepDays,slot.excludeWeekends,exceptions),exceptIds));
   for(const a of items) {
     if(busy.has(a.employeeId)) violations.push({employee_id:a.employeeId,reason:'overlap'});
     const post=byPost.get(a.postId);
     const repeat=Boolean(post.allow_consecutive ?? type.allow_consecutive);
     const from=source.get(a.employeeId);
     // Отдых со СВОЕГО места, куда разрешено заступать подряд, нарушением не
     // считается: человек его отбывает, но поставить его сюда можно снова.
     const ownRest=repeat && from && (post.allow_consecutive===true
       ? from.postId===a.postId : from.dutyTypeId===type.id);
     if((resting.has(a.employeeId) && !ownRest) || (forward.has(a.employeeId) && !repeat)) {
       violations.push({employee_id:a.employeeId,reason:'rest'});
     }
   }
 }
 const forbidden=violations.filter(x=>!options.override || !OVERRIDABLE.has(x.reason));
 if(forbidden.length) v.fail(forbidden.map(x=>`Сотрудник № ${x.employee_id}: ${BROKEN_REASON[x.reason]}.`).join(' '));
 return [...new Set(violations.map(x=>x.reason))];
}
async function validatePost(data) {
 v.id(data.dutyTypeId);if(!String(data.name||'').trim()) v.fail('Укажите название поста.');
 if(data.requiredWeaponKind && !['rifle','pistol'].includes(data.requiredWeaponKind)) v.fail('Неизвестный вид оружия.');
 if(data.requiredPermitTypeId && !(await personnel.listPermitTypes()).some(p=>p.id===data.requiredPermitTypeId)) v.fail('Неизвестный допуск.');
}
async function invalidateType(typeId) {
 const duties=(await queries.listFutureDuties()).filter(d=>d.duty_type_id===typeId);
 await queries.unapproveDuties(duties.map(d=>d.id),null);
}
async function calendarSignatures() {
 const map=new Map();
 for(const d of await queries.listFutureDuties()) {
   const date=cal.dayKey(d.starts_at);const block=await getBlockDates(d.duty_type_id,date);
   const rest=cal.restDays(cal.dayKey(d.ends_at),block.dutyType.recovery_sleep_days,block.dutyType.rest_excludes_weekends,block.exceptions);
   map.set(d.id,{d,signature:JSON.stringify([block.deadline,block.periods.map(p=>p.startDate),rest])});
 }
 return map;
}
async function invalidateCalendarChanges(before,userId) {
 const after=await calendarSignatures();
 for(const [id,entry] of after) if(before.get(id)?.signature!==entry.signature) {
   await queries.unapproveDuties([id],userId);
   await unapproveBlock(entry.d.duty_type_id,cal.dayKey(entry.d.starts_at),null,userId);
 }
}
// ----------------------------------------------------------------------------
// Шаблон приказа
//
// У каждого вида наряда свой шаблон: параметры листа и блоки. Настраивается
// во вкладке «Наряды», у вида — «Приказ». Раскладка — order-template.js.
// ----------------------------------------------------------------------------

/**
 * Реквизиты и подписанты приказа на дату приказа: командир части и под ним
 * начальник штаба; на время их отсутствия — ВРИО (назначенный или
 * предложенный системой). Входят в сохраняемую форму приказа.
 */
async function orderContextOn(date) {
  const signers = await org.orderSigners(date);
  const pack = (s) => (s && s.person ? {
    last_name: s.person.last_name, first_name: s.person.first_name, middle_name: s.person.middle_name,
    rank_name: s.person.rank_name, title: s.title, acting: s.acting,
  } : null);
  return { unit: signers.unit, commander: pack(signers.commander), chief: pack(signers.chief) };
}

/** Действующий шаблон вида: свой или по умолчанию. */
function templateOf(dutyType) {
  if (!dutyType || !dutyType.order_template) return orderTemplate.DEFAULT_TEMPLATE;
  try {
    return orderTemplate.normalize(dutyType.order_template);
  } catch {
    // Испорченный сохраненный шаблон не должен ронять печать.
    return orderTemplate.DEFAULT_TEMPLATE;
  }
}

async function getOrderTemplate(typeId) {
  const type = await queries.getDutyType(v.id(typeId));
  if (!type) return null;
  const versions = await queries.orderTemplateVersions(type.id);
  return {
    type, template: templateOf(type), custom: Boolean(type.order_template),
    version: versions.length > 0 ? versions[0].version : 0, versions,
  };
}

function checkReason(reason) {
  const text = String(reason || '').trim();
  if (!text) v.fail('Укажите основание изменения шаблона приказа.');
  if (text.length > 500) v.fail('Основание длиннее 500 знаков.');
  return text;
}

/**
 * Изменение шаблона приказа — всегда новой версией с основанием и автором.
 * reset — возврат к шаблону по умолчанию; restore — номер прежней версии.
 */
async function saveOrderTemplate(typeId, body, userId, { reset = false, restore = null } = {}) {
  const type = await queries.getDutyType(v.id(typeId));
  if (!type) v.fail('Вид наряда не найден.', 404);
  const reason = checkReason(body.reason);

  let template;
  if (reset) {
    template = null;
  } else if (restore !== null) {
    const old = (await queries.orderTemplateVersions(type.id)).find((x) => x.version === Number(restore));
    if (!old) v.fail('Такой версии шаблона нет.', 404);
    template = old.template === null ? null : orderTemplate.normalize(old.template);
  } else {
    template = orderTemplate.fromForm(body);
  }
  return queries.setOrderTemplate(type.id, template, reason, userId);
}

/**
 * Образец приказа для предпросмотра шаблона: посты вида с условными
 * людьми — синтетическими, без обращения к личному составу.
 */
async function sampleOrder(typeId, days = 1) {
  const type = await queries.getDutyType(v.id(typeId));
  if (!type) return null;
  const count = Math.min(Math.max(Number(days) || 1, 1), 4);
  const posts = await queries.listPosts(type.id);
  const date = cal.addDays(cal.dayKey(new Date()), 7);
  const hours = type.duration_hours || 24;
  const sample = { rank_name: 'рядовой', full_name: 'Образцов Иван Иванович',
    last_name: 'Образцов', first_name: 'Иван', middle_name: 'Иванович' };

  // Сутки образца идут подряд — как приказ на выходные или праздники.
  const sections = [];
  for (let i = 0; i < count; i += 1) {
    const start = new Date(`${cal.addDays(date, i)}T${(type.start_time || '18:00').slice(0, 5)}:00`);
    const roster = posts.map((post) => ({
      post: { id: post.id, name: post.name, start_time: null, duration_hours: null },
      onDate: null, employee: sample,
      weapon: post.required_weapon_kind ? { kind: post.required_weapon_kind, state: 'own' } : null,
    }));
    const armed = roster.find((r) => r.weapon);
    if (armed) {
      armed.weapon = { ...armed.weapon, state: 'loan', orderLine: weaponOrderLine(sample,
        { kind: armed.weapon.kind, serial: `АА00000${i}`, year: 2000 }) };
    }
    sections.push({ duty: { starts_at: start, ends_at: new Date(+start + hours * 3600000) },
      roster, postCount: roster.length });
  }

  return {
    dutyType: { code: type.code, name: type.name },
    sections, orderDate: cal.addDays(date, -2),
    totalAssigned: sections.reduce((n, sec) => n + sec.roster.length, 0),
    template: templateOf(type), context: await orderContextOn(cal.addDays(date, -2)), sample: true,
  };
}

/** Приказ к печати: форма старого утверждения без шаблона — по текущему. */
async function completeOrder(order, dutyTypeId) {
  if (!order) return null;
  const type = order.template ? null : await queries.getDutyType(dutyTypeId);
  return {
    ...order,
    template: order.template ? orderTemplate.normalize(order.template) : templateOf(type),
    context: order.context || await orderContextOn(order.orderDate || cal.dayKey(new Date())),
  };
}

async function getPrintableOrder(dutyId) {
 const duty=await queries.getDuty(v.id(dutyId));if(!duty) return null;
 if(duty.status!=='approved') v.fail('Печать доступна только для утверждённого приказа.');
 if(cal.dayKey(duty.starts_at)<=cal.dayKey(new Date())) {
   if(!duty.order_snapshot) v.fail('У старого приказа нет сохранённой утверждённой формы.');
   return completeOrder(duty.order_snapshot,duty.duty_type_id);
 }
 const plan=await getBlockPlan(duty.duty_type_id,cal.dayKey(duty.starts_at),null);
 if(!plan?.approved || plan.unfilledTotal || !plan.postCount) v.fail('Приказ неполный или требует повторного утверждения.');
 if(!duty.order_snapshot) v.fail('Требуется повторное утверждение приказа.');
 return completeOrder(duty.order_snapshot,duty.duty_type_id);
}

module.exports = {
  employeeAssignments,
 getPrintableOrder, getOrderTemplate, saveOrderTemplate, sampleOrder,
 // Раскладка приказа по шаблону и справочники страницы шаблона — для
 // печати (модуль order) и страницы настройки.
 orderLayout:(order)=>orderTemplate.layout(order.template,order),
 orderTemplateOptions:{kinds:orderTemplate.KINDS,aligns:orderTemplate.ALIGNS,
   formats:orderTemplate.FORMATS,placeholders:orderTemplate.PLACEHOLDERS},
 listPermitTypes:personnel.listPermitTypes,
 listFutureDuties:queries.listFutureDuties,
  listDutyTypes,
  listAllDutyTypes,
  getDutyTypeCard,
  createDutyType,
  updateDutyType,
  removeDutyType,
  listUnits,
  listDuties,
  listPosts,
  listAllPosts,
  getPost,
  reorderPosts,
  reorderDutyTypes,
  createPost,
  updatePost,
  findCandidatesByPost,
  getMonthSchedule,
  getDutyState,
  withdrawEmployee,
  dropFromFutureDuties,
  listStoredOrders: (typeId) => queries.listStoredOrders(v.id(typeId)),
  getDutyForEdit,
  updateAssignments,
  getBlockDates,
  getBlockPlan,
  findDutiesOnDates,
  autoFill,
  autoFillPlan,
  postResponsibility,
  setPostResponsibility,
  setPostUnits,
  listPostUnits,
  postQueue,
  setPostActive,
  postAssignmentCounts: queries.postAssignmentCounts,
  postEmployees,
  removePost,
  postUsage: queries.postUsage,
  savePostStaffing,
  listSettings,
  setSetting,
  listPostRankWeights,
  setPostRankWeights,
  listEmployeePostWeights,
  setEmployeePostWeight,
  employeeQueueState,
  getDuty,
  saveBlock,
  approveBlock,
  replaceMember,
  listCalendarDays,
  listCalendarRanges,
  setCalendarRange,
  deleteCalendarRange,
  createDuty,
  getDutyWithMembers,
};

// Вложенные запросы обоих модулей используют тот же клиент транзакции.
for(const name of ['createDutyType','updateDutyType','removeDutyType','createDuty','saveBlock','updateAssignments','replaceMember','withdrawEmployee','approveBlock',
 'setCalendarRange','deleteCalendarRange','createPost','updatePost','getPrintableOrder','saveOrderTemplate']) {
 const fn=module.exports[name];module.exports[name]=(...args)=>db.transaction(()=>fn(...args));
}
