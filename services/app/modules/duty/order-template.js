'use strict';

// Шаблон приказа вида наряда и раскладка приказа по нему.
//
// Шаблон — параметры листа и блоки по порядку. Блок либо ПИШЕТСЯ шаблоном
// (текст с подстановками — пункт о контроле, преамбула, подпись), либо
// ЗАПОЛНЯЕТСЯ системой (состав наряда, оружие). Что автоматизировать, а что
// писать, решает набор блоков; оформление — у каждого блока свое.
//
// Модуль чистый: без базы и шаблонизатора. Печать и предпросмотр получают
// из layout() готовые абзацы и таблицы.

const v = require('../../lib/validation');

const KINDS = {
  text: 'Текст',
  roster: 'Состав наряда (заполняет система)',
  weapons: 'Оружие (заполняет система)',
  signature: 'Подпись',
};

const ALIGNS = { justify: 'по ширине', left: 'влево', center: 'по центру', right: 'вправо' };
// Состав в приказе — текстом, по строке на пост, без таблицы и нумерации.
// Прежнее значение «таблицей» в сохраненных шаблонах читается как текст.
const FORMATS = { list: 'текстом' };

/** Подстановки в тексте блоков — перечень для подсказки на странице шаблона. */
const PLACEHOLDERS = {
  '{{часть}}': 'наименование части (верхнее подразделение)',
  '{{дата_приказа}}': 'дата приказа словами: 12 октября 2026 г.',
  '{{вид_наряда}}': 'наименование вида наряда',
  '{{код}}': 'обозначение вида наряда',
  '{{период}}': 'период всего приказа: с 18.00 12.10.2026 по 18.00 13.10.2026',
  '{{всего}}': 'всего назначено человек',
  '{{командир}}': 'командир части (на время отсутствия — ВРИО): И.О. Фамилия',
  '{{командир_звание}}': 'воинское звание подписывающего за командира',
  '{{командир_должность}}': 'должность: «Командир части» или «Врио командира части»',
  '{{начальник_штаба}}': 'начальник штаба (на время отсутствия — ВРИО): И.О. Фамилия',
  '{{начальник_штаба_звание}}': 'воинское звание подписывающего за начальника штаба',
  '{{начальник_штаба_должность}}': 'должность: «Начальник штаба» или «Врио начальника штаба»',
  '{{с}}': 'в блоке состава — начало суток раздела',
  '{{по}}': 'в блоке состава — окончание суток раздела',
};

// Нормы оформления распорядительных документов: Times New Roman 14,
// одинарный интервал, поля 20/20/30/15 мм (левое — под подшивку), абзацный
// отступ 1,25 см.
const DEFAULT_PAGE = {
  marginTop: 20, marginBottom: 20, marginLeft: 30, marginRight: 15,
  fontSize: 14, lineHeight: 1,
};

const BLOCK_DEFAULTS = {
  kind: 'text', text: '', right: '', align: 'justify', indent: 1.25,
  bold: false, numbered: false, spaceBefore: 0, format: 'list', posts: [],
};

const DEFAULT_BLOCKS = [
  { text: 'ПРИКАЗ', align: 'center', indent: 0, bold: true },
  { text: '{{часть}}', align: 'center', indent: 0 },
  { text: '№ ______                                        {{дата_приказа}}', align: 'center', indent: 0, spaceBefore: 6 },
  { text: 'О назначении наряда «{{вид_наряда}}»', align: 'center', indent: 0, bold: true, spaceBefore: 12 },
  { text: 'Для несения службы в наряде «{{вид_наряда}}» {{период}}', spaceBefore: 12 },
  { text: 'ПРИКАЗЫВАЮ:', align: 'left', indent: 0, bold: true, spaceBefore: 6 },
  { kind: 'roster', text: 'Назначить в наряд с {{с}} по {{по}} следующий личный состав:', numbered: true },
  { kind: 'weapons', text: 'Личному составу наряда получить личное оружие.', numbered: true },
  { text: 'Контроль за исполнением приказа оставляю за собой.', numbered: true },
  { kind: 'signature', text: '{{командир_должность}}\n{{командир_звание}}', right: '{{командир}}',
    align: 'left', indent: 0, spaceBefore: 24 },
  // Вторая подпись — начальник штаба, под командиром.
  { kind: 'signature', text: '{{начальник_штаба_должность}}\n{{начальник_штаба_звание}}', right: '{{начальник_штаба}}',
    align: 'left', indent: 0, spaceBefore: 18 },
];

