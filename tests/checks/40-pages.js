'use strict';

// Страницы отвечают и содержат то, что должны. Проверки идут по работающему
// приложению; если оно не запущено, они пропускаются с пометкой.

const { get, post } = require('../lib');
const duty = require('../../services/app/modules/duty/service');

async function ooDate() {
  const type = (await duty.listDutyTypes()).find((t) => t.code === 'OO');
  const now = new Date();
  const month = new Date(now.getFullYear(), now.getMonth() + 1, 1);
  const schedule = await duty.getMonthSchedule(type.id, month.getFullYear(), month.getMonth() + 1, null);
  const start = schedule.grid.flat().find((d) => d.cell && d.cell.isStart && !d.outside);
  return { type, date: start.cell.startDate };
}

/** Основные страницы открываются. */
exports.страницы_отвечают = async (t, ctx) => {
  if (!ctx.alive) { t.ok(true, 'приложение не запущено — пропущено'); return; }

  const types = await duty.listDutyTypes();
  const paths = ['/', '/personnel', '/personnel/roster', '/duty-types', '/weapons', '/calendar?year=2026'];
  for (const type of types) paths.push(`/duties?type=${type.id}`);

  for (const path of paths) {
    const { status } = await get(path);
    t.is(status, 200, `страница ${path}`);
  }
};

