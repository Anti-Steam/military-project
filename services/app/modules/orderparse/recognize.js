'use strict';

// Узнавание смысловых кусочков в тексте приказа — где бы и как бы они ни
// были написаны:
//   люди      — по всем падежам фамилии и инициалам/имени рядом с ней
//               («рядового Иванова И.И.», «И.И. Иванов», «Иванову Ивану»);
//   значения  — виды допуска и причины отсутствия: по названию в любом
//               падеже («дежурным по части») и по словарю (сокращения);
//   даты и периоды — «с 12.10.2026 по 30.10.2026», «12 октября 2026 г.»,
//               «на 10 суток с …», «до …»;
//   отметки   — «допущен», «+» в ячейках таблиц.
// Модуль чистый: словари и личный состав передаются снаружи.

const declension = require('../../lib/declension');

const norm = (s) => String(s || '').toLowerCase().replace(/ё/g, 'е').replace(/\s+/g, ' ').trim();

// Окончания для сравнения слов по основе: «дежурным» = «дежурного» =
// «дежурный», «части» = «часть», «помощником» = «помощник».
const ENDINGS = ['ами', 'ями', 'ого', 'его', 'ому', 'ему', 'ыми', 'ими', 'ый', 'ий', 'ой', 'ая', 'яя', 'ое',
  'ее', 'ые', 'ие', 'ую', 'юю', 'ым', 'им', 'ом', 'ем', 'ах', 'ях', 'ов', 'ев', 'ам', 'ям', 'ы', 'и', 'а',
  'я', 'о', 'е', 'у', 'ю', 'ь', 'й'];
function stem(word) {
  const w = norm(word);
  for (const end of ENDINGS) {
    if (w.length - end.length >= 3 && w.endsWith(end)) return w.slice(0, -end.length);
  }
  return w;
}

/** Слова текста с позициями (для «рядом»): буквенные слова и инициалы «И.». */
function words(text) {
  const out = [];
  const re = /[A-Za-zА-Яа-яЁё]+(?:-[A-Za-zА-Яа-яЁё]+)*\.?|[+✓]/g;
  let m;
  while ((m = re.exec(text))) {
    const raw = m[0];
    out.push({ raw, word: raw.replace(/\.$/, ''), at: m.index, initial: /^[А-ЯЁA-Z]\.$/.test(raw) });
  }
  return out;
}

// ----------------------------------------------------------------------------
// Значения (виды допуска, причины) — фразы, сравниваемые по основам
// ----------------------------------------------------------------------------

/** Фраза словаря → последовательность основ. */
function phraseStems(phrase) {
  return words(phrase).map((w) => ({ stem: stem(w.word), prefix: norm(w.word) }));
}

/**
 * Словарь значений: [{id, label, phrases:[string]}] → готовый к поиску.
 * Название значения само — тоже фраза (узнается в любом падеже).
 */
function buildValues(items) {
  const list = [];
  for (const item of items) {
    for (const phrase of [item.label, ...(item.phrases || [])]) {
      const stems = phraseStems(phrase);
      if (stems.length) list.push({ id: item.id, label: item.label, stems, length: stems.length });
    }
  }
  return list.sort((a, b) => b.length - a.length);
}

const wordMatches = (textWord, p) => {
  const w = norm(textWord);
  return stem(w) === p.stem || (p.prefix.length >= 3 && w.startsWith(p.prefix));
};

/** Значения в тексте — длинные раньше, без наложений; в порядке появления. */
function findValues(text, values) {
  const ws = words(text).filter((w) => !w.initial);
  const used = new Set();
  const found = [];
  for (const v of values) {
    for (let i = 0; i + v.length <= ws.length; i += 1) {
      let ok = true;
      for (let k = 0; k < v.length; k += 1) {
        if (used.has(i + k) || !wordMatches(ws[i + k].word, v.stems[k])) { ok = false; break; }
      }
      if (ok) {
        for (let k = 0; k < v.length; k += 1) used.add(i + k);
        if (!found.some((f) => f.id === v.id)) found.push({ id: v.id, label: v.label, at: ws[i].at });
      }
    }
  }
  return found.sort((a, b) => a.at - b.at);
}

