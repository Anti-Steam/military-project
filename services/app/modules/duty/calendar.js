'use strict';

// Расчет графика нарядов на месяц.
//
// Функции здесь чистые: принимают данные, возвращают результат, в БД не
// обращаются. Главная мысль модуля — календарь строится не по созданным
// нарядам, а по ПОЛОЖЕННЫМ. Наряд, который должен был быть назначен и не
// назначен, не оставляет в БД никакого следа; если рисовать только то, что
// есть, пропуск останется невидимым, а именно его и нужно показать.

const { computePeriod, isoWeekday } = require('./candidateFilter');

const MS_IN_DAY = 24 * 60 * 60 * 1000;

// Состояния дня, в порядке возрастания благополучия.
const STATUS = {
  MISSING:    'missing',     // наряд положен, но не создан
  INCOMPLETE: 'incomplete',  // созданы не все посты
  OVERDUE:    'overdue',     // не закрыт, но день уже наступил или прошел
  AUTO:       'auto',        // состав предложен системой, не подтвержден
  PENDING:    'pending',     // состав назначен человеком, не утвержден
  APPROVED:   'approved',    // утвержден
  CANCELLED:  'cancelled',   // отменен
};

const STATUS_TITLE = {
  [STATUS.MISSING]:    'Наряд не назначен',
  [STATUS.INCOMPLETE]: 'Состав неполный',
  [STATUS.OVERDUE]:    'Прошло, состав не закрыт',
  [STATUS.AUTO]:       'Предложено системой, требуется подтверждение',
  [STATUS.PENDING]:    'Назначен, ожидает утверждения',
  [STATUS.APPROVED]:   'Утвержден',
  [STATUS.CANCELLED]:  'Отменен',
};

// ----------------------------------------------------------------------------
// Даты
//
// Дни календаря представлены строками YYYY-MM-DD, а не объектами Date.
// Ключ дня должен оставаться одним и тем же независимо от времени суток и
// смещения; со строкой это выполняется само собой.
// ----------------------------------------------------------------------------

/** Ключ дня для даты в местном времени. */
function dayKey(date) {
  const y = date.getFullYear();
  const m = String(date.getMonth() + 1).padStart(2, '0');
  const d = String(date.getDate()).padStart(2, '0');
  return `${y}-${m}-${d}`;
}

/** Полдень выбран намеренно: сдвиг на час при переводе времени не меняет дату. */
function dayDate(key) {
  require('../../lib/validation').date(key);
  const [y, m, d] = key.split('-').map(Number);
  return new Date(y, m - 1, d, 12, 0, 0);
}

function addDays(key, count) {
  const date = dayDate(key);
  date.setDate(date.getDate() + count);
  return dayKey(date);
}

/** Перечень дней от from до to включительно. */
function daysBetween(from, to) {
  const out = [];
  for (let key = from; key <= to; key = addDays(key, 1)) out.push(key);
  return out;
}

// ----------------------------------------------------------------------------
// Рабочие и нерабочие дни
// ----------------------------------------------------------------------------

/**
 * Нерабочий ли день.
 *
 * Суббота и воскресенье нерабочие по умолчанию; справочник хранит только
 * отклонения — праздник среди недели и рабочий день, перенесенный на выходной.
 *
 * @param {string} key      день, YYYY-MM-DD
 * @param {Map<string,string>} exceptions  день → 'holiday' | 'workday'
 */
function isNonWorking(key, exceptions) {
  const kind = exceptions.get(key);
  if (kind === 'workday') return false;
  if (kind === 'holiday') return true;
  return isoWeekday(dayDate(key)) >= 6;
}

/**
 * Срок выпуска приказа на наряд, заступающий в указанный день, —
 * ближайший предшествующий рабочий день.
 *
 * Одно это правило дает и обычный порядок «приказ накануне», и порядок на
 * нерабочие дни: для субботы, воскресенья и понедельника ближайшим
 * предшествующим рабочим днем оказывается одна и та же пятница, поэтому все
 * три наряда и попадают в один пятничный приказ.
 *
 * Ограничение в 30 шагов защищает от зацикливания, если справочник объявит
 * нерабочим целый месяц.
 */
