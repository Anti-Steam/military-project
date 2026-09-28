'use strict';

// SQL модуля оргструктуры.
// Обращаться сюда напрямую вправе только org/service.js.

const db = require('../../db/pool');

const UNIT_FIELDS = `
    u.id, u.parent_id, u.name, u.short_name, u.sort_order, u.is_active,
    u.commander_employee_id, u.staff_count
`;

/**
 * Поддерево подразделения: оно само и все вложенные на любую глубину.
 *
 * На этом держится вся область видимости: командир взвода отвечает за свои
 * отделения, командир роты — за взводы вместе с их отделениями. Обход в
 * глубину делает СУБД: собирать дерево в коде значило бы тянуть всю таблицу
 * ради двух-трех строк.
 */
async function subtreeIds(unitId) {
  if (!unitId) return null;

  const { rows } = await db.query(`
    WITH RECURSIVE tree AS (
      SELECT id FROM core.units WHERE id = $1
      UNION ALL
      SELECT u.id FROM core.units u JOIN tree t ON u.parent_id = t.id
    )
    SELECT id FROM tree
  `, [unitId]);

  return rows.map((r) => r.id);
}

/** Путь от корня до подразделения — для заголовка и хлебных крошек. */
async function path(unitId) {
  const { rows } = await db.query(`
    WITH RECURSIVE up AS (
      SELECT id, parent_id, short_name, 0 AS depth FROM core.units WHERE id = $1
      UNION ALL
      SELECT u.id, u.parent_id, u.short_name, up.depth + 1
      FROM core.units u JOIN up ON up.parent_id = u.id
    )
    SELECT id, short_name FROM up ORDER BY depth DESC
  `, [unitId]);
  return rows;
}

/**
 * Подразделения вместе с числом людей и командиром.
 *
 * Считается ЧИСЛО В САМОМ подразделении и ЧИСЛО В ПОДДЕРЕВЕ: у роты своих
 * людей двое — управление, — а в подчинении сотня, и показывать нужно оба.
 */
async function listUnits(scopeIds) {
  const { rows } = await db.query(`
    WITH RECURSIVE
    -- Путь от верхнего уровня: «1 рота · 1 взвод». Нужен там, где
    -- подразделения показываются плоским списком — в дереве вложенность
    -- видна сама, а в выпадающем списке «1 взвод» есть у каждой роты.
    paths AS (
      SELECT id, short_name::text AS path, 0 AS level
      FROM core.units WHERE parent_id IS NULL
      UNION ALL
      SELECT c.id,
             CASE WHEN p.level = 0 THEN c.short_name ELSE p.path || ' · ' || c.short_name END,
             p.level + 1
      FROM core.units c JOIN paths p ON c.parent_id = p.id
    ),
    tree AS (
      SELECT id, id AS root FROM core.units
      UNION ALL
      SELECT u.id, t.root FROM core.units u JOIN tree t ON u.parent_id = t.id
    ),
    totals AS (
      SELECT t.root AS unit_id, count(e.id)::int AS total
      FROM tree t LEFT JOIN personnel.employees e ON e.unit_id = t.id AND e.is_active
      GROUP BY t.root
    )
    SELECT ${UNIT_FIELDS},
           paths.path AS path_name,
           coalesce(own.n, 0) AS own_count,
           coalesce(totals.total, 0) AS total_count,
           concat_ws(' ', r.name, c.last_name, c.first_name) AS commander_name
    FROM core.units u
    LEFT JOIN paths ON paths.id = u.id
    LEFT JOIN totals ON totals.unit_id = u.id
    LEFT JOIN LATERAL (
      SELECT count(*)::int AS n FROM personnel.employees e
      WHERE e.unit_id = u.id AND e.is_active
    ) own ON true
    LEFT JOIN personnel.employees c ON c.id = u.commander_employee_id
    LEFT JOIN core.ranks r          ON r.id = c.rank_id
    WHERE $1::int[] IS NULL OR u.id = ANY($1::int[])
    ORDER BY u.sort_order, u.short_name
  `, [scopeIds]);
  return rows;
}

async function getUnit(id) {
  const { rows } = await db.query(`SELECT ${UNIT_FIELDS} FROM core.units u WHERE u.id = $1`, [id]);
  return rows[0] || null;
}