/** Есть ли в тексте хоть одна из фраз (для вида приказа, отметок). */
function hasPhrase(text, phrases) {
  const t = ` ${norm(text)} `;
  return phrases.find((p) => {
    const n = norm(p);
    if (!n) return false;
    if (n.length <= 2) return norm(text) === n;       // «+», «да», «v» — только вся ячейка
    return t.includes(` ${n}`) || t.includes(n);
  }) || null;
}

// ----------------------------------------------------------------------------
// Люди
// ----------------------------------------------------------------------------

/**
 * Указатель людей: форма фамилии (в нижнем регистре) → люди.
 * people: [{id, last_name, first_name, middle_name, label}]
 */
function buildPeople(people) {
  const index = new Map();
  for (const p of people) {
    for (const form of declension.surnameForms({ lastName: p.last_name, middleName: p.middle_name })) {
      const key = norm(form);
      if (!index.has(key)) index.set(key, []);
      if (!index.get(key).includes(p)) index.get(key).push(p);
    }
  }
  return index;
}

const letter = (w) => norm(w)[0];

/**
 * Люди в тексте. Фамилия — слово с заглавной буквы в любом падеже; кто
 * именно — по инициалам или имени-отчеству рядом (после или перед ней).
 * @returns [{at, text, employeeId|null, candidates:[person]}]
 */
function findPeople(text, index) {
  const ws = words(text);
  const found = [];
  for (let i = 0; i < ws.length; i += 1) {
    const w = ws[i];
    if (w.initial || !/^[А-ЯЁ]/.test(w.word)) continue;
    const list = index.get(norm(w.word));
    if (!list) continue;

    // Инициалы или имя-отчество: «Иванов И.И.», «Иванова Ивана Ивановича»
    // (после фамилии) или «И.И. Иванов» (перед ней).
    const after = ws.slice(i + 1, i + 3).filter((x, k) => /^[А-ЯЁ]/.test(x.word) && (k === 0 || x.at - ws[i + k].at < 30));
    const before = ws.slice(Math.max(0, i - 2), i).filter((x) => x.initial);
    const side = after.length ? after : before;
    const letters = side.map((x) => letter(x.word));
    let candidates = list;
    if (letters.length) {
      const narrowed = list.filter((p) => letter(p.first_name) === letters[0]
        && (letters.length < 2 || !p.middle_name || letter(p.middle_name) === letters[1]));
      if (narrowed.length) candidates = narrowed;
    }
    const start = !after.length && before.length ? before[0].at : w.at;
    const last = after.length ? after[after.length - 1] : w;
    found.push({
      at: w.at,
      text: text.slice(start, last.at + last.raw.length),
      employeeId: candidates.length === 1 ? candidates[0].id : null,
      candidates,
    });
  }
  return found;
}

/**
 * Похожие на человека, но не узнанные: «Сидоров С.С.», «С.С. Сидоров» —
 * чтобы проверяющий видел, кого система не нашла в личном составе.
 */
function unknownNames(text, recognized) {
  const out = [];
  const re = /([А-ЯЁ][а-яё]+(?:-[А-ЯЁ][а-яё]+)?)\s+([А-ЯЁ])\.\s?([А-ЯЁ])\.|([А-ЯЁ])\.\s?([А-ЯЁ])\.\s?([А-ЯЁ][а-яё]+)/g;
  let m;
  while ((m = re.exec(text))) {
    const at = m.index;
    if (recognized.some((r) => Math.abs(r.at - at) < 6 || (r.at >= at && r.at <= at + m[0].length))) continue;
    out.push(m[0]);
  }
  return out;
}

// ----------------------------------------------------------------------------
// Даты и периоды
// ----------------------------------------------------------------------------

const MONTHS = ['январ', 'феврал', 'март', 'апрел', 'ма', 'июн', 'июл', 'август', 'сентябр', 'октябр', 'ноябр', 'декабр'];
const pad = (n) => String(n).padStart(2, '0');

