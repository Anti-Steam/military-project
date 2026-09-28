'use strict';

// График нарядов: сутки многосуточной смены показываются отдельно.

const duty = require('../../services/app/modules/duty/service');
const queries = require('../../services/app/modules/duty/queries');
const cal = require('../../services/app/modules/duty/calendar');

// Месяц впереди: проверяется живой расчет, а не пустая сетка.
const next = (() => {
  const d = new Date();
  return { year: new Date(d.getFullYear(), d.getMonth() + 1, 1).getFullYear(),
           month: new Date(d.getFullYear(), d.getMonth() + 1, 1).getMonth() + 1 };
})();

async function ooType() {
  return (await duty.listDutyTypes()).find((t) => t.code === 'OO');
}

/** У каждых суток смены свое заполнение, а не одна ячейка на трое суток. */
exports.сутки_смены_показаны_отдельно = async (t) => {
  const type = await ooType();
  t.ok(Boolean(type), 'вид наряда ОО заведен');

  const posts = await queries.listPosts(type.id);
  const permanent = posts.filter((p) => !cal.isShiftPost(p));
  const shiftPosts = posts.filter(cal.isShiftPost);

  // Посуточно меняются только ПТСО. ПУД заступает со всей сменой, хотя
  // часы у него свои, — он в постоянном составе.
  t.is(shiftPosts.map((p) => p.short_name).sort(), ['ПТСО 1', 'ПТСО 2'],
    'посуточно замещаются только ПТСО');
  t.ok(permanent.some((p) => p.short_name === 'ПУД 1' && p.start_time),
    'ПУД со своими часами входит в постоянный состав');

  const schedule = await duty.getMonthSchedule(type.id, next.year, next.month, null);
  const cells = schedule.grid.flat().filter((d) => d.cell && !d.outside);

  t.ok(cells.length > 8, 'смена занимает больше суток, чем число заступлений');

  // Сутки заступления: постоянный состав плюс выходы, попадающие в эти сутки.
  const starts = cells.filter((d) => d.cell.isStart);
  t.ok(starts.length >= 4, 'в месяце не меньше четырех заступлений ОО');
  t.ok(starts.every((d) => d.cell.postCount > permanent.length),
    'в сутки заступления мест больше, чем постоянных постов');

  // Промежуточные сутки: только выходы посменных постов.
  const middle = cells.filter((d) => !d.cell.isStart && !d.cell.continuation);
  t.ok(middle.length > 0, 'промежуточные сутки замещаются');
  t.ok(middle.every((d) => d.cell.postCount === shiftPosts.length || d.cell.others.length > 0),
    'в промежуточные сутки замещаются только посты ПТСО');
};

/** Дневные посты последних суток принадлежат сдающей смене. */
exports.сутки_смены_соединяют_два_приказа = async (t) => {
  const type = await ooType();
  const schedule = await duty.getMonthSchedule(type.id, next.year, next.month, null);
  const cells = schedule.grid.flat().filter((d) => d.cell && !d.outside);

  const shared = cells.filter((d) => d.cell.others.length > 0);
  t.ok(shared.length > 0, 'есть сутки, где сходятся два приказа');

  for (const day of shared) {
    t.ok(day.cell.others.every((o) => o.startDate < day.key),
      'чужие места принадлежат ранее заступившей смене');
    t.ok(day.cell.isStart, 'такие сутки — день заступления следующей смены');
  }
};

/** Суточные наряды прежнего вида ничего не потеряли. */
exports.суточные_наряды_не_изменились = async (t) => {
  const types = await duty.listDutyTypes();

  for (const type of types.filter((x) => x.kind !== 'multiday')) {
    const posts = await queries.listPosts(type.id);
    t.ok(posts.every((p) => !cal.isShiftPost(p)),
      `у вида ${type.code} нет посменных постов`);

    const schedule = await duty.getMonthSchedule(type.id, next.year, next.month, null);
    const cells = schedule.grid.flat().filter((d) => d.cell && !d.outside);

    t.ok(cells.every((d) => d.cell.isStart), `${type.code}: каждые сутки — свой наряд`);
    t.ok(cells.every((d) => d.cell.postCount === posts.length),
      `${type.code}: число мест равно числу постов`);
  }
};