async function createUnit({ parentId, name, shortName, sortOrder }) {
  const { rows } = await db.query(`
    INSERT INTO core.units (parent_id, name, short_name, sort_order)
    VALUES ($1, $2, $3,
            -- Новое — в конец среди соседей; порядок потом перетаскивается.
            COALESCE($4, (SELECT coalesce(max(sort_order), 0) + 10
                          FROM core.units WHERE parent_id IS NOT DISTINCT FROM $1)))
    RETURNING id
  `, [parentId, name, shortName, sortOrder ?? null]);
  return rows[0].id;
}

async function updateUnit(id, { name, shortName, sortOrder, parentId, isActive }) {
  await db.query(`
    UPDATE core.units
       SET name = $2, short_name = $3,
           -- Порядок задается перетаскиванием; при переносе в другое
           -- вышестоящее подразделение — в конец среди новых соседей.
           sort_order = CASE
             WHEN $4::int IS NOT NULL THEN $4::int
             WHEN $5::int IS DISTINCT FROM parent_id THEN
               (SELECT coalesce(max(s.sort_order), 0) + 10 FROM core.units s
                WHERE s.parent_id IS NOT DISTINCT FROM $5::int)
             ELSE sort_order END,
           parent_id = $5, is_active = $6, updated_at = now()
     WHERE id = $1
  `, [id, name, shortName, sortOrder ?? null, parentId, isActive]);
}


/**
 * Что держит подразделение: вложенные, люди, наряды, закрепления и учетные
 * записи. Удалить можно только то, за что ничего не держится.
 */
async function usage(id) {
  const { rows } = await db.query(`
    SELECT (SELECT count(*)::int FROM core.units WHERE parent_id = $1)                AS children,
           (SELECT count(*)::int FROM personnel.employees WHERE unit_id = $1)         AS employees,
           (SELECT count(*)::int FROM duty.duties WHERE unit_id = $1)                 AS duties,
           (SELECT count(*)::int FROM duty.duty_posts WHERE unit_id = $1)             AS posts,
           ((SELECT count(*) FROM duty.post_units WHERE unit_id = $1)
            + (SELECT count(*) FROM duty.post_responsibilities WHERE unit_id = $1))::int AS responsibilities,
           (SELECT count(*)::int FROM core.users WHERE scope_unit_id = $1)            AS users
  `, [id]);
  return rows[0];
}

async function deleteUnit(id) {
  await db.query('DELETE FROM core.units WHERE id = $1', [id]);
}

/** Непосредственно вложенные подразделения — для проверки перестановки. */
async function childIds(parentId) {
  const { rows } = await db.query('SELECT id FROM core.units WHERE parent_id = $1', [parentId]);
  return rows.map((r) => r.id);
}

/** Порядок вложенных подразделений по перечню: 10, 20, 30… */
async function setChildOrder(parentId, ids) {
  await db.query(`
    UPDATE core.units u SET sort_order = o.n * 10, updated_at = now()
    FROM unnest($2::int[]) WITH ORDINALITY AS o(id, n)
    WHERE u.id = o.id AND u.parent_id = $1
  `, [parentId, ids]);
}

async function employeeUnit(employeeId) {
  const { rows } = await db.query(
    'SELECT unit_id FROM personnel.employees WHERE id = $1', [employeeId],
  );
  return rows[0] ? rows[0].unit_id : null;
}

/** Личный состав подразделений поддерева — для дерева личного состава. */
async function employeesIn(unitIds) {
  const { rows } = await db.query(`
    SELECT e.id, e.unit_id, e.personnel_number, e.position, e.is_active,
           concat_ws(' ', e.last_name, e.first_name, e.middle_name) AS full_name,
           concat_ws(' ', r.short_name, e.last_name) AS short_name,
           r.name AS rank_name, r.seniority
    FROM personnel.employees e
    LEFT JOIN core.ranks r ON r.id = e.rank_id
    WHERE e.unit_id = ANY($1::int[]) AND e.is_active
    ORDER BY r.seniority DESC NULLS LAST, e.last_name
  `, [unitIds]);
  return rows;
}

// ----------------------------------------------------------------------------
// Штат: должности подразделений
// ----------------------------------------------------------------------------

