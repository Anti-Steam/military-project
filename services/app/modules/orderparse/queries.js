'use strict';

// SQL модуля «Разбор приказов» (МС-3): словарь разбора и извлеченная
// структура документов. Люди, виды допуска и причины — через сервис
// личного состава.

const db = require('../../db/pool');

async function listPhrases() {
  const { rows } = await db.query(`
    SELECT p.id, p.kind, p.target, p.phrase, p.section_id, to_char(p.created_at, 'YYYY-MM-DD') AS created_on, u.login AS author
    FROM parse.phrases p LEFT JOIN core.users u ON u.id = p.created_by
    ORDER BY p.kind, p.target NULLS FIRST, p.phrase
  `);
  return rows;
}

async function addPhrase({ kind, target, phrase, userId }) {
  const { rows } = await db.query(`
    INSERT INTO parse.phrases (kind, target, phrase, created_by, section_id)
    VALUES ($1, $2, $3, $4, (SELECT id FROM parse.sections WHERE builtin AND kind = $1 LIMIT 1))
    ON CONFLICT (kind, target, phrase) DO NOTHING RETURNING id
  `, [kind, target || null, phrase, userId || null]);
  return rows[0] ? rows[0].id : null;
}

/** Разделы словаря (по назначению слов), с числом слов. */
async function listSections() {
  const { rows } = await db.query(`
    SELECT s.id, s.name, s.kind, s.builtin,
           (SELECT count(*)::int FROM parse.phrases p WHERE p.section_id = s.id) AS phrases
    FROM parse.sections s ORDER BY s.sort_order, s.id
  `);
  return rows;
}

// Виды приказов для разбора («Приказ на караул»): как узнать и что делать.
const PROFILE_FIELDS = `
  p.id, p.name, p.header_phrases, p.absence_code, p.permit_type_id, p.reserve_weapons,
  p.default_days, p.is_active, p.sort_order`;

async function listProfiles() {
  const { rows } = await db.query(`
    SELECT ${PROFILE_FIELDS},
           (SELECT count(*)::int FROM personnel.permit_orders o WHERE o.profile_id = p.id) AS orders
    FROM parse.profiles p ORDER BY p.sort_order, p.name
  `);
  return rows;
}

async function getProfile(id) {
  const { rows } = await db.query(`SELECT ${PROFILE_FIELDS} FROM parse.profiles p WHERE p.id = $1`, [id]);
  return rows[0] || null;
}

async function createProfile(d) {
  const { rows } = await db.query(`
    INSERT INTO parse.profiles (name, header_phrases, absence_code, permit_type_id, reserve_weapons, default_days, sort_order, created_by)
    VALUES ($1, $2, $3, $4, $5, $6, (SELECT coalesce(max(sort_order), 0) + 10 FROM parse.profiles), $7) RETURNING id
  `, [d.name, d.headerPhrases, d.absenceCode, d.permitTypeId, d.reserveWeapons, d.defaultDays, d.userId || null]);
  return rows[0].id;
}

async function updateProfile(id, d) {
  await db.query(`
    UPDATE parse.profiles SET name = $2, header_phrases = $3, absence_code = $4, permit_type_id = $5,
           reserve_weapons = $6, default_days = $7, is_active = $8
    WHERE id = $1
  `, [id, d.name, d.headerPhrases, d.absenceCode, d.permitTypeId, d.reserveWeapons, d.defaultDays, d.isActive]);
}

async function deleteProfile(id) {
  await db.query('DELETE FROM parse.profiles WHERE id = $1', [id]);
}

async function deletePhrase(id) {
  await db.query('DELETE FROM parse.phrases WHERE id = $1', [id]);
}

async function getDocument(orderId) {
  const { rows } = await db.query('SELECT blocks, error, extracted_at FROM parse.documents WHERE order_id = $1', [orderId]);
  return rows[0] || null;
}

async function saveDocument(orderId, blocks, error) {
  await db.query(`
    INSERT INTO parse.documents (order_id, blocks, error, extracted_at) VALUES ($1, $2, $3, now())
    ON CONFLICT (order_id) DO UPDATE SET blocks = $2, error = $3, extracted_at = now()
  `, [orderId, blocks ? JSON.stringify(blocks) : null, error || null]);
}

module.exports = {
  listPhrases, addPhrase, deletePhrase, getDocument, saveDocument,
  listSections, listProfiles, getProfile, createProfile, updateProfile, deleteProfile,
};
