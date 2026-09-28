'use strict';

// Расчет суток и выходов — чистые функции, без БД.

const cal = require('../../services/app/modules/duty/calendar');

// Смена ОО: вторник 17:30 — пятница 17:30.
const TUESDAY_SHIFT = {
  startsAt: new Date('2026-10-06T17:30:00'),
  endsAt: new Date('2026-10-09T17:30:00'),
};

const PTSO1 = { per_day: true, start_time: '08:00:00', duration_hours: 12, recovery_sleep_days: 1 };
const PTSO2 = { per_day: true, start_time: '20:00:00', duration_hours: 12, recovery_sleep_days: 1 };
// ПУД заступает со всей сменой: часы у него свои, но посуточно он не меняется.
const PUD = { per_day: false, start_time: '08:00:00', duration_hours: 10, recovery_sleep_days: 0 };

/** Выход принадлежит смене, несущей службу в час его заступления. */
exports.выходы_по_моменту_заступления = async (t) => {
  const night = cal.postShifts(TUESDAY_SHIFT, PTSO2).map((s) => s.date);
  const day = cal.postShifts(TUESDAY_SHIFT, PTSO1).map((s) => s.date);

  // Ночной ПТСО заступает в 20:00 — вторник уже внутри смены, пятница нет.
  t.is(night, ['2026-10-06', '2026-10-07', '2026-10-08'], 'ночные выходы ПТСО 2');
  // Дневной заступает в 08:00 — вторник еще до смены, пятница до сдачи.
  t.is(day, ['2026-10-07', '2026-10-08', '2026-10-09'], 'дневные выходы ПТСО 1');
};

/** Ни один выход не теряется и не попадает в два приказа сразу. */
exports.выходы_не_дублируются_между_сменами = async (t) => {
  const friday = {
    startsAt: new Date('2026-10-09T17:30:00'),
    endsAt: new Date('2026-10-13T17:30:00'),
  };

  const inTuesday = cal.postShifts(TUESDAY_SHIFT, PTSO1).map((s) => s.date);
  const inFriday = cal.postShifts(friday, PTSO1).map((s) => s.date);

  t.ok(!inTuesday.some((d) => inFriday.includes(d)), 'сутки не повторяются в двух приказах');
  t.is(inFriday[0], '2026-10-10', 'пятничный дневной выход остался за вторничной сменой');
};

/** Группировка выходов по суткам: сколько мест замещается каждый день. */
exports.выходы_по_суткам = async (t) => {
  const byDate = cal.shiftsByDate(TUESDAY_SHIFT, [PTSO1, PTSO2, PUD, PUD]);
  const counts = [...byDate].map(([date, items]) => [date, items.length]);

  // Посуточно меняются только ПТСО; ПУД замещается один раз на всю смену.
  t.is(counts, [
    ['2026-10-06', 1], // только ночной ПТСО 2
    ['2026-10-07', 2],
    ['2026-10-08', 2],
    ['2026-10-09', 1], // ночной уже за следующей сменой
  ], 'места по суткам вторничного приказа');
};

/** Пост без своего графика замещается на весь наряд и выходов не имеет. */
exports.пост_без_графика_выходов_не_имеет = async (t) => {
  t.is(cal.postShifts(TUESDAY_SHIFT, { start_time: null, duration_hours: null }), [],
    'постоянный состав выходов не образует');
  t.ok(!cal.isShiftPost({ start_time: null, duration_hours: null }), 'признак посменного поста');
  t.ok(cal.isShiftPost(PTSO2), 'ПТСО 2 — посменный');
  // Часы поста сами по себе посуточного замещения не означают.
  t.ok(!cal.isShiftPost(PUD), 'ПУД заступает на всю смену');
  t.is(cal.postShifts(TUESDAY_SHIFT, PUD), [], 'у ПУД выходов нет');
};

/** Пересечения и отдых между местами наряда. */
exports.пересечения_мест = async (t) => {
  const slot = (id, from, to, sleepDays = 0) => ({
    employeeId: id, startsAt: new Date(from), endsAt: new Date(to),
    sleepDays, excludeWeekends: false, label: from,
  });

  // ПУД 08:00–18:00 и ПТСО 1 08:00–20:00 в одни сутки — пересечение.
  const overlap = cal.findSlotConflicts([
    slot(1, '2026-10-07T08:00:00', '2026-10-07T18:00:00'),
    slot(1, '2026-10-07T08:00:00', '2026-10-07T20:00:00'),
  ], new Map());
  t.is(overlap.length, 1, 'одновременные места запрещены');
  t.is(overlap[0].reason, 'overlap', 'причина — пересечение');

  // Ночной ПТСО 2 и дневной выход назавтра: отсыпной занимает сутки сдачи.
  const rest = cal.findSlotConflicts([
    slot(2, '2026-10-07T20:00:00', '2026-10-08T08:00:00', 1),
    slot(2, '2026-10-08T08:00:00', '2026-10-08T18:00:00'),
  ], new Map());
  t.is(rest.length, 1, 'после ночного выхода сутки заняты отсыпным');
  t.is(rest[0].reason, 'rest', 'причина — отдых');

  // Дневной ПУД два дня подряд: отдых не положен, запрета нет.
  const allowed = cal.findSlotConflicts([
    slot(3, '2026-10-07T08:00:00', '2026-10-07T18:00:00'),
    slot(3, '2026-10-08T08:00:00', '2026-10-08T18:00:00'),
  ], new Map());
  t.is(allowed.length, 0, 'дневные выходы подряд разрешены');
};

/** ПТСО 1 и ПТСО 2 подряд одному человеку запрещены в обе стороны. */
exports.птсо_подряд_запрещен = async (t) => {
  const at = (date, post) => {
    const startsAt = new Date(`${date}T${post.start_time}`);
    return {
      employeeId: 1, startsAt,
      endsAt: new Date(startsAt.getTime() + post.duration_hours * 3600000),
      sleepDays: post.recovery_sleep_days, excludeWeekends: false,
      label: `${post.start_time} ${date}`,
    };
  };

  // Днем ПТСО 1, вечером того же дня ПТСО 2 — сутки подряд без перерыва.
  t.is(cal.findSlotConflicts([at('2026-10-07', PTSO1), at('2026-10-07', PTSO2)], new Map()).length,
    1, 'ПТСО 1 → ПТСО 2 в те же сутки запрещен');

  // Ночью ПТСО 2, утром следующего дня ПТСО 1 — то же самое наоборот.
  t.is(cal.findSlotConflicts([at('2026-10-07', PTSO2), at('2026-10-08', PTSO1)], new Map()).length,
    1, 'ПТСО 2 → ПТСО 1 наутро запрещен');

  // ПТСО 1 два дня подряд правилами не запрещен: отдых кончается в те же сутки.
  t.is(cal.findSlotConflicts([at('2026-10-07', PTSO1), at('2026-10-08', PTSO1)], new Map()).length,
    0, 'ПТСО 1 два дня подряд разрешен');
};