/** Даты в тексте по порядку: [{at, date:'YYYY-MM-DD', end}]. */
function findDates(text) {
  const out = [];
  const numeric = /(\d{1,2})\.(\d{1,2})\.(\d{2,4})/g;
  let m;
  while ((m = numeric.exec(text))) {
    const y = m[3].length === 2 ? 2000 + Number(m[3]) : Number(m[3]);
    out.push({ at: m.index, end: m.index + m[0].length, date: `${y}-${pad(m[2])}-${pad(m[1])}` });
  }
  const verbal = /(\d{1,2})\s+([а-яё]+)\s+(\d{4})/gi;
  while ((m = verbal.exec(text))) {
    const name = norm(m[2]);
    const month = MONTHS.findIndex((p) => (p === 'ма' ? name === 'мая' || name === 'май' : name.startsWith(p)));
    if (month >= 0) out.push({ at: m.index, end: m.index + m[0].length, date: `${m[3]}-${pad(month + 1)}-${pad(m[1])}` });
  }
  return out.sort((a, b) => a.at - b.at);
}

function addDays(key, n) {
  const [y, mo, d] = key.split('-').map(Number);
  const x = new Date(y, mo - 1, d + n, 12);
  return `${x.getFullYear()}-${pad(x.getMonth() + 1)}-${pad(x.getDate())}`;
}

/** Период: «с X по Y», «с X до Y», «с X на N суток», «X – Y»; одна дата — начало. */
function findPeriod(text) {
  const dates = findDates(text);
  if (!dates.length) return null;
  const before = (d) => norm(text.slice(Math.max(0, d.at - 4), d.at));
  const from = dates.find((d) => /(^|\s)с$/.test(before(d))) || dates[0];
  const to = dates.find((d) => d !== from && d.at > from.at && /(по|до|[-–—])$/.test(before(d)))
    || dates.find((d) => d !== from && d.at > from.at);
  let dateTo = to ? to.date : null;
  const days = /на\s+(\d{1,3})\s+(сут|дн|день|дня|дней)/i.exec(text);
  if (!dateTo && days) dateTo = addDays(from.date, Number(days[1]) - 1);
  return { from: from.date, to: dateTo };
}

// ----------------------------------------------------------------------------
// Оружие — по номеру из учета, как бы он ни был записан: «СК-А-001»,
// «СК А 001», «ска001» (сравниваются только буквы и цифры).
// ----------------------------------------------------------------------------

const ALNUM = /[0-9a-zа-я]/;
const compact = (s) => norm(s).split('').filter((c) => ALNUM.test(c)).join('');

/**
 * Номера оружия в тексте: [{at, weaponId, serial}].
 * weapons: [{id, serial_number}]
 */
function findWeapons(text, weapons) {
  const low = norm(text);
  // Сжатый текст с позициями исходных знаков.
  let flat = '';
  const pos = [];
  for (let i = 0; i < low.length; i += 1) {
    if (ALNUM.test(low[i])) { flat += low[i]; pos.push(i); }
  }
  const out = [];
  for (const w of weapons) {
    const key = compact(w.serial_number);
    if (key.length < 3 || !/\d/.test(key)) continue;
    let from = 0;
    let at;
    while ((at = flat.indexOf(key, from)) >= 0) {
      from = at + 1;
      const start = pos[at];
      const end = pos[at + key.length - 1];
      // Номер целиком: слева и справа — не буква и не цифра.
      if (ALNUM.test(low[start - 1] || ' ') || ALNUM.test(low[end + 1] || ' ')) continue;
      out.push({ at: start, weaponId: w.id, serial: w.serial_number });
    }
  }
  return out.sort((a, b) => a.at - b.at);
}

/** Упоминание оружия без номера: «с оружием», «автомат», «пистолет». */
const mentionsWeapon = (text) => /оружи|автомат|пистолет|карабин|\bак-?\d|\bпм\b/.test(norm(text));

module.exports = {
  norm, stem, words, buildValues, findValues, hasPhrase, buildPeople, findPeople, unknownNames,
  findDates, findPeriod, addDays, findWeapons, mentionsWeapon,
};
