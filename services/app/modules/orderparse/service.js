'use strict';

// Разбор приказов (МС-3): по приказу из реестра — предложения «кому что»
// для проверки; принятое вносится обычными путями (выдача допуска, отметка
// отсутствия) с пометкой «из приказа». Словарь пополняется при проверке.

const queries = require('./queries');
const { parse, parseProfile } = require('./parse');
const db = require('../../db/pool');
const { extract } = require('./extract');
const personnel = require('../personnel/service');
const documents = require('../../lib/documents');
const v = require('../../lib/validation');

const KINDS = {
  order_permit: 'Заголовок: приказ о допуске',
  order_absence: 'Заголовок: приказ об отсутствии',
  permit: 'Вид допуска — иное написание',
  absence: 'Причина отсутствия — иное написание',
  mark_yes: 'Отметка «допущен» в таблице',
};

/** Словарь для разбора: из справочников и из parse.phrases. */
async function dictionary() {
  const [phrases, permitTypes, absenceTypes] = await Promise.all([
    queries.listPhrases(), personnel.listPermitTypes(), personnel.listAbsenceTypes(),
  ]);
  const of = (kind, target) => phrases.filter((p) => p.kind === kind && (target === undefined || p.target === String(target)))
    .map((p) => p.phrase);
  return {
    orderPermit: of('order_permit'),
    orderAbsence: of('order_absence'),
    marks: of('mark_yes'),
    permits: permitTypes.map((t) => ({ id: t.id, label: t.name, phrases: of('permit', t.id) })),
    absences: absenceTypes.map((t) => ({ id: t.code, label: t.name, phrases: of('absence', t.code) })),
  };
}

/** Структура документа приказа: сохраненная или прочитанная заново. */
async function documentOf(order, again) {
  const stored = await queries.getDocument(order.id);
  if (stored && !again) return stored;
  const full = documents.resolve(order.file_path);
  if (!full) {
    const error = 'К приказу не приложен файл — разбирать нечего. Приложите файл или внесите данные вручную.';
    return { blocks: null, error };
  }
  try {
    const blocks = await extract(full);
    await queries.saveDocument(order.id, blocks, null);
    return { blocks, error: null };
  } catch (err) {
    if (!err.userMessage) throw err;
    await queries.saveDocument(order.id, null, err.message);
    return { blocks: null, error: err.message };
  }
}

/**
 * Разбор для проверки: предложения с пометкой «уже внесено», не узнанные
 * люди и не разобранные пункты.
 */
async function review(orderId, { again = false } = {}) {
  const order = await personnel.getOrder(orderId);
  if (!order) v.fail('Приказ не найден.', 404);
  const doc = await documentOf(order, again);
  if (order.kind === 'other') return reviewProfile(order, doc);
  const [dict, people] = await Promise.all([dictionary(), personnel.listEmployees()]);

  const result = doc.blocks
    ? parse(doc.blocks, dict, people, order.kind)
    : { kind: order.kind, detected: null, matchedBy: [], facts: [], unparsed: [], unknown: [] };

  // Уже внесенное по этому приказу — чтобы не вносить дважды.
  const [permits, absences] = await Promise.all([personnel.orderPermits(order.id), personnel.orderAbsences(order.id)]);
  const absenceName = new Map(dict.absences.map((a) => [a.id, a.label]));
  for (const f of result.facts) {
    f.exists = order.kind === 'permit'
      ? permits.some((p) => p.employee_id === f.employeeId && p.permit_type_id === f.valueId)
      : absences.some((a) => a.employee_id === f.employeeId && a.reason === absenceName.get(f.valueId));
  }

  return { order, error: doc.error, extractedAt: doc.extracted_at, blocks: doc.blocks || [], dict, people, ...result };
}