function orderDeadline(key, exceptions) {
  let cursor = addDays(key, -1);
  for (let step = 0; step < 370; step += 1) {
    if (!isNonWorking(cursor, exceptions)) return cursor;
    cursor = addDays(cursor, -1);
  }
  return null;
}

/**
 * Дни отсыпного после сдачи наряда.
 *
 * Отсыпной начинается в день сдачи. В отсыпной привлечение к другим нарядам
 * запрещено (раздел 8.4), поэтому именно эти дни исключают человека из
 * кандидатов — без этого правила один и тот же человек назначается в наряд
 * двое суток подряд: наряд, заступающий ровно в момент сдачи предыдущего,
 * с ним не пересекается и проверкой занятости не отсеивается.
 *
 * У дежурной смены «Охрана и оборона» отдых считается без учета выходных:
 * суббота и воскресенье в счет двух суток не идут, но человек в эти дни
 * все равно отдыхает. Поэтому нерабочий день попадает в перечень, но норму
 * отдыха не расходует.
 *
 * @param {string}  endDate         день сдачи, YYYY-MM-DD
 * @param {number}  sleepDays       норма отсыпного в сутках
 * @param {boolean} excludeWeekends не засчитывать нерабочие дни в норму
 * @param {Map}     exceptions      справочник празднично-выходных дней
 * @returns {string[]} дни, в которые привлечение запрещено
 */
function restDays(endDate, sleepDays, excludeWeekends, exceptions) {
  if (!sleepDays || sleepDays < 1) return [];

  const days = [];
  let cursor = endDate;
  let counted = 0;

  // Предел защищает от зацикливания, если справочник объявит нерабочим
  // непрерывный период длиннее месяца.
  for (let step = 0; step < 740 && counted < sleepDays; step += 1) {
    days.push(cursor);
    if (!excludeWeekends || !isNonWorking(cursor, exceptions)) counted += 1;
    cursor = addDays(cursor, 1);
  }

  return days;
}

/**
 * Состояние отдыха сотрудников на указанный день.
 *
 * @param {Array}  recentEnds  сданные наряды: employee_id, end_date и норма отдыха
 * @param {Map}    exceptions  справочник празднично-выходных дней
 * @param {string} onDate      день, на который проверяется состояние
 * @returns {{resting: Map, justRested: Map}}
 *   resting    — находится в отсыпном, привлекать запрещено;
 *   justRested — отсыпной кончился накануне: запрета нет, но человека
 *                привлекают при первой же возможности.
 */
function restState(recentEnds, exceptions, onDate) {
  const resting = new Map();
  const justRested = new Map();
  // Откуда отдых: вид наряда и пост. Нужно там, где заступать подряд
  // разрешено: человек отдых отбывает, но на ЭТОТ ЖЕ пост его можно поставить
  // снова, а на чужой — нет.
  const restingSource = new Map();
  const dayBefore = addDays(onDate, -1);

  for (const row of recentEnds) {
    const days = restDays(
      row.end_date, row.recovery_sleep_days, row.rest_excludes_weekends, exceptions,
    );
    // Называется ПОСТ, а не вид наряда: «дневальный по 1-й роте» говорит
    // о человеке все, а «СН» — только к какому приказу он относится.
    const label = row.post_name || row.duty_code;
    if (days.includes(onDate)) {
      resting.set(row.employee_id, label);
      restingSource.set(row.employee_id,
        { dutyTypeId: row.duty_type_id, postId: row.post_id });
    }
    if (days.length > 0 && days[days.length - 1] === dayBefore) {
      justRested.set(row.employee_id, label);
    }
  }

  // Находящийся в отсыпном не может одновременно из него выходить
  for (const id of resting.keys()) justRested.delete(id);

  return { resting, justRested, restingSource };
}