/** Должности подразделений вместе с занимающими их людьми (вакантные — без). */
async function listPositions(unitIds) {
  const { rows } = await db.query(`
    SELECT p.id, p.unit_id, p.title, p.sort_order, p.employee_id, p.is_commander,
           concat_ws(' ', e.last_name, e.first_name, e.middle_name) AS full_name,
           concat_ws(' ', r.short_name, e.last_name) AS short_name,
           r.name AS rank_name
    FROM core.positions p
    LEFT JOIN personnel.employees e ON e.id = p.employee_id
    LEFT JOIN core.ranks r          ON r.id = e.rank_id
    WHERE $1::int[] IS NULL OR p.unit_id = ANY($1::int[])
    ORDER BY p.unit_id, p.sort_order, p.id
  `, [unitIds]);
  return rows;
}

async function getPosition(id) {
  const { rows } = await db.query('SELECT * FROM core.positions WHERE id = $1', [id]);
  return rows[0] || null;
}

async function positionOf(employeeId) {
  const { rows } = await db.query('SELECT * FROM core.positions WHERE employee_id = $1', [employeeId]);
  return rows[0] || null;
}

/** Новая должность — в конец штата подразделения. */
async function createPosition(unitId, title) {
  const { rows } = await db.query(`
    INSERT INTO core.positions (unit_id, title, sort_order)
    VALUES ($1, $2, (SELECT coalesce(max(sort_order), 0) + 10 FROM core.positions WHERE unit_id = $1))
    RETURNING id
  `, [unitId, title]);
  return rows[0].id;
}

/**
 * Человек ушел из подразделения (перевод, за штат): закрепленное за ним
 * оружие того подразделения открепляется и остается в нем за командиром.
 */
async function releaseWeapons(employeeId, keepUnitId = null) {
  await db.query(`UPDATE personnel.weapons SET owner_id = NULL
    WHERE owner_id = $1 AND unit_id IS DISTINCT FROM $2::int`, [employeeId, keepUnitId]);
}

/**
 * Командир подразделения — тот, кто занимает его командирскую должность.
 *
 * Меняется командир — меняется и доступ: учетная запись нового получает роль
 * командира с зоной этого подразделения (если ее роль не выше командира),
 * учетная запись прежнего, получившая командирство так же, возвращается к
 * роли пользователя. У подразделения без командирской должности командир
 * не трогается.
 */
async function syncCommander(unitId, force = false) {
  if (!unitId) return;
  const { rows: [unit] } = await db.query(`
    SELECT u.commander_employee_id AS prev,
           (SELECT p.employee_id FROM core.positions p WHERE p.unit_id = u.id AND p.is_commander) AS next,
           EXISTS (SELECT 1 FROM core.positions p WHERE p.unit_id = u.id AND p.is_commander) AS has_post
    FROM core.units u WHERE u.id = $1
  `, [unitId]);
  // force — командирская должность только что ушла из подразделения
  // (удалена или перенесена): командирство снимается и без нее.
  if (!unit || (!unit.has_post && !force) || unit.prev === unit.next) return;

  await db.query('UPDATE core.units SET commander_employee_id = $2, updated_at = now() WHERE id = $1',
    [unitId, unit.next]);
  if (unit.prev) {
    await db.query(`UPDATE core.users SET role_code = 'user', updated_at = now()
      WHERE employee_id = $1 AND role_code = 'commander' AND scope_unit_id = $2`, [unit.prev, unitId]);
  }
  if (unit.next) {
    await db.query(`UPDATE core.users SET role_code = 'commander', scope_unit_id = $2, updated_at = now()
      WHERE employee_id = $1 AND role_code IN ('user', 'commander')`, [unit.next, unitId]);
  }
}

/** Есть ли у подразделения командирская должность. */
async function hasCommanderPosition(unitId) {
  const { rows } = await db.query(
    'SELECT 1 FROM core.positions WHERE unit_id = $1 AND is_commander LIMIT 1', [unitId]);
  return rows.length > 0;
}

/** Снять отметку командирской: командирство подразделения снимается. */
async function clearCommanderPosition(positionId) {
  await db.transaction(async () => {
    const { rows: [p] } = await db.query(
      'UPDATE core.positions SET is_commander = false WHERE id = $1 RETURNING unit_id', [positionId]);
    if (p) await syncCommander(p.unit_id, true);
  });
}

/** Командирская должность подразделения — одна; прежняя отметка снимается. */
async function setCommanderPosition(positionId) {
  await db.transaction(async () => {
    const { rows: [p] } = await db.query('SELECT unit_id FROM core.positions WHERE id = $1', [positionId]);
    await db.query('UPDATE core.positions SET is_commander = false WHERE unit_id = $1 AND is_commander', [p.unit_id]);
    await db.query('UPDATE core.positions SET is_commander = true WHERE id = $1', [positionId]);
    await syncCommander(p.unit_id);
  });
}