const DEFAULT_TEMPLATE = {
  page: DEFAULT_PAGE,
  blocks: DEFAULT_BLOCKS.map((b) => ({ ...BLOCK_DEFAULTS, ...b })),
};

const number = (value, min, max, label) => {
  const n = Number(String(value ?? '').replace(',', '.'));
  if (!Number.isFinite(n) || n < min || n > max) v.fail(`${label}: число от ${min} до ${max}.`);
  return n;
};

/** Проверенный шаблон: неизвестное отклоняется, пропущенное — по умолчанию. */
function normalize(input) {
  const src = input || {};
  const page = { ...DEFAULT_PAGE, ...(src.page || {}) };
  const checkedPage = {
    marginTop: number(page.marginTop, 0, 60, 'Верхнее поле, мм'),
    marginBottom: number(page.marginBottom, 0, 60, 'Нижнее поле, мм'),
    marginLeft: number(page.marginLeft, 0, 60, 'Левое поле, мм'),
    marginRight: number(page.marginRight, 0, 60, 'Правое поле, мм'),
    fontSize: number(page.fontSize, 8, 20, 'Кегль, пт'),
    lineHeight: number(page.lineHeight, 0.8, 3, 'Межстрочный интервал'),
  };

  const blocks = (src.blocks || []).map((raw, i) => {
    const b = { ...BLOCK_DEFAULTS, ...raw };
    const where = `Блок ${i + 1}`;
    if (!KINDS[b.kind]) v.fail(`${where}: неизвестный вид блока.`);
    if (!ALIGNS[b.align]) v.fail(`${where}: неизвестное выравнивание.`);
    const posts = [...new Set((Array.isArray(b.posts) ? b.posts
      : String(b.posts || '').split(',')).map((x) => String(x).trim()).filter(Boolean).map((x) => v.id(x)))];
    const text = String(b.text || '');
    const right = String(b.right || '');
    if (text.length > 2000 || right.length > 300) v.fail(`${where}: слишком длинный текст.`);
    if (b.kind === 'text' && !text.trim()) v.fail(`${where}: текстовый блок пуст.`);
    return {
      kind: b.kind, text, right, align: b.align, format: 'list',
      posts: b.kind === 'roster' ? posts : [],
      indent: number(b.indent, 0, 5, `${where}, отступ`),
      spaceBefore: number(b.spaceBefore, 0, 72, `${where}, интервал перед`),
      bold: b.bold === true || b.bold === 'yes',
      numbered: b.numbered === true || b.numbered === 'yes',
    };
  });

  if (blocks.length === 0) v.fail('В шаблоне нет ни одного блока.');
  if (blocks.length > 60) v.fail('Слишком много блоков.');
  const rosters = blocks.filter((b) => b.kind === 'roster');
  if (rosters.length === 0) v.fail('В шаблоне нет блока состава наряда.');
  // Посты делятся между блоками состава: пост — только в одном блоке;
  // блок без выбранных постов берет все остальные, и такой блок — один.
  const seen = new Set();
  for (const b of rosters) for (const id of b.posts) {
    if (seen.has(id)) v.fail('Пост выбран в двух блоках состава: у каждого поста — один блок.');
    seen.add(id);
  }
  if (rosters.filter((b) => b.posts.length === 0).length > 1) {
    v.fail('Блок «остальные посты» (без выбранных постов) может быть только один.');
  }
  return { page: checkedPage, blocks };
}

/** Шаблон из формы: поля блоков приходят массивами в порядке строк. */
function fromForm(body) {
  const list = (key) => {
    const value = body[key];
    if (value === undefined) return [];
    return Array.isArray(value) ? value : [value];
  };
  const kinds = list('blockKind');
  const field = (key, i) => list(key)[i];
  return normalize({
    page: {
      marginTop: body.marginTop, marginBottom: body.marginBottom,
      marginLeft: body.marginLeft, marginRight: body.marginRight,
      fontSize: body.fontSize, lineHeight: body.lineHeight,
    },
    blocks: kinds.map((kind, i) => ({
      kind,
      text: field('blockText', i),
      right: field('blockRight', i),
      align: field('blockAlign', i),
      indent: field('blockIndent', i),
      spaceBefore: field('blockSpace', i),
      bold: field('blockBold', i),
      numbered: field('blockNumbered', i),
      format: field('blockFormat', i),
      posts: field('blockPosts', i),
    })),
  });
}