// ----------------------------------------------------------------------------
// Положенные наряды
// ----------------------------------------------------------------------------

/**
 * Наряды, положенные по расписанию вида наряда, за период.
 *
 * Суточный наряд положен ежедневно. Многодневная смена — только в дни
 * недели, предусмотренные расписанием, и занимает в календаре несколько
 * дней подряд. День сдачи в занятые не входит: в этот день заступает
 * следующая смена, и день принадлежит ей.
 *
 * @returns {Array<{startDate, startsAt, endsAt, days, covers: string[]}>}
 */
function expectedDuties(dutyType, schedules, from, to, exceptions) {
  const multiday = dutyType.kind === 'multiday';

  // Многодневная смена, начавшаяся до начала периода, занимает его первые
  // дни, поэтому отсчет ведется с запасом в неделю назад.
  const scanFrom = multiday ? addDays(from, -7) : from;
  const startWeekdays = new Set(schedules.map((s) => s.start_weekday));

  // Дни недели теперь задаются и ежедневному наряду: пустой перечень
  // означает «каждые сутки», непустой — только эти дни. У смены перечень
  // обязателен, иначе неизвестно, когда она заступает.
  const byWeekday = multiday || startWeekdays.size > 0;

  // Отношение к нерабочим дням задается отдельно: праздник среди недели и
  // рабочая суббота объявляются постановлением, а не днем недели.
  const holidays = exceptions || new Map();
  const rule = dutyType.holiday_rule || 'any';

  const out = [];

  for (const key of daysBetween(scanFrom, to)) {
    if (byWeekday && !startWeekdays.has(isoWeekday(dayDate(key)))) continue;

    if (rule !== 'any') {
      const nonWorking = isNonWorking(key, holidays);
      if (rule === 'only' && !nonWorking) continue;
      if (rule === 'never' && nonWorking) continue;
    }

    const period = computePeriod(dutyType, schedules, key);
    const days = multiday
      ? Math.max(1, Math.round((period.endsAt - period.startsAt) / MS_IN_DAY))
      : 1;

    const covers = daysBetween(key, addDays(key, days - 1))
      .filter((d) => d >= from && d <= to);

    if (covers.length === 0) continue;

    out.push({
      startDate: key,
      startsAt: period.startsAt,
      endsAt: period.endsAt,
      days,
      covers,
    });
  }

  return out;
}

/**
 * Наряд, заступление которого уже наступило или прошло.
 *
 * Приказ на текущие сутки не выпускается: к моменту заступления он должен
 * быть подписан. Поэтому сегодняшний день относится к прошедшим наравне со
 * вчерашним — повлиять на его состав уже нельзя.
 */
function isPast(period, today) {
  return period.startDate <= today;
}

/**
 * Выходы посменного поста внутри периода наряда.
 *
 * Пост со своим графиком (ПТСО, ПУД) сменяется каждый день и не совпадает с
 * периодом смены: ПТСО 2 заступает в 20:00 на двенадцать часов, ПУД — в
 * 08:00 на десять. Такой пост относится к той смене, которая несет службу
 * В ЧАС ЕГО ЗАСТУПЛЕНИЯ. Одно это правило распределяет все выходы между
 * приказами без пропусков и без двойного счета: пятничный дневной ПУД
 * попадает во вторничный приказ (смена сдает в 17:30), а пятничный ночной
 * ПТСО 2 — уже в пятничный.
 *
 * Пост без собственного графика замещается на весь наряд и выходов не имеет.
 *
 * @returns {Array<{date:string, startsAt:Date, endsAt:Date}>}
 */