/** Переименование; наименование должности у занимающего меняется тоже. */
async function renamePosition(id, title) {
  await db.transaction(async () => {
    await db.query('UPDATE core.positions SET title = $2 WHERE id = $1', [id, title]);
    await db.query(`UPDATE personnel.employees e SET position = $2, updated_at = now()
      FROM core.positions p WHERE p.id = $1 AND e.id = p.employee_id`, [id, title]);
  });
}

/**
 * Удаление должности — «в корзину». Занимавший ее уходит за штат: остается
 * в своем подразделении, но без должности. Командирская уходит вместе с
 * командирством.
 */
async function deletePosition(id) {
  await db.transaction(async () => {
    const { rows: [p] } = await db.query('SELECT * FROM core.positions WHERE id = $1', [id]);
    if (!p) return;
    await db.query('DELETE FROM core.positions WHERE id = $1', [id]);
    if (p.employee_id) {
      await db.query(`UPDATE personnel.employees SET position = NULL, unit_id = NULL, updated_at = now()
        WHERE id = $1`, [p.employee_id]);
      await releaseWeapons(p.employee_id);
    }
    if (p.is_commander) await syncCommander(p.unit_id, true);
  });
}

/**
 * Перенос должности в другое подразделение — вместе с тем, кто ее занимает.
 * Встает в конец штата; командирской в новом подразделении не становится.
 */
async function movePosition(id, unitId) {
  await db.transaction(async () => {
    const { rows: [p] } = await db.query('SELECT * FROM core.positions WHERE id = $1', [id]);
    await db.query(`
      UPDATE core.positions SET unit_id = $2, is_commander = false,
        sort_order = (SELECT coalesce(max(sort_order), 0) + 10 FROM core.positions WHERE unit_id = $2)
      WHERE id = $1
    `, [id, unitId]);
    if (p.employee_id) {
      await db.query('UPDATE personnel.employees SET unit_id = $2, updated_at = now() WHERE id = $1',
        [p.employee_id, unitId]);
      await releaseWeapons(p.employee_id, unitId);
    }
    if (p.is_commander) await syncCommander(p.unit_id, true);
  });
}

/**
 * Человек — за штат: должность освобождается (становится вакантной), сам он
 * остается в своем подразделении без должности. Была командирской —
 * командирство снимается.
 */
async function releaseEmployee(employeeId) {
  await db.transaction(async () => {
    const { rows } = await db.query(
      'UPDATE core.positions SET employee_id = NULL WHERE employee_id = $1 RETURNING unit_id', [employeeId]);
    await db.query(`UPDATE personnel.employees SET position = NULL, unit_id = NULL, updated_at = now()
      WHERE id = $1`, [employeeId]);
    await releaseWeapons(employeeId);
    if (rows[0]) await syncCommander(rows[0].unit_id);
  });
}

/** Порядок должностей подразделения по перечню: 10, 20, 30… */
async function setPositionOrder(unitId, ids) {
  await db.query(`
    UPDATE core.positions p SET sort_order = o.n * 10
    FROM unnest($2::int[]) WITH ORDINALITY AS o(id, n)
    WHERE p.id = o.id AND p.unit_id = $1
  `, [unitId, ids]);
}

/** За штатом: действующие люди вне всех подразделений. */
async function unplacedEmployees() {
  const { rows } = await db.query(`
    SELECT e.id,
           concat_ws(' ', e.last_name, e.first_name, e.middle_name) AS full_name,
           concat_ws(' ', r.short_name, e.last_name) AS short_name,
           r.name AS rank_name
    FROM personnel.employees e
    LEFT JOIN core.ranks r ON r.id = e.rank_id
    WHERE e.is_active AND e.unit_id IS NULL
    ORDER BY r.seniority DESC NULLS LAST, e.last_name
  `);
  return rows;
}

/** Сотрудник есть? — и его подразделение (null — за штатом). */
async function employeeRow(employeeId) {
  const { rows } = await db.query('SELECT id, unit_id FROM personnel.employees WHERE id = $1', [employeeId]);
  return rows[0] || null;
}

/**
 * Перевод: человек освобождает прежнюю должность и занимает новую; его
 * подразделение и наименование должности — по новой.
 */