// ----------------------------------------------------------------------------
// Раскладка приказа
// ----------------------------------------------------------------------------

const MONTHS = ['января', 'февраля', 'марта', 'апреля', 'мая', 'июня', 'июля',
  'августа', 'сентября', 'октября', 'ноября', 'декабря'];
const pad = (n) => String(n).padStart(2, '0');
const asDate = (value) => (value instanceof Date ? value : new Date(value));

/** 18.00 12.10.2026 — время и дата, как пишут в приказах. */
function stamp(value) {
  const d = asDate(value);
  return `${pad(d.getHours())}.${pad(d.getMinutes())} ${pad(d.getDate())}.${pad(d.getMonth() + 1)}.${d.getFullYear()}`;
}

/** 12 октября 2026 г. */
function longDate(value) {
  const [y, m, d] = String(value).slice(0, 10).split('-').map(Number);
  return `${d} ${MONTHS[m - 1]} ${y} г.`;
}

function fill(text, values) {
  return String(text || '').replace(/\{\{([^}]+)\}\}/g, (all, key) => (
    Object.hasOwn(values, key) ? values[key] : all));
}

/** И.О. Фамилия — для подписи. */
function signName(person) {
  if (!person || !person.last_name) return '';
  const initials = [person.first_name, person.middle_name].filter(Boolean)
    .map((x) => `${x.trim()[0].toUpperCase()}.`).join('');
  return `${initials} ${person.last_name}`.trim();
}

/**
 * Группы одного раздела (суток) приказа: постоянный состав; посты,
 * несущие службу в свои часы (ПУД); выходы посменных постов по суткам.
 */
function sectionGroups(section, head) {
  const permanent = section.roster.filter((r) => !r.onDate);
  const core = permanent.filter((r) => !r.post.start_time);
  const groups = [{ head, items: core }];

  const timed = new Map();
  for (const item of permanent.filter((r) => r.post.start_time)) {
    const start = item.post.start_time.slice(0, 5);
    const end = `${pad((Number(start.slice(0, 2)) + item.post.duration_hours) % 24)}:${start.slice(3, 5)}`;
    const key = `${start}–${end}`;
    if (!timed.has(key)) timed.set(key, []);
    timed.get(key).push(item);
  }
  for (const [hours, items] of timed) {
    groups.push({ head: `На весь период дежурства ежедневно с ${hours} назначить:`, items });
  }

  const byDate = new Map();
  for (const item of section.roster.filter((r) => r.onDate)) {
    if (!byDate.has(item.onDate)) byDate.set(item.onDate, []);
    byDate.get(item.onDate).push(item);
  }
  for (const date of [...byDate.keys()].sort()) {
    const [y, m, d] = date.split('-');
    groups.push({ head: `На сутки ${d}.${m}.${y} назначить:`, items: byDate.get(date) });
  }
  return groups.filter((g) => g.items.length > 0 || g === groups[0]);
}

/** Строка списка: «Дежурный по части — капитан Иванов Иван Иванович». */
function listLine(item) {
  const e = item.employee;
  const who = e ? [e.rank_name, e.full_name].filter(Boolean).join(' ') : '________________';
  return `${item.post.name} — ${who}`;
}

/**
 * Приказ по шаблону: абзацы и таблицы в порядке блоков, со сквозной
 * нумерацией пунктов.
 *
 * @param {object} template  проверенный шаблон (normalize)
 * @param {object} order     сохраненная форма приказа: dutyType, sections,
 *                           orderDate, totalAssigned, context {unit, commander}
 * @returns {{page, items:Array}}  item: {type:'p'|'table'|'sign', ...}
 */
