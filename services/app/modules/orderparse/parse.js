'use strict';

// Разбор приказа по структуре документа — общими правилами, без шаблонов
// под каждую формулировку:
//
//   1. ВИД ПРИКАЗА — по заголовку (первые абзацы): словари order_permit /
//      order_absence («о допуске», «об убытии»). Разбор идет по виду, под
//      которым приказ заведен в реестре (от него зависит, что можно внести);
//      вид по заголовку — подсказка: разошлись — проверяющий предупреждается.
//      Вида в реестре нет — берется по заголовку.
//   2. ЗАГОЛОВОК ПУНКТА И ПЕРЕЧЕНЬ. Абзац со значениями (виды допуска,
//      причина) и без людей задает контекст; люди ниже получают его целиком
//      (все допуски пункта; причину и период). Свой период у человека в
//      строке — сильнее общего. Абзац со значениями и людьми сразу — сам себе
//      пункт. Контекст действует до следующего абзаца со значениями.
//   3. ТАБЛИЦА (приложение). Шапка со значениями в столбцах — люди в строках,
//      отметка в ячейке («допущен», «+») — допуск; пустая — нет. Таблица без
//      значений в шапке — каждая строка разбирается как абзац (ФИО, даты,
//      причина — в своих столбцах).
//
// Результат — ПРЕДЛОЖЕНИЯ для проверки человеком, а не записи. Модуль
// чистый: словари и личный состав передаются снаружи.

const r = require('./recognize');

/**
 * @param {object[]} blocks  структура документа (blocks.js)
 * @param {object}   dict    {orderPermit, orderAbsence, marks:[string],
 *                            permits:[{id,label,phrases}], absences:[{id(code),label,phrases}]}
 * @param {object[]} people  личный состав [{id,last_name,first_name,middle_name,label}]
 * @param {string}   fallbackKind  вид приказа из реестра
 */
function parse(blocks, dict, people, fallbackKind) {
  const index = r.buildPeople(people);
  const permitValues = r.buildValues(dict.permits);
  const absenceValues = r.buildValues(dict.absences);

  // 1. Вид — по заголовку, затем по всему тексту.
  const paragraphs = blocks.filter((b) => b.type === 'p').map((b) => b.text);
  const head = paragraphs.slice(0, 8).join(' ');
  const score = (text) => ({
    permit: dict.orderPermit.filter((p) => r.hasPhrase(text, [p])).length,
    absence: dict.orderAbsence.filter((p) => r.hasPhrase(text, [p])).length,
  });
  let s = score(head);
  if (s.permit === s.absence) s = score(paragraphs.join(' '));
  const detected = s.permit > s.absence ? 'permit' : (s.absence > s.permit ? 'absence' : null);
  const kind = fallbackKind || detected || 'permit';
  const values = kind === 'permit' ? permitValues : absenceValues;
  const matchedBy = (detected === 'permit' ? dict.orderPermit : dict.orderAbsence)
    .filter((p) => r.hasPhrase(head, [p]));

  const facts = [];
  const unparsed = [];
  const unknown = [];
  let context = null;

  const push = (person, found, period, snippet, where) => {
    const list = found.length ? found : [{ id: null, label: null }];
    for (const v of list) {
      facts.push({
        kind, personText: person.text, employeeId: person.employeeId,
        candidates: person.candidates.map((c) => c.id),
        valueId: v.id, valueLabel: v.label,
        dateFrom: period ? period.from : null, dateTo: period ? period.to : null,
        snippet, where,
      });
    }
  };

  const handleText = (text, where) => {
    const found = r.findValues(text, values);
    const persons = r.findPeople(text, index);
    const period = r.findPeriod(text);
    unknown.push(...r.unknownNames(text, persons).map((name) => ({ name, where, snippet: text })));

    if (found.length && persons.length === 0) {
      // Заголовок пункта: задает, что получают люди ниже.
      context = { values: found, period };
      return;
    }
    if (persons.length === 0) return;
    const use = found.length ? found : (context ? context.values : []);
    const usePeriod = period && period.from ? period : (context ? context.period : null);
    if (!use.length) unparsed.push({ where, text, reason: 'люди есть, а что им — не понятно' });
    for (const person of persons) push(person, use, usePeriod, text, where);
    if (found.length && /:\s*$/.test(text)) context = { values: found, period };
  };

  blocks.forEach((block, bi) => {
    const where = `${block.type === 'table' ? 'таблица' : 'абзац'} ${bi + 1}`;
    if (block.type === 'p') { handleText(block.text, where); return; }

    // 3. Таблица: шапка со значениями — люди × значения с отметкой.
    const headerAt = block.rows.findIndex((row) => row.some((cell) => r.findValues(cell, values).length));
    const header = headerAt >= 0 ? block.rows[headerAt] : null;
    const columns = header ? header.map((cell) => {
      const v = r.findValues(cell, values);
      return v.length === 1 ? v[0] : null;
    }) : [];
    const valueColumns = columns.filter(Boolean).length;
    if (header && valueColumns >= (kind === 'permit' ? 1 : 2)) {
      block.rows.slice(headerAt + 1).forEach((row, ri) => {
        const persons = r.findPeople(row.join(' '), index);
        if (!persons.length) {
          const names = r.unknownNames(row.join(' '), []);
          unknown.push(...names.map((name) => ({ name, where: `${where}, строка ${ri + 1}`, snippet: row.join(' | ') })));
          return;
        }
        const marked = columns
          .map((v, ci) => (v && r.hasPhrase(row[ci] || '', dict.marks) ? v : null))
          .filter(Boolean);
        if (marked.length) push(persons[0], marked, null, row.join(' | '), `${where}, строка ${ri + 1}`);
      });
      return;
    }
    // Таблица без значений в шапке — строка как абзац (ФИО, даты, причина).
    block.rows.forEach((row, ri) => handleText(row.join(' ; '), `${where}, строка ${ri + 1}`));
  });

  return { kind, detected, matchedBy, facts, unparsed, unknown };
}