/** Разбор приказа своего вида: люди, сроки, оружие. */
async function reviewProfile(order, doc) {
  const [profile, people, weapons, absences, reservations, dict] = await Promise.all([
    queries.getProfile(order.profile_id), personnel.listEmployees(), personnel.activeWeapons(),
    personnel.orderAbsences(order.id), personnel.orderReservations(order.id), dictionary(),
  ]);
  const result = doc.blocks
    ? parseProfile(doc.blocks, profile, people, weapons, order.issued_on)
    : { kind: 'other', detected: null, matchedBy: [], facts: [], unparsed: [], unknown: [] };
  for (const f of result.facts) {
    const absent = !profile.absence_code || absences.some((a) => a.employee_id === f.employeeId);
    const reserved = !f.weaponId || reservations.some((r) => r.weapon_id === f.weaponId);
    f.exists = Boolean(f.employeeId) && absent && reserved;
  }
  return { order, profile, weapons, error: doc.error, extractedAt: doc.extracted_at, blocks: doc.blocks || [],
    dict, people, ...result };
}

/**
 * Принять строки приказа своего вида: что делать — от вида (отметить
 * отсутствующим, выдать допуск, занять оружие). Человек отмечается один
 * раз, даже если у него две строки (два оружия); уже внесенное по этому
 * приказу — пропускается.
 */
async function applyProfile(order, rows, userId) {
  const profile = await queries.getProfile(order.profile_id);
  const [absences, reservations, permits] = await Promise.all([
    personnel.orderAbsences(order.id), personnel.orderReservations(order.id), personnel.orderPermits(order.id),
  ]);
  const absent = new Set(absences.map((a) => a.employee_id));
  const reserved = new Set(reservations.map((r) => r.weapon_id));
  const permitted = new Set(permits.map((p) => p.employee_id));
  const results = [];
  for (const row of rows) {
    try {
      if (!row.employeeId) v.fail('не выбран человек');
      if (!row.dateFrom) v.fail('не указано начало');
      const weaponId = profile.reserve_weapons && row.weaponId ? Number(row.weaponId) : null;
      await db.transaction(async () => {
        if (profile.absence_code && !absent.has(row.employeeId)) {
          await personnel.recordAbsence({ employeeId: row.employeeId, typeCode: profile.absence_code,
            dateFrom: row.dateFrom, dateTo: row.dateTo || '', openEnded: !row.dateTo, orderId: order.id,
            source: 'import', userId, note: profile.name });
        }
        if (profile.permit_type_id && !permitted.has(row.employeeId)) {
          await personnel.grantPermit({ employeeId: row.employeeId, permitTypeId: profile.permit_type_id,
            orderId: order.id, expiresAt: row.dateTo || null, note: 'из приказа (разбор)' });
        }
        if (weaponId && !reserved.has(weaponId)) {
          if (!row.dateTo) v.fail('оружие занимается на срок — укажите окончание');
          await personnel.reserveWeapon({ weaponId, employeeId: row.employeeId, dateFrom: row.dateFrom,
            dateTo: row.dateTo, reason: profile.name, orderId: order.id }, userId);
        }
      });
      absent.add(row.employeeId);
      permitted.add(row.employeeId);
      if (weaponId) reserved.add(weaponId);
      results.push({ row, ok: true });
    } catch (err) {
      if (!err.userMessage) throw err;
      results.push({ row, ok: false, message: err.message });
    }
  }
  return results;
}

/**
 * Принять проверенные строки: допуски выдаются, отсутствия отмечаются — теми
 * же путями, что и вручную, с пометкой «из приказа». Каждая строка —
 * отдельно: ошибка в одной не отменяет другие.
 */