async function occupyPosition(employeeId, positionId) {
  await db.transaction(async () => {
    const { rows: before } = await db.query('SELECT unit_id FROM core.positions WHERE employee_id = $1', [employeeId]);
    await db.query('UPDATE core.positions SET employee_id = NULL WHERE employee_id = $1', [employeeId]);
    const { rows } = await db.query(`
      UPDATE core.positions SET employee_id = $1 WHERE id = $2 AND employee_id IS NULL
      RETURNING unit_id, title
    `, [employeeId, positionId]);
    if (rows.length === 0) require('../../lib/validation').fail('Должность уже занята. Обновите страницу.');
    await db.query(`UPDATE personnel.employees SET unit_id = $2, position = $3, updated_at = now()
      WHERE id = $1`, [employeeId, rows[0].unit_id, rows[0].title]);
    await releaseWeapons(employeeId, rows[0].unit_id);
    // Командир следует из штата: и там, откуда ушел, и там, куда пришел.
    if (before[0]) await syncCommander(before[0].unit_id);
    await syncCommander(rows[0].unit_id);
  });
}

// ----------------------------------------------------------------------------
// ВРИО командира и подписанты приказа
// ----------------------------------------------------------------------------

const PERSON = `
  e.id, e.last_name, e.first_name, e.middle_name, e.unit_id,
  concat_ws(' ', e.last_name, e.first_name, e.middle_name) AS full_name,
  concat_ws(' ', r.short_name, e.last_name) AS short_name,
  r.name AS rank_name, r.seniority`;

/**
 * Кандидаты во ВРИО: люди подразделения и вложенных — сначала само
 * подразделение, затем ближайший вложенный уровень и глубже; на уровне —
 * по старшинству звания. Командир (занимающий командирскую) не входит.
 */
async function actingCandidates(unitId) {
  const { rows } = await db.query(`
    WITH RECURSIVE tree AS (
      SELECT id, 0 AS depth FROM core.units WHERE id = $1
      UNION ALL
      SELECT u.id, t.depth + 1 FROM core.units u JOIN tree t ON u.parent_id = t.id
    )
    SELECT ${PERSON}, t.depth, cu.short_name AS unit_short
    FROM personnel.employees e
    JOIN tree t ON t.id = e.unit_id
    JOIN core.units cu ON cu.id = e.unit_id
    LEFT JOIN core.ranks r ON r.id = e.rank_id
    WHERE e.is_active
      AND e.id IS DISTINCT FROM (SELECT p.employee_id FROM core.positions p WHERE p.unit_id = $1 AND p.is_commander)
    ORDER BY t.depth, r.seniority DESC NULLS LAST, e.last_name, e.id
  `, [unitId]);
  return rows;
}

/** Назначенные ВРИО подразделений (действующие и будущие, не отмененные). */
async function listActing(unitIds) {
  const { rows } = await db.query(`
    SELECT a.id, a.unit_id, a.employee_id, a.reason,
           to_char(a.date_from, 'YYYY-MM-DD') AS date_from, to_char(a.date_to, 'YYYY-MM-DD') AS date_to,
           concat_ws(' ', r.short_name, e.last_name) AS short_name
    FROM core.acting_commanders a
    JOIN personnel.employees e ON e.id = a.employee_id
    LEFT JOIN core.ranks r     ON r.id = e.rank_id
    WHERE a.cancelled_at IS NULL AND a.date_to >= CURRENT_DATE
      AND ($1::int[] IS NULL OR a.unit_id = ANY($1::int[]))
    ORDER BY a.unit_id, a.date_from
  `, [unitIds]);
  return rows;
}

async function createActing({ unitId, employeeId, dateFrom, dateTo, reason, userId }) {
  const { rows } = await db.query(`
    INSERT INTO core.acting_commanders (unit_id, employee_id, date_from, date_to, reason, created_by)
    VALUES ($1, $2, $3, $4, $5, $6) RETURNING id
  `, [unitId, employeeId, dateFrom, dateTo, reason || null, userId || null]);
  return rows[0].id;
}

async function getActing(id) {
  const { rows } = await db.query('SELECT * FROM core.acting_commanders WHERE id = $1', [id]);
  return rows[0] || null;
}

/** Будущие и текущие назначения ВРИО человека — отменить (исключение из списков). */
async function cancelActingOf(employeeId) {
  await db.query(`UPDATE core.acting_commanders SET cancelled_at = now()
    WHERE employee_id = $1 AND cancelled_at IS NULL AND date_to >= CURRENT_DATE`, [employeeId]);
}