function postShifts(period, post) {
  if (!isShiftPost(post)) return [];

  const out = [];
  const from = addDays(dayKey(period.startsAt), -1);
  const to = addDays(dayKey(period.endsAt), 1);

  for (const date of daysBetween(from, to)) {
    const startsAt = new Date(`${date}T${post.start_time}`);
    if (startsAt < period.startsAt || startsAt >= period.endsAt) continue;

    out.push({
      date,
      startsAt,
      endsAt: new Date(startsAt.getTime() + post.duration_hours * 60 * 60 * 1000),
    });
  }

  return out;
}

/**
 * Выходы всех посменных постов наряда, сгруппированные по суткам.
 *
 * @returns {Map<string, Array<{post:object, startsAt:Date, endsAt:Date}>>}
 */
function shiftsByDate(period, posts) {
  const byDate = new Map();

  for (const post of posts) {
    for (const shift of postShifts(period, post)) {
      if (!byDate.has(shift.date)) byDate.set(shift.date, []);
      byDate.get(shift.date).push({ post, startsAt: shift.startsAt, endsAt: shift.endsAt });
    }
  }

  return new Map([...byDate].sort((a, b) => a[0].localeCompare(b[0])));
}

/**
 * Пост, замещаемый на каждые сутки смены отдельно.
 *
 * Часы поста этого не определяют: у ПУД свои часы (08:00–18:00), но
 * заступает он вместе со всей сменой и несет службу все ее дни. Посуточное
 * замещение — отдельное свойство поста.
 */
function isShiftPost(post) {
  return Boolean(post?.per_day && post.start_time && post.duration_hours);
}

/** Номер выхода от опорных суток. Расписание повторяется каждые 7 дней. */
function rotationTurn(dutyType, schedules, post, since, date, exceptions) {
  if (!since || date < since) return null;
  const end = addDays(since, 6);
  const dates = new Set();
  for (const period of expectedDuties(dutyType, schedules, since, end, exceptions)) {
    const starts = isShiftPost(post) ? postShifts(period, post).map(s => s.date) : [period.startDate];
    for (const start of starts) if (start >= since && start <= end) dates.add(start);
  }
  const offsets = [...dates].map(d => Math.round((dayDate(d) - dayDate(since)) / MS_IN_DAY));
  const elapsed = Math.round((dayDate(date) - dayDate(since)) / MS_IN_DAY);
  const remainder = elapsed % 7;
  if (!offsets.includes(remainder)) return null;
  return Math.floor(elapsed / 7) * offsets.length + offsets.filter(n => n <= remainder).length;
}

/**
 * Сутки блока, в которые нельзя назначить ОДНОГО И ТОГО ЖЕ человека.
 *
 * Правило то же самое, что и при отборе кандидатов: наряд, заступающий до
 * сдачи предыдущего либо в его отсыпной, второй раз того же человека принять
 * не может. Здесь оно применяется к суткам, а не к людям, — получается
 * таблица «эти сутки с этими несовместимы», пригодная и для проверки на
 * сервере, и для мгновенной фильтрации списков в форме.
 *
 * @param {Array<{startDate:string, endsAt:Date}>} periods
 * @returns {Map<string, string[]>} сутки → несовместимые с ними сутки
 */
function conflictingDates(periods, sleepDays, excludeWeekends, exceptions) {
  const ordered = [...periods].sort((a, b) => a.startDate.localeCompare(b.startDate));
  const map = new Map(ordered.map((p) => [p.startDate, []]));

  for (let i = 0; i < ordered.length; i += 1) {
    const rest = restDays(dayKey(ordered[i].endsAt), sleepDays, excludeWeekends, exceptions);

    for (let j = i + 1; j < ordered.length; j += 1) {
      const conflict = ordered[j].startDate < dayKey(ordered[i].endsAt)
        || rest.includes(ordered[j].startDate);

      if (!conflict) continue;

      map.get(ordered[i].startDate).push(ordered[j].startDate);
      map.get(ordered[j].startDate).push(ordered[i].startDate);
    }
  }

  return map;
}