function layout(template, order) {
  const sections = order.sections || [];
  const context = order.context || {};
  const first = sections[0];
  const last = sections[sections.length - 1];

  const values = {
    часть: context.unit || '',
    дата_приказа: order.orderDate ? longDate(order.orderDate) : '',
    вид_наряда: order.dutyType ? order.dutyType.name : '',
    код: order.dutyType ? order.dutyType.code : '',
    период: first ? `с ${stamp(first.duty.starts_at)} по ${stamp(last.duty.ends_at)}` : '',
    всего: String(order.totalAssigned ?? ''),
    командир: signName(context.commander),
    командир_звание: context.commander ? context.commander.rank_name || '' : '',
    командир_должность: context.commander ? context.commander.title || 'Командир' : '',
    начальник_штаба: signName(context.chief),
    начальник_штаба_звание: context.chief ? context.chief.rank_name || '' : '',
    начальник_штаба_должность: context.chief ? context.chief.title || 'Начальник штаба' : '',
  };

  const items = [];
  let point = 0;
  // Посты, отданные блокам состава с выбранными постами.
  const claimed = new Set(template.blocks.filter((b) => b.kind === 'roster').flatMap((b) => b.posts));
  // Незамещенные места — одним предупреждением на экране, не в документе.
  sections.forEach((section) => {
    if (section.roster.length < section.postCount) {
      items.push({ type: 'warn', text: `Внимание: не замещено постов — ${section.postCount - section.roster.length}.` });
    }
  });
  const style = (b) => ({ align: b.align, indent: b.indent, bold: b.bold, spaceBefore: b.spaceBefore });
  const paragraphs = (b, text, numberText, extra = {}) => {
    String(text).split('\n').forEach((line, i) => {
      items.push({ type: 'p', text: line, number: i === 0 ? numberText : null, ...style(b), ...extra,
        spaceBefore: i === 0 ? b.spaceBefore : 0 });
    });
  };

  for (const b of template.blocks) {
    if (b.kind === 'text') {
      paragraphs(b, fill(b.text, values), b.numbered ? `${++point}.` : null);
    } else if (b.kind === 'signature') {
      items.push({ type: 'sign', left: fill(b.text, values), right: fill(b.right, values), ...style(b) });
    } else if (b.kind === 'roster') {
      // Свои посты блока; блок без выбранных — все, не попавшие в другие.
      const own = b.posts.length > 0 ? new Set(b.posts) : null;
      const mine = (r) => (own ? own.has(r.post.id) : !claimed.has(r.post.id));
      const parts = sections
        .map((section) => ({ section, roster: section.roster.filter(mine) }))
        .filter((part) => part.roster.length > 0);
      if (parts.length === 0) continue;

      const main = b.numbered ? ++point : null;
      parts.forEach(({ section, roster }, si) => {
        const head = fill(b.text, { ...values, с: stamp(section.duty.starts_at), по: stamp(section.duty.ends_at) });
        const sub = main === null ? null : (parts.length > 1 ? `${main}.${si + 1}.` : `${main}.`);
        sectionGroups({ ...section, roster }, head).forEach((group, gi) => {
          paragraphs(b, group.head, gi === 0 ? sub : null, gi === 0 ? {} : { spaceBefore: 0 });
          // Текстом, по строке на пост; последняя — с точкой.
          group.items.forEach((item, ii) => items.push({
            type: 'p', text: `${listLine(item)}${ii === group.items.length - 1 ? '.' : ';'}`,
            number: null, ...style(b), spaceBefore: 0,
          }));
        });
      });
    } else if (b.kind === 'weapons') {
      const armed = sections.flatMap((s) => s.roster).filter((r) => r.weapon);
      if (armed.length === 0) continue;
      paragraphs(b, fill(b.text, values), b.numbered ? `${++point}.` : null);
      // Приказ на несколько суток (выходные, праздники): закрепления идут по
      // суткам — иначе непонятно, на какую смену закреплено оружие.
      sections.forEach((section) => {
        const loans = section.roster.filter((r) => r.weapon && r.weapon.orderLine);
        if (loans.length === 0) return;
        if (sections.length > 1) {
          items.push({ type: 'p', text: `С ${stamp(section.duty.starts_at)} по ${stamp(section.duty.ends_at)}:`,
            number: null, ...style(b), spaceBefore: 0 });
        }
        loans.forEach((r) => items.push({
          type: 'p', text: r.weapon.orderLine, number: null, ...style(b), spaceBefore: 0,
        }));
      });
    }
  }

  return { page: template.page, items };
}

module.exports = {
  KINDS, ALIGNS, FORMATS, PLACEHOLDERS, DEFAULT_TEMPLATE, normalize, fromForm, layout, longDate, stamp,
};