async function cancelActing(id) {
  await db.query('UPDATE core.acting_commanders SET cancelled_at = now() WHERE id = $1', [id]);
}

/** Пересекается ли с уже назначенным ВРИО этого подразделения. */
async function actingOverlaps(unitId, dateFrom, dateTo) {
  const { rows } = await db.query(`
    SELECT 1 FROM core.acting_commanders
    WHERE unit_id = $1 AND cancelled_at IS NULL AND date_from <= $3 AND date_to >= $2 LIMIT 1
  `, [unitId, dateFrom, dateTo]);
  return rows.length > 0;
}

/** Назначенный ВРИО подразделения на дату. */
async function actingOn(unitId, date) {
  const { rows } = await db.query(`
    SELECT ${PERSON}
    FROM core.acting_commanders a
    JOIN personnel.employees e ON e.id = a.employee_id
    LEFT JOIN core.ranks r     ON r.id = e.rank_id
    WHERE a.unit_id = $1 AND a.cancelled_at IS NULL AND $2::date BETWEEN a.date_from AND a.date_to
    ORDER BY a.id DESC LIMIT 1
  `, [unitId, date]);
  return rows[0] || null;
}

/** Где человек — ВРИО командира на дату (для прав). */
async function actingUnitOf(employeeId, date) {
  const { rows } = await db.query(`
    SELECT unit_id FROM core.acting_commanders
    WHERE employee_id = $1 AND cancelled_at IS NULL AND $2::date BETWEEN date_from AND date_to
    ORDER BY id DESC LIMIT 1
  `, [employeeId, date]);
  return rows[0] ? rows[0].unit_id : null;
}

/** Командирская должность подразделения: наименование и занимающий. */
async function commanderPost(unitId) {
  const { rows } = await db.query(`
    SELECT p.title, ${PERSON}
    FROM core.positions p
    LEFT JOIN personnel.employees e ON e.id = p.employee_id
    LEFT JOIN core.ranks r          ON r.id = e.rank_id
    WHERE p.unit_id = $1 AND p.is_commander
  `, [unitId]);
  return rows[0] || null;
}

/** Отсутствие человека на дату (любое действующее). */
async function absentOn(employeeId, date) {
  const { rows } = await db.query(`
    SELECT 1 FROM personnel.absences
    WHERE employee_id = $1 AND cancelled_at IS NULL AND $2::date BETWEEN date_from AND date_to LIMIT 1
  `, [employeeId, date]);
  return rows.length > 0;
}

/** Ближайшее (текущее или будущее) отсутствие — даты ВРИО по умолчанию. */
async function nextAbsence(employeeId) {
  const { rows } = await db.query(`
    SELECT to_char(date_from, 'YYYY-MM-DD') AS date_from,
           CASE WHEN date_to = 'infinity' THEN 'infinity' ELSE to_char(date_to, 'YYYY-MM-DD') END AS date_to
    FROM personnel.absences
    WHERE employee_id = $1 AND cancelled_at IS NULL AND date_to >= CURRENT_DATE
    ORDER BY date_from LIMIT 1
  `, [employeeId]);
  return rows[0] || null;
}

async function rootUnitRow() {
  const { rows } = await db.query('SELECT id, name FROM core.units WHERE parent_id IS NULL AND is_active ORDER BY id LIMIT 1');
  return rows[0] || null;
}

async function headquartersRow() {
  const { rows } = await db.query('SELECT id, name FROM core.units WHERE is_headquarters LIMIT 1');
  return rows[0] || null;
}

module.exports = {
  actingCandidates,
  listActing,
  createActing,
  getActing,
  cancelActing,
  cancelActingOf,
  actingOverlaps,
  actingOn,
  actingUnitOf,
  commanderPost,
  absentOn,
  nextAbsence,
  rootUnitRow,
  headquartersRow,
  listPositions,
  getPosition,
  positionOf,
  createPosition,
  renamePosition,
  deletePosition,
  occupyPosition,
  movePosition,
  releaseEmployee,
  setPositionOrder,
  unplacedEmployees,
  employeeRow,
  syncCommander,
  setCommanderPosition,
  clearCommanderPosition,
  hasCommanderPosition,
  subtreeIds,
  path,
  listUnits,
  getUnit,
  createUnit,
  updateUnit,
  usage,
  deleteUnit,
  childIds,
  setChildOrder,
  employeeUnit,
  employeesIn,
};