/**
 * Пересечения и нарушения отдыха в НАБОРЕ МЕСТ.
 *
 * Место — это пост вместе с интервалом, на который он замещается: у
 * постоянного состава смены это весь ее период, у посменного поста (ПТСО,
 * ПУД) — его выход. Одна проверка покрывает все случаи сразу: один человек
 * на двух постах одних суток, он же в соседние сутки блока, он же на выходе
 * внутри смены, в которой уже стоит.
 *
 * Проверяются именно ЗАДУМАННЫЕ места, а не сохраненные: наряды блока
 * создаются одной формой и в базе на момент проверки еще не существуют.
 *
 * @param {Array<{employeeId:number, startsAt:Date, endsAt:Date,
 *                sleepDays:number, excludeWeekends:boolean, label:string}>} slots
 * @returns {Array<{employeeId:number, first:object, second:object, reason:string}>}
 */
function findSlotConflicts(slots, exceptions) {
  const conflicts = [];
  const byEmployee = new Map();

  for (const slot of slots) {
    if (slot.employeeId === null || slot.employeeId === undefined) continue;
    if (!byEmployee.has(slot.employeeId)) byEmployee.set(slot.employeeId, []);
    byEmployee.get(slot.employeeId).push(slot);
  }

  for (const [employeeId, list] of byEmployee) {
    list.sort((a, b) => a.startsAt - b.startsAt);

    for (let i = 0; i < list.length; i += 1) {
      const rest = restDays(
        dayKey(list[i].endsAt), list[i].sleepDays, list[i].excludeWeekends, exceptions,
      );

      for (let j = i + 1; j < list.length; j += 1) {
        const overlaps = list[j].startsAt < list[i].endsAt;
        const inRest = rest.includes(dayKey(list[j].startsAt));
        if (!overlaps && !inRest) continue;

        // Отдых не мешает там, где заступать подряд разрешено: человек его
        // отбывает, но на это место его можно поставить снова. Пересечение по
        // времени остается нарушением всегда — в двух местах сразу не стоят.
        if (!overlaps && list[j].allowRepeat
            && (list[j].postId === list[i].postId
                || list[j].allowRepeatKind === 'type')) continue;

        conflicts.push({
          employeeId, first: list[i], second: list[j], reason: overlaps ? 'overlap' : 'rest',
        });
      }
    }
  }

  return conflicts;
}

/**
 * Нарушения отдыха ВНУТРИ приказного блока.
 *
 * Наряды блока назначаются одной формой и в базе на момент проверки еще не
 * существуют, поэтому обычная проверка отсыпного их не видит: она опирается
 * на уже сохраненные наряды. Без этой проверки один человек уходил бы в
 * субботу и воскресенье подряд — то самое, что отсыпной и запрещает.
 *
 * @param {Array<{startDate:string, endsAt:Date, employees:Set<number>}>} days
 * @returns {Array<{employeeId:number, from:string, to:string}>}
 */
function findRestConflicts(days, sleepDays, excludeWeekends, exceptions) {
  const conflicts = [];
  const byDate = new Map(days.map((d) => [d.startDate, d.employees]));
  const incompatible = conflictingDates(days, sleepDays, excludeWeekends, exceptions);

  for (const [from, others] of incompatible) {
    for (const to of others) {
      // Пара суток встречается в таблице дважды; берется та половина, где
      // первые сутки раньше, иначе каждое нарушение удвоится.
      if (to <= from) continue;

      for (const employeeId of byDate.get(to)) {
        if (byDate.get(from).has(employeeId)) {
          conflicts.push({ employeeId, from, to });
        }
      }
    }
  }

  return conflicts;
}