/** Назначение на смену показывает и постоянный состав, и сутки выходов. */
exports.страница_назначения_показывает_выходы = async (t, ctx) => {
  if (!ctx.alive) { t.ok(true, 'приложение не запущено — пропущено'); return; }

  const { type, date } = await ooDate();
  const { status, body } = await get(`/duties/plan?type=${type.id}&date=${date}`);

  t.is(status, 200, 'страница назначения открылась');
  t.ok(body.includes('Посты на сутки'), 'есть разделы по суткам выходов');
  t.ok(/id="shift-\d{4}-\d{2}-\d{2}"/.test(body), 'разделы выходов имеют якоря');

  // Каждое место — свой список; постов в блоке больше, чем постоянных.
  const selects = (body.match(/<select\b[^>]*\bname="post_/g) || []).length;
  t.ok(selects >= 12, `мест в блоке: ${selects}`);
  let depth = 0;
  for (const tag of body.match(/<\/?form\b[^>]*>/g) || []) {
    if (tag.startsWith('</')) depth -= 1;
    else { depth += 1; t.is(depth, 1, 'формы не вложены друг в друга'); }
  }
  t.is(depth, 0, 'все формы закрыты');
  t.ok(/<select\b[^>]*form="roster-form"[^>]*name="post_/.test(body),
    'поля состава связаны с формой сохранения');
};

/** График ведет на нужный раздел и показывает чужие места суток. */
exports.график_ведет_к_суткам = async (t, ctx) => {
  if (!ctx.alive) { t.ok(true, 'приложение не запущено — пропущено'); return; }

  const { type } = await ooDate();
  const { status, body } = await get(`/duties?type=${type.id}`);

  t.is(status, 200, 'график открылся');
  t.ok(body.includes('#shift-'), 'сутки смены ведут к своему разделу');
  t.ok(body.includes('смена продолжается'), 'продолжение смены отмечено');
};

/** Сохранение состава возвращает в график того же месяца и вида наряда. */
exports.сохранение_возвращает_в_график = async (t, ctx) => {
  if (!ctx.alive) { t.ok(true, 'приложение не запущено — пропущено'); return; }

  const { type, date } = await ooDate();

  // Форма без единого поля состава ничего не меняет: проверяется только,
  // куда уходит страница после сохранения.
  const { status, location } = await post('/duties/plan', {
    dutyTypeId: type.id, unitId: 1, date,
  });

  t.is(status, 302, 'сохранение перенаправляет');
  t.ok(String(location).includes('/duties?'), 'возврат именно в график');
  t.ok(String(location).includes(`type=${type.id}`), 'вкладка того же вида наряда');
  t.ok(String(location).includes(`month=${date.slice(0, 7)}`), 'месяц тех же суток');
};

/** Оглавление считает те же места, что и разделы под ним. */
exports.оглавление_совпадает_с_разделами = async (t, ctx) => {
  if (!ctx.alive) { t.ok(true, 'приложение не запущено — пропущено'); return; }

  const { type, date } = await ooDate();
  const { body } = await get(`/duties/plan?type=${type.id}&date=${date}`);

  // Разделы страницы и вкладки оглавления должны быть одни и те же.
  const sections = [...body.matchAll(/<section [^>]*data-section="([^"]+)"/g)].map((m) => m[1]);
  const tabs = [...body.matchAll(/<a [^>]*data-tab="([^"]+)"/g)].map((m) => m[1]);

  t.ok(sections.length > 1, `разделов на странице: ${sections.length}`);
  t.is(tabs, sections, 'каждому разделу отвечает своя вкладка');

  // У каждого раздела и у каждой вкладки есть живой счетчик, и на момент
  // отрисовки он равен числу занятых мест этого раздела.
  // У суток счетчик — в их заголовке-сворачивателе, прямо перед разделом.
  const starts = [...body.matchAll(/<section [^>]*data-section="([^"]+)"/g)];
  for (let i = 0; i < starts.length; i += 1) {
    const key = starts[i][1];
    const chunk = body.slice(starts[i].index, i + 1 < starts.length ? starts[i + 1].index : body.length);
    const selected = (chunk.match(/<option [^>]*selected/g) || []).length;
    const before = body.slice(0, starts[i].index);
    const shown = key.startsWith('day-')
      ? [...before.matchAll(/data-filled-summary>(\d+)</g)].pop()
      : chunk.match(/data-filled[^>]*>(\d+)</);

    t.ok(Boolean(shown), `${key}: в разделе есть счетчик`);
    if (shown) t.is(Number(shown[1]), selected, `${key}: счетчик равен числу занятых мест`);
  }
};

/**
 * Сутки продолжающейся смены не выглядят пустыми.
 *
 * В них никто не сменяется и замещать нечего, но смена несет службу: в
 * ячейке стоит ее состояние и переход к ней. Иначе прошедшие сутки
 * многосуточного наряда читаются как пробел в графике.
 */
exports.продолжение_смены_не_пустое = async (t, ctx) => {
  if (!ctx.alive) { t.ok(true, 'приложение не запущено — пропущено'); return; }

  const type = (await duty.listDutyTypes()).find((x) => x.code === 'OO');
  const now = new Date();

  // Ищем месяц, где у смены есть сутки продолжения без собственных мест.
  for (let back = 0; back <= 2; back += 1) {
    const month = new Date(now.getFullYear(), now.getMonth() - back, 1);
    const [year, index] = [month.getFullYear(), month.getMonth() + 1];

    const schedule = await duty.getMonthSchedule(type.id, year, index, null, null);
    const cont = schedule.grid.flat().find((d) => d.cell && !d.outside && d.cell.continuation);
    if (!cont) continue;

    const { body } = await get(`/duties?type=${type.id}&month=${year}-${String(index).padStart(2, '0')}`);
    const cell = body.slice(body.indexOf(`cal-num">${cont.cell.anchorDate.slice(8).replace(/^0/, '')}<`));

    t.ok(cell.includes('cal-cont'), 'сутки продолжения смены отрисованы');
    t.ok(/href="\/duties\//.test(cell.slice(0, 600)), 'из них есть переход к смене');
    t.ok(cell.slice(0, 600).includes('cal-status'), 'и показано состояние смены');
    return;
  }

  // На стенде таких суток может не быть — они появляются у смен, заведенных
  // без посуточных постов. Тогда проверяется сама разметка: ячейка
  // продолжения обязана вести к смене, а не быть глухой надписью.
  const view = require('node:fs').readFileSync(
    require('node:path').join(__dirname, '../../services/app/views/duty-calendar.ejs'), 'utf8',
  );
  const block = view.slice(view.indexOf('c.continuation'), view.indexOf('c.continuation') + 900);
  t.ok(block.includes('cal-status'), 'в разметке у суток продолжения есть состояние смены');
  t.ok(block.includes('href='), 'и переход к ней');
};

/**
 * Страницы отдаются сжатыми, а длинные повторяющиеся перечни (подразделения
 * в каждой форме) приходят один раз на страницу и подставляются в список
 * при первом нажатии.
 */
exports.облегченные_страницы = async (t, ctx) => {
  if (!ctx.alive) { t.ok(true, 'приложение не запущено — пропущено'); return; }
  const { get } = require('../lib');

  const units = await get('/units');
  t.is(units.status, 200, 'подразделения открываются');
  t.is(units.encoding, 'gzip', 'страница отдается сжатой');
  t.ok(units.body.includes('window.OPTION_LISTS'), 'перечень подразделений — один на страницу');
  t.ok(/<select name="parentId" data-options="units" data-exclude="\d+">\s*<option value="\d+" selected>/
    .test(units.body), '«Входит в» приходит только с выбранным вариантом');
  t.ok(units.body.includes('/js/lazy-select.js'), 'сценарий подстановки подключен');

  const script = await get('/js/lazy-select.js');
  t.is(script.status, 200, 'сценарий подстановки отдается');

  const small = await get('/login');
  t.ok(small.status === 200 || small.status === 302, 'короткая страница отвечает');
};