/**
 * Разбор приказа своего вида (профиль: «Приказ на караул»). Что делать с
 * людьми, задано видом; из приказа берутся только люди, сроки и оружие:
 *   - человек — как везде (любой падеж, инициалы);
 *   - срок — свой в строке человека или общий из абзаца без людей выше
 *     («с 12.10.2026 по 14.10.2026 назначить в караул:»); нет конца —
 *     срок по умолчанию вида (default_days);
 *   - оружие — номер из учета в куске текста человека (от него до
 *     следующего человека). Номера нет, но оружие упомянуто — предлагается
 *     закрепленное за человеком.
 * Одна строка — один человек и одна единица оружия (две единицы — две строки).
 *
 * @param {object}   profile  {header_phrases, reserve_weapons, default_days}
 * @param {object[]} weapons  [{id, serial_number, holder_id}]
 * @param {string}   issuedOn дата издания — «от 10.10.2026» не срок
 */
function parseProfile(blocks, profile, people, weapons, issuedOn) {
  const index = r.buildPeople(people);
  const paragraphs = blocks.filter((b) => b.type === 'p').map((b) => b.text);
  const head = paragraphs.slice(0, 8).join(' ');
  const matchedBy = (profile.header_phrases || []).filter((p) => r.hasPhrase(head, [p]));

  const facts = [];
  const unparsed = [];
  const unknown = [];
  let period = null;

  const handleText = (text, where) => {
    const persons = r.findPeople(text, index);
    const own = r.findPeriod(text);
    unknown.push(...r.unknownNames(text, persons).map((name) => ({ name, where, snippet: text })));
    if (!persons.length) {
      if (own && own.from && !(own.from === issuedOn && !own.to)) period = own;
      return;
    }
    const use = own && own.from ? own : period;
    const found = profile.reserve_weapons ? r.findWeapons(text, weapons) : [];
    persons.forEach((person, i) => {
      const start = i === 0 ? 0 : person.at;
      const end = persons[i + 1] ? persons[i + 1].at : text.length;
      const piece = text.slice(start, end);
      let ids = found.filter((w) => w.at >= start && w.at < end).map((w) => w.weaponId);
      if (!ids.length && profile.reserve_weapons && person.employeeId && r.mentionsWeapon(piece)) {
        const mine = weapons.find((w) => w.holder_id === person.employeeId);
        if (mine) ids = [mine.id];
      }
      let dateTo = use ? use.to : null;
      if (use && use.from && !dateTo && profile.default_days) dateTo = r.addDays(use.from, profile.default_days - 1);
      for (const weaponId of (ids.length ? ids : [null])) {
        facts.push({
          personText: person.text, employeeId: person.employeeId,
          candidates: person.candidates.map((c) => c.id),
          weaponId, dateFrom: use ? use.from : null, dateTo, snippet: text, where,
        });
      }
    });
    if (!use) unparsed.push({ where, text, reason: 'люди есть, а срок не указан' });
  };

  blocks.forEach((block, bi) => {
    const where = `${block.type === 'table' ? 'таблица' : 'абзац'} ${bi + 1}`;
    if (block.type === 'p') handleText(block.text, where);
    else block.rows.forEach((row, ri) => handleText(row.join(' ; '), `${where}, строка ${ri + 1}`));
  });

  return { kind: 'other', detected: null, matchedBy, facts, unparsed, unknown };
}

module.exports = { parse, parseProfile };