/**
 * Приказной блок — наряды, охватываемые ОДНИМ приказом.
 *
 * Приказ выпускается на весь блок нерабочих дней вместе с первым рабочим
 * днем после него: в пятницу подписывается приказ на субботу, воскресенье и
 * понедельник. Признак принадлежности к одному приказу выводить не нужно —
 * им служит СРОК ВЫПУСКА. Все наряды блока имеют один и тот же ближайший
 * предшествующий рабочий день, и это же свойство делает их одним приказом.
 *
 * Для суточных нарядов блок нерабочих дней дает три-четыре записи, обычный
 * рабочий день — одну. Многодневная смена всегда одна: следующая заступает
 * через несколько суток и попадает в другой срок.
 *
 * @returns {Array} записи expectedDuties, упорядоченные по дате заступления
 */
function orderBlock(dutyType, schedules, date, exceptions) {
  const deadline = orderDeadline(date, exceptions);
  if (!deadline) return [];

  // Запас перекрывает самый длинный блок: новогодние каникулы плюс первый
  // рабочий день не выходят за две недели.
  const expected = expectedDuties(
    dutyType, schedules, addDays(date, -370), addDays(date, 370), exceptions,
  );

  return expected.filter((p) => orderDeadline(p.startDate, exceptions) === deadline);
}

/**
 * Состояние положенного наряда.
 *
 * Незакрытый наряд за прошедший день выделяется отдельным состоянием.
 * Красным он больше не показывается: красный означает «нужно сделать», а
 * сделать с прошедшими сутками уже нечего. Но и скрывать их нельзя —
 * по ним видно фактическую заполненность месяца.
 *
 * @param {object|null} duty  запись наряда из БД, если создан
 * @param {number} postCount  число действующих постов вида наряда
 * @param {boolean} past      день заступления наступил или прошел
 */
function dutyStatus(duty, postCount, past) {
  if (!duty) return past ? STATUS.OVERDUE : STATUS.MISSING;
  if (duty.status === 'cancelled') return STATUS.CANCELLED;
  if (duty.assigned_count < postCount) return past ? STATUS.OVERDUE : STATUS.INCOMPLETE;
  if (duty.status === 'approved') return STATUS.APPROVED;
  if (duty.auto_count > 0) return STATUS.AUTO;
  return STATUS.PENDING;
}

/**
 * Требует ли наряд немедленных действий.
 *
 * Отмечается, когда состав не закрыт, срок выпуска приказа наступил или
 * прошел, а заступление еще впереди. Прошедшие и текущие сутки исключены:
 * приказ на них уже не выпускается, и мигание призывало бы к тому, чего
 * сделать нельзя.
 */
function isUrgent(status, period, deadline, today) {
  if (status !== STATUS.MISSING && status !== STATUS.INCOMPLETE) return false;
  if (isPast(period, today)) return false;
  return Boolean(deadline) && deadline <= today;
}

// ----------------------------------------------------------------------------
// Сетка месяца
// ----------------------------------------------------------------------------

/**
 * Недели месяца, начиная с понедельника. Дни соседних месяцев включаются,
 * чтобы сетка оставалась прямоугольной, и помечаются признаком outside.
 */
function monthGrid(year, month) {
  const first = new Date(year, month - 1, 1, 12);
  const last = new Date(year, month, 0, 12);

  const gridStart = addDays(dayKey(first), -(isoWeekday(first) - 1));
  const gridEnd = addDays(dayKey(last), 7 - isoWeekday(last));

  const weeks = [];
  let week = [];

  for (const key of daysBetween(gridStart, gridEnd)) {
    week.push({ key, outside: dayDate(key).getMonth() !== month - 1 });
    if (week.length === 7) {
      weeks.push(week);
      week = [];
    }
  }

  return { weeks, gridStart, gridEnd };
}

module.exports = {
  STATUS,
  STATUS_TITLE,
  dayKey,
  dayDate,
  addDays,
  daysBetween,
  isNonWorking,
  orderDeadline,
  restDays,
  restState,
  expectedDuties,
  orderBlock,
  postShifts,
  shiftsByDate,
  isShiftPost,
  rotationTurn,
  conflictingDates,
  findSlotConflicts,
  findRestConflicts,
  isPast,
  dutyStatus,
  isUrgent,
  monthGrid,
};