async function apply(orderId, rows, userId) {
  const order = await personnel.getOrder(orderId);
  if (!order) v.fail('Приказ не найден.', 404);
  if (order.kind === 'other') return applyProfile(order, rows, userId);
  const results = [];
  for (const row of rows) {
    try {
      if (!row.employeeId) v.fail('не выбран человек');
      if (!row.valueId) v.fail(order.kind === 'permit' ? 'не выбран вид допуска' : 'не выбрана причина');
      await db.transaction(async () => {
        if (order.kind === 'permit') {
          await personnel.grantPermit({ employeeId: row.employeeId, permitTypeId: row.valueId, orderId: order.id,
            expiresAt: row.dateTo || null, note: 'из приказа (разбор)' });
        } else {
          await personnel.recordAbsence({ employeeId: row.employeeId, typeCode: row.valueId, dateFrom: row.dateFrom,
            dateTo: row.dateTo || '', openEnded: !row.dateTo, orderId: order.id, source: 'import', userId });
        }
      });
      results.push({ row, ok: true });
    } catch (err) {
      if (!err.userMessage) throw err;
      results.push({ row, ok: false, message: err.message });
    }
  }
  return results;
}

/** Научить: вариант написания в словарь (в стандартный раздел своего вида). */
async function addPhrase({ kind, target, phrase }, userId) {
  if (!KINDS[kind]) v.fail('Неизвестный вид записи словаря.');
  const text = String(phrase || '').trim().toLowerCase();
  if (!text) v.fail('Укажите слово или фразу.');
  if (text.length > 200) v.fail('Слишком длинная фраза.');
  const needsTarget = kind === 'permit' || kind === 'absence';
  if (needsTarget && !target) v.fail('Укажите, что означает фраза.');
  return queries.addPhrase({ kind, target: needsTarget ? String(target) : null, phrase: text, userId });
}

// ----------------------------------------------------------------------------
// Свои виды приказов («Приказ на караул»): как узнать и что делать с
// каждым найденным человеком.
// ----------------------------------------------------------------------------

async function checkProfile(data) {
  const name = String(data.name || '').trim();
  if (!name) v.fail('Укажите название вида приказа.');
  if (name.length > 120) v.fail('Слишком длинное название.');
  const headerPhrases = String(data.headerPhrases || '').split(/[,;\n]/).map((x) => x.trim().toLowerCase())
    .filter(Boolean).slice(0, 20);
  const absenceCode = String(data.absenceCode || '') || null;
  if (absenceCode && !(await personnel.listAbsenceTypes()).some((t) => t.code === absenceCode)) {
    v.fail('Неизвестная причина отсутствия.');
  }
  const permitTypeId = data.permitTypeId ? v.id(data.permitTypeId) : null;
  const reserveWeapons = data.reserveWeapons === 'on' || data.reserveWeapons === true;
  let defaultDays = null;
  if (String(data.defaultDays || '').trim()) {
    defaultDays = Number(data.defaultDays);
    if (!Number.isInteger(defaultDays) || defaultDays < 1 || defaultDays > 366) v.fail('Срок по умолчанию — от 1 до 366 суток.');
  }
  if (!absenceCode && !permitTypeId && !reserveWeapons) {
    v.fail('Укажите, что делать с людьми из приказа: отметить отсутствующими, выдать допуск или занять оружие.');
  }
  return { name, headerPhrases, absenceCode, permitTypeId, reserveWeapons, defaultDays };
}

async function createProfile(data, userId) {
  return queries.createProfile({ ...(await checkProfile(data)), userId });
}

async function updateProfile(id, data) {
  const profile = await queries.getProfile(v.id(id));
  if (!profile) v.fail('Вид приказа не найден.', 404);
  await queries.updateProfile(profile.id, { ...(await checkProfile(data)), isActive: data.isActive === 'on' });
}

/** Удалить вид — только без приказов; с приказами — выключить. */
async function removeProfile(id) {
  const profile = (await queries.listProfiles()).find((p) => p.id === v.id(id));
  if (!profile) v.fail('Вид приказа не найден.', 404);
  if (profile.orders > 0) v.fail(`Приказов этого вида: ${profile.orders}. Вид не удаляется — выключите его.`);
  await queries.deleteProfile(profile.id);
}

module.exports = {
  KINDS, dictionary, review, apply, addPhrase, createProfile, updateProfile, removeProfile,
  listSections: queries.listSections,
  listProfiles: queries.listProfiles,
  listPhrases: queries.listPhrases,
  deletePhrase: (id) => queries.deletePhrase(v.id(id)),
};
