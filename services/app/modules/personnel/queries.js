'use strict';

// SQL-запросы модуля «Личный состав».
// Обращаться сюда напрямую вправе только personnel/service.js.

const db = require('../../db/pool');

const EMPLOYEE_FIELDS = `
    e.id,
    e.last_name,
    e.first_name,
    e.middle_name,
    e.position,
    e.personnel_number,
    r.short_name AS rank_short,
    r.name       AS rank_name,
    r.seniority,
    e.rank_id,
    e.unit_id,
    u.short_name AS unit_short,
    e.phone, e.is_active,
    to_char(e.excluded_on, 'YYYY-MM-DD') AS excluded_on, e.exclusion_reason
`;

const EMPLOYEE_JOINS = `
    FROM personnel.employees e
    LEFT JOIN core.ranks r ON r.id = e.rank_id
    LEFT JOIN core.units u ON u.id = e.unit_id  -- за штатом — без подразделения
`;

// Отсутствие, блокирующее привлечение, на указанную дату.
const ABSENT_ON_DATE = `
    EXISTS (
        SELECT 1
        FROM personnel.absences a
        JOIN personnel.absence_types t ON t.id = a.absence_type_id
        WHERE a.employee_id = e.id
          AND t.blocks_duty
          AND a.cancelled_at IS NULL
          AND $1::date BETWEEN a.date_from AND a.date_to
    )
`;

async function countActive(unitIds = null) {
  const { rows } = await db.query(
    'SELECT count(*)::int AS n FROM personnel.employees WHERE is_active AND ($1::int[] IS NULL OR unit_id = ANY($1))',
    [unitIds],
  );
  return rows[0].n;
}

async function listEmployees() {
  const { rows } = await db.query(`
    SELECT ${EMPLOYEE_FIELDS} ${EMPLOYEE_JOINS}
    WHERE e.is_active
    ORDER BY r.seniority DESC NULLS LAST, e.last_name
  `);
  return rows;
}

async function listByIds(ids) {
  if (ids.length === 0) return [];
  const { rows } = await db.query(`
    SELECT ${EMPLOYEE_FIELDS} ${EMPLOYEE_JOINS}
    WHERE e.id = ANY($1::int[])
    ORDER BY r.seniority DESC NULLS LAST, e.last_name
  `, [ids]);
  return rows;
}

/**
 * Условия наличия действующих ОБЩИХ допусков.
 * Общий допуск к посту не привязан, поэтому post_id у него пуст.
 *
 * Действие проверяется НА ДАТУ ЗАСТУПЛЕНИЯ ($1), а не на сегодня. Наряды
 * назначаются на месяц вперед, и человек, у которого допуск истекает через
 * неделю, кандидатом на конец месяца быть не должен: обнаружилось бы это в
 * день заступления, когда заменять уже некем.
 */
function generalPermitConditions(permitTypeIds, params) {
  return permitTypeIds.map((permitTypeId) => {
    params.push(permitTypeId);
    return `
      AND EXISTS (
          SELECT 1 FROM personnel.employee_permits p
          WHERE p.employee_id = e.id
            AND p.permit_type_id = $${params.length}
            AND p.post_id IS NULL
            AND personnel.permit_is_valid(p, $1::date)
      )`;
  }).join('\n');
}

/**
 * Сотрудники, доступные к привлечению на дату и имеющие все общие допуски.
 * Постовой допуск здесь не проверяется.
 */
async function findAvailable({ onDate, generalPermitTypeIds }) {
  const params = [onDate];
  const conditions = generalPermitConditions(generalPermitTypeIds, params);

  const { rows } = await db.query(`
    SELECT ${EMPLOYEE_FIELDS} ${EMPLOYEE_JOINS}
    WHERE e.is_active AND e.unit_id IS NOT NULL
      AND NOT ${ABSENT_ON_DATE}
      ${conditions}
    ORDER BY r.seniority DESC NULLS LAST, e.last_name
  `, params);

  return rows;
}

/**
 * Кандидаты по каждому посту одним запросом.
 *
 * Возвращает строки «пост — сотрудник»: сотрудник попадает в строку для того
 * поста, к которому у него есть действующий постовой допуск. Один сотрудник
 * может оказаться кандидатом сразу на несколько постов.
 *
 * Идентификаторы постов приходят из модуля «Наряды» и используются здесь как
 * непрозрачные значения: соединения с таблицами схемы duty нет, поэтому
 * граница между модулями сохраняется.
 *
 * Один запрос вместо запроса на каждый пост: постов у наряда бывает
 * несколько десятков.
 */
async function findCandidatesForPosts({ onDate, generalPermitTypeIds, posts, startsAt, endsAt }) {
  if (!posts.length) return [];
  const params=[onDate, posts.map(p=>p.id), posts.map(p=>p.required_permit_type_id),
    posts.map(p=>p.required_weapon_kind), startsAt, endsAt];
  const conditions=generalPermitConditions(generalPermitTypeIds,params);
  const {rows}=await db.query(`
    SELECT pp.post_id, ${EMPLOYEE_FIELDS} ${EMPLOYEE_JOINS}
    CROSS JOIN unnest($2::int[],$3::int[],$4::text[]) pp(post_id,required_permit,weapon_kind)
    WHERE e.is_active AND e.unit_id IS NOT NULL
    AND NOT EXISTS (SELECT 1 FROM personnel.absences a
      JOIN personnel.absence_types t ON t.id=a.absence_type_id
      WHERE a.employee_id=e.id AND t.blocks_duty AND a.cancelled_at IS NULL
      AND a.date_from::timestamp<$6::timestamptz AND (a.date_to+1)::timestamp>$5::timestamptz)
    AND (pp.required_permit IS NULL OR EXISTS (SELECT 1 FROM personnel.employee_permits p
      WHERE p.employee_id=e.id AND p.permit_type_id=pp.required_permit AND p.post_id IS NULL
      AND personnel.permit_is_valid(p,$1::date)))
    ${conditions}
    ORDER BY pp.post_id,r.seniority DESC,e.last_name`,params);
  return rows;
}

/** Сотрудники, отсутствующие на указанную дату, с указанием причины. */
async function listAbsentOn(onDate) {
  const { rows } = await db.query(`
    SELECT e.id, e.last_name, e.first_name, e.middle_name,
           t.name AS reason, a.date_from, a.date_to
    FROM personnel.absences a
    JOIN personnel.absence_types t ON t.id = a.absence_type_id
    JOIN personnel.employees e     ON e.id = a.employee_id
    WHERE a.cancelled_at IS NULL
      AND $1::date BETWEEN a.date_from AND a.date_to
    ORDER BY e.last_name
  `, [onDate]);
  return rows;
}

/**
 * Запись об отсутствии.
 *
 * Категория указывается кодом, а не идентификатором: перечень категорий
 * закрыт (раздел 9.1), и вызывающая сторона не должна знать его нумерацию.
 */
async function addAbsence({ employeeId, typeCode, dateFrom, dateTo, documentRef, note,
  createdBy, source, orderId }) {
  const { rows } = await db.query(`
    INSERT INTO personnel.absences
        (employee_id, absence_type_id, date_from, date_to, document_ref, note, created_by, source, order_id)
    SELECT $1, t.id, $3::date, $4::date, $5, $6, $7, $8, $9
    FROM personnel.absence_types t
    WHERE t.code = $2
    RETURNING id
  `, [employeeId, typeCode, dateFrom, dateTo, documentRef || null, note || null,
    createdBy || null, source || 'manual', orderId || null]);

  if (rows.length === 0) throw new Error(`Категория отсутствия не найдена: ${typeCode}`);
  return rows[0].id;
}

/**
 * Действующие записи об отсутствии на дату — по одной на человека.
 *
 * Если записей на дату несколько (отпуск продлен вдогонку, наложилась
 * командировка), берется начавшаяся позже: она и есть последнее основание.
 */
async function listAbsencesOnDate(onDate) {
  const { rows } = await db.query(`
    SELECT DISTINCT ON (a.employee_id)
           a.id, a.employee_id, t.code, t.name AS reason,
           to_char(a.date_from, 'YYYY-MM-DD') AS date_from,
           CASE WHEN a.date_to = 'infinity' THEN 'infinity' ELSE to_char(a.date_to, 'YYYY-MM-DD') END AS date_to,
           a.document_ref, a.note, a.source
    FROM personnel.absences a
    JOIN personnel.absence_types t ON t.id = a.absence_type_id
    WHERE a.cancelled_at IS NULL
      AND $1::date BETWEEN a.date_from AND a.date_to
    ORDER BY a.employee_id, a.date_from DESC, a.id DESC
  `, [onDate]);
  return rows;
}

/** Запись об отсутствии вместе с человеком — для проверки прав и снятия. */
async function getAbsence(id) {
  const { rows } = await db.query(`
    SELECT a.id, a.employee_id, a.source, a.cancelled_at, e.unit_id,
           to_char(a.date_from, 'YYYY-MM-DD') AS date_from,
           CASE WHEN a.date_to = 'infinity' THEN 'infinity' ELSE to_char(a.date_to, 'YYYY-MM-DD') END AS date_to,
           t.name AS reason
    FROM personnel.absences a
    JOIN personnel.absence_types t ON t.id = a.absence_type_id
    JOIN personnel.employees e     ON e.id = a.employee_id
    WHERE a.id = $1
  `, [id]);
  return rows[0] || null;
}

/** Снятие записи пометкой: основание сохраняется, из расчета уходит. */
async function cancelAbsence(id, userId) {
  const { rowCount } = await db.query(`
    UPDATE personnel.absences
       SET cancelled_at = now(), cancelled_by = $2
     WHERE id = $1 AND cancelled_at IS NULL
  `, [id, userId || null]);
  return rowCount;
}

/** Завершить бессрочное отсутствие: указать дату окончания. */
async function setAbsenceEnd(id, dateTo) {
  const { rowCount } = await db.query(`UPDATE personnel.absences SET date_to = $2::date
    WHERE id = $1 AND cancelled_at IS NULL`, [id, dateTo]);
  return rowCount;
}

/** Пересекающиеся по датам действующие записи того же человека. */
async function overlappingAbsences(employeeId, dateFrom, dateTo) {
  const { rows } = await db.query(`
    SELECT a.id, t.name AS reason,
           to_char(a.date_from, 'YYYY-MM-DD') AS date_from,
           CASE WHEN a.date_to = 'infinity' THEN 'infinity' ELSE to_char(a.date_to, 'YYYY-MM-DD') END AS date_to
    FROM personnel.absences a
    JOIN personnel.absence_types t ON t.id = a.absence_type_id
    WHERE a.employee_id = $1
      AND a.cancelled_at IS NULL
      AND a.date_from <= $3::date
      AND a.date_to   >= $2::date
    ORDER BY a.date_from
  `, [employeeId, dateFrom, dateTo]);
  return rows;
}

/** Справочник категорий отсутствия. */
async function listAbsenceTypes() {
  const { rows } = await db.query(`
    SELECT id, code, name, blocks_duty
    FROM personnel.absence_types
    ORDER BY sort_order, name
  `);
  return rows;
}

/**
 * Проверка уже назначенных: кто из них НЕ пригоден к своему посту на дату
 * заступления.
 *
 * Отбор кандидатов проверяет человека в момент назначения, но условия
 * меняются позже: истекает допуск, человек уходит в отпуск, допуск
 * приостанавливают. Назначение при этом остается, и наряд выглядит
 * укомплектованным. Проверять приходится повторно.
 *
 * Действие допуска проверяется НА ДАТУ ЗАСТУПЛЕНИЯ, а не на сегодня, поэтому
 * представление v_valid_permits здесь не годится: оно привязано к текущей
 * дате и для наряда через две недели дало бы неверный ответ.
 *
 * @param {Array<{employeeId:number, postId:number, onDate:string}>} items
 * @param {number[]} generalPermitTypeIds  общие допуски, обязательные для поста
 * @returns {Array<{employee_id, post_id, on_date, reason}>}
 */
async function findUnfitAssignments(items, generalPermitTypeIds) {
 if (!items.length) return [];
 const {rows}=await db.query(`
 WITH a AS (SELECT * FROM unnest($1::int[],$2::int[],$3::date[],$4::int[],$5::text[],$6::timestamptz[],$7::timestamptz[])
   AS x(employee_id,post_id,on_date,required_permit,weapon_kind,starts_at,ends_at))
 SELECT a.employee_id,a.post_id,to_char(a.on_date,'YYYY-MM-DD') AS on_date,reason
 FROM a CROSS JOIN LATERAL (
   SELECT 'inactive' AS reason WHERE NOT EXISTS(SELECT 1 FROM personnel.employees e WHERE e.id=a.employee_id AND e.is_active)
   UNION ALL SELECT 'absent' WHERE EXISTS(SELECT 1 FROM personnel.absences ab
     JOIN personnel.absence_types t ON t.id=ab.absence_type_id WHERE ab.employee_id=a.employee_id AND t.blocks_duty
     AND ab.cancelled_at IS NULL
     AND ab.date_from::timestamp<a.ends_at AND (ab.date_to+1)::timestamp>a.starts_at)
   UNION ALL SELECT 'post_permit' WHERE a.required_permit IS NOT NULL AND NOT EXISTS(
     SELECT 1 FROM personnel.employee_permits p WHERE p.employee_id=a.employee_id
     AND p.permit_type_id=a.required_permit AND p.post_id IS NULL AND personnel.permit_is_valid(p,a.on_date))
   UNION ALL SELECT 'general_permit' WHERE EXISTS(SELECT pt FROM unnest($8::int[]) pt WHERE NOT EXISTS(
     SELECT 1 FROM personnel.employee_permits p WHERE p.employee_id=a.employee_id
     AND p.permit_type_id=pt AND p.post_id IS NULL AND personnel.permit_is_valid(p,a.on_date)))
 ) problems`,[items.map(i=>i.employeeId),items.map(i=>i.postId),items.map(i=>i.onDate),
 items.map(i=>i.requiredPermit),items.map(i=>i.weaponKind),items.map(i=>i.startsAt),items.map(i=>i.endsAt),generalPermitTypeIds||[]]);
 return rows;
}

/** Отсутствия сотрудника, пересекающиеся с периодом. */
async function listAbsencesFor(employeeId, from, to) {
  const { rows } = await db.query(`
    SELECT a.id, t.code, t.name AS reason,
           to_char(a.date_from, 'YYYY-MM-DD') AS date_from,
           CASE WHEN a.date_to = 'infinity' THEN 'infinity' ELSE to_char(a.date_to, 'YYYY-MM-DD') END AS date_to,
           a.document_ref, a.note, a.source
    FROM personnel.absences a
    JOIN personnel.absence_types t ON t.id = a.absence_type_id
    WHERE a.employee_id = $1
      AND a.cancelled_at IS NULL
      AND a.date_from <= $3::date
      AND a.date_to   >= $2::date
    ORDER BY a.date_from
  `, [employeeId, from, to]);
  return rows;
}

/**
 * Допуски одного человека — все, включая истекшие и приостановленные.
 *
 * Карточке нужны и недействующие: «допуска нет» и «допуск был и кончился» —
 * разные основания, и по второму видно, что оформлять заново, а не с нуля.
 */
async function listPermitsFor(employeeId, onDate) {
  const { rows } = await db.query(`
    SELECT ep.id, ep.permit_type_id, ep.post_id, ep.status, ep.order_id,
           t.code, t.name,
           o.number AS order_number,
           to_char(o.issued_on, 'YYYY-MM-DD') AS order_date,
           o.pdf_path IS NOT NULL AS order_has_pdf,
           to_char(ep.issued_at,  'YYYY-MM-DD') AS issued_at,
           to_char(ep.expires_at, 'YYYY-MM-DD') AS expires_at,
           ep.document_ref,
           personnel.permit_is_valid(ep, $2::date) AS valid
    FROM personnel.employee_permits ep
    JOIN personnel.permit_types t          ON t.id = ep.permit_type_id
    LEFT JOIN personnel.permit_orders o    ON o.id = ep.order_id
    WHERE ep.employee_id = $1
    ORDER BY t.name
  `, [employeeId, onDate]);
  return rows;
}

async function listPermitTypes() {
 return (await db.query("SELECT id,name FROM personnel.permit_types WHERE NOT is_post_specific ORDER BY name")).rows;
}

/**
 * ВСЕ виды допуска, включая привязанные к посту.
 *
 * Приказ допускает и к посту тоже, поэтому при выдаче по приказу перечень
 * шире того, что предлагается в справочнике постов.
 */
async function listAllPermitTypes() {
  const { rows } = await db.query(`
    SELECT id, code, name, is_post_specific, default_validity_months
    FROM personnel.permit_types
    WHERE is_active
    ORDER BY is_post_specific, name
  `);
  return rows;
}
async function listWeapons() {
 return (await db.query(`SELECT w.*, e.last_name AS owner_name,
   (SELECT json_agg(json_build_object('employee',concat_ws(' ',pr.short_name,p.last_name),'from',l.starts_at,'to',l.ends_at,'reason',l.reason,'duty',l.duty_id) ORDER BY l.starts_at)
    FROM personnel.v_weapon_loans l JOIN personnel.employees p ON p.id=l.employee_id
    LEFT JOIN core.ranks pr ON pr.id=p.rank_id
    WHERE l.weapon_id=w.id AND l.ends_at>now()) AS loans
 FROM personnel.weapons w LEFT JOIN personnel.employees e ON e.id=w.owner_id ORDER BY w.id`)).rows;
}
async function createWeapon(data) {
 const {rows}=await db.query(`INSERT INTO personnel.weapons(name,serial_number,manufactured_on,kind,owner_id,unit_id,sort_order)
 VALUES($1,$2,$3,$4,$5,$6,(SELECT coalesce(max(sort_order),0)+10 FROM personnel.weapons WHERE unit_id IS NOT DISTINCT FROM $6::int))
 RETURNING id`,[data.name,data.serialNumber,data.manufacturedOn,data.kind,data.ownerId||null,data.unitId||null]);
 return rows[0].id;
}
/**
 * Оружие человека: закрепленное за ним и переданное во временное пользование.
 *
 * Показываются ДВЕ стороны: что у него на руках (свое и полученное) и что из
 * его закрепленного оружия сейчас у другого. Иначе владелец видит оружие
 * «своим», не зная, что оно выдано в наряд.
 */
async function weaponsOfEmployee(employeeId) {
  const { rows } = await db.query(`
    SELECT w.id, w.name, w.serial_number, w.kind, w.is_active, w.owner_id,
           to_char(w.manufactured_on, 'YYYY-MM-DD') AS manufactured_on,
           (w.owner_id = $1) AS own,
           (w.holder_id = $1) AS held,
           l.id AS loan_id,
           l.employee_id AS loan_to,
           to_char(l.starts_at, 'YYYY-MM-DD HH24:MI') AS loan_from,
           to_char(l.ends_at,   'YYYY-MM-DD HH24:MI') AS loan_to_at,
           l.reason AS loan_reason,
           l.duty_id,
           concat_ws(' ', r.short_name, e.last_name) AS loan_holder
    FROM personnel.v_weapons w
    LEFT JOIN LATERAL (
      SELECT * FROM personnel.v_weapon_loans x
      WHERE x.weapon_id = w.id AND x.ends_at > now()
      ORDER BY x.starts_at LIMIT 1
    ) l ON true
    LEFT JOIN personnel.employees e ON e.id = l.employee_id
    LEFT JOIN core.ranks r          ON r.id = e.rank_id
    WHERE w.is_active AND (w.holder_id = $1 OR l.employee_id = $1)
    ORDER BY (w.owner_id = $1) DESC, (w.holder_id = $1) DESC, w.name
  `, [employeeId]);
  return rows;
}

/** Оружие, ни за кем не закрепленное, — из него и выбирают при закреплении. */
async function freeWeapons() {
  const { rows } = await db.query(`
    SELECT id, name, serial_number, kind
    FROM personnel.weapons
    WHERE is_active AND owner_id IS NULL
    ORDER BY kind, name, serial_number
  `);
  return rows;
}

async function getWeapon(id) {
  const { rows } = await db.query('SELECT * FROM personnel.weapons WHERE id = $1', [id]);
  return rows[0] || null;
}

/** Постоянное закрепление оружия; employeeId = null снимает его. */
async function setWeaponOwner(weaponId, employeeId) {
  const { rowCount } = await db.query(
    'UPDATE personnel.weapons SET owner_id = $2 WHERE id = $1', [weaponId, employeeId],
  );
  return rowCount;
}

/** Действующие и будущие передачи этого оружия. */
async function weaponLoans(weaponId) {
  const { rows } = await db.query(`
    SELECT l.id, l.employee_id, l.duty_id, l.reason,
           to_char(l.starts_at, 'YYYY-MM-DD HH24:MI') AS starts_at,
           to_char(l.ends_at,   'YYYY-MM-DD HH24:MI') AS ends_at
    FROM personnel.v_weapon_loans l
    WHERE l.weapon_id = $1 AND l.ends_at > now()
    ORDER BY l.starts_at
  `, [weaponId]);
  return rows;
}

// ----------------------------------------------------------------------------
// Прием, правка, исключение из списков
// ----------------------------------------------------------------------------

/** Новый человек — за штатом (без подразделения); на должность — переводом. */
async function createEmployee({ lastName, firstName, middleName, rankId, personnelNumber, phone }) {
  const { rows } = await db.query(`
    INSERT INTO personnel.employees (last_name, first_name, middle_name, rank_id, personnel_number, phone, unit_id)
    VALUES ($1, $2, $3, $4, $5, $6, NULL) RETURNING id
  `, [lastName, firstName, middleName || null, rankId || null, personnelNumber || null, phone || null]);
  return rows[0].id;
}

async function updateEmployeeData(id, { lastName, firstName, middleName, rankId, personnelNumber, phone }) {
  await db.query(`
    UPDATE personnel.employees
       SET last_name = $2, first_name = $3, middle_name = $4, rank_id = $5,
           personnel_number = $6, phone = $7, updated_at = now()
     WHERE id = $1
  `, [id, lastName, firstName, middleName || null, rankId || null, personnelNumber || null, phone || null]);
}

async function personnelNumberTaken(number, exceptId) {
  const { rows } = await db.query(
    'SELECT 1 FROM personnel.employees WHERE personnel_number = $1 AND id IS DISTINCT FROM $2', [number, exceptId || null]);
  return rows.length > 0;
}

async function setExcluded(id, reason) {
  await db.query(`UPDATE personnel.employees SET is_active = false, unit_id = NULL, position = NULL,
    excluded_on = CURRENT_DATE, exclusion_reason = $2, updated_at = now() WHERE id = $1`, [id, reason]);
}

/** Возврат в списки — за штатом. */
async function setRestored(id) {
  await db.query(`UPDATE personnel.employees SET is_active = true, unit_id = NULL,
    excluded_on = NULL, exclusion_reason = NULL, updated_at = now() WHERE id = $1`, [id]);
}

/** Исключенные из списков — для кадровика. */
async function listExcluded() {
  const { rows } = await db.query(`
    SELECT e.id, concat_ws(' ', e.last_name, e.first_name, e.middle_name) AS full_name,
           r.name AS rank_name, to_char(e.excluded_on, 'YYYY-MM-DD') AS excluded_on, e.exclusion_reason
    FROM personnel.employees e LEFT JOIN core.ranks r ON r.id = e.rank_id
    WHERE NOT e.is_active
    ORDER BY e.excluded_on DESC NULLS LAST, e.last_name
  `);
  return rows;
}

/** Справочник званий — для настройки весов на постах. */
async function listRanks() {
  const { rows } = await db.query(
    'SELECT id, name, short_name, seniority FROM core.ranks WHERE is_active ORDER BY seniority',
  );
  return rows;
}


// ----------------------------------------------------------------------------
// Приказы на допуск
//
// Каталог — дерево направлений; годы в нем не хранятся, а выводятся из даты
// издания приказа (раздел 7.3).
// ----------------------------------------------------------------------------

async function listDirections() {
  const { rows } = await db.query(`
    SELECT d.id, d.parent_id, d.name, d.sort_order, d.is_active,
           (SELECT count(*)::int FROM personnel.permit_orders o WHERE o.direction_id = d.id) AS orders
    FROM personnel.permit_directions d
    ORDER BY d.sort_order, d.name
  `);
  return rows;
}

async function createDirection({ parentId, name, sortOrder }) {
  const { rows } = await db.query(`
    INSERT INTO personnel.permit_directions (parent_id, name, sort_order)
    VALUES ($1, $2,
            -- Новое — в конец перечня; порядок потом перетаскивается.
            COALESCE($3, (SELECT coalesce(max(sort_order), 0) + 10
                          FROM personnel.permit_directions)))
    RETURNING id
  `, [parentId || null, name, sortOrder ?? null]);
  return rows[0].id;
}

async function updateDirection(id, { name, sortOrder, isActive }) {
  await db.query(`
    UPDATE personnel.permit_directions
       SET name = $2, sort_order = COALESCE($3, sort_order), is_active = $4
     WHERE id = $1
  `, [id, name, sortOrder ?? null, isActive]);
}

async function directionIds() {
  const { rows } = await db.query('SELECT id FROM personnel.permit_directions');
  return rows.map((r) => r.id);
}

/** Направления одного уровня (вложенные в parentId; null — верхние). */
async function directionIdsWithin(parentId) {
  const { rows } = await db.query(
    'SELECT id FROM personnel.permit_directions WHERE parent_id IS NOT DISTINCT FROM $1', [parentId]);
  return rows.map((r) => r.id);
}

/** Порядок направлений одного уровня по перечню: 10, 20, 30… */
async function setDirectionOrder(parentId, ids) {
  await db.query(`
    UPDATE personnel.permit_directions d SET sort_order = o.n * 10
    FROM unnest($2::int[]) WITH ORDINALITY AS o(id, n)
    WHERE d.id = o.id AND d.parent_id IS NOT DISTINCT FROM $1
  `, [parentId, ids]);
}

async function directionUsage(id) {
  const { rows } = await db.query(`
    SELECT (SELECT count(*)::int FROM personnel.permit_orders o WHERE o.direction_id = $1) AS orders,
           (SELECT count(*)::int FROM personnel.permit_directions d WHERE d.parent_id = $1) AS children
  `, [id]);
  return rows[0];
}

async function deleteDirection(id) {
  await db.query('DELETE FROM personnel.permit_directions WHERE id = $1', [id]);
}

const ORDER_FIELDS = `
    o.id, o.direction_id, o.kind, o.number, o.title, o.note, o.source,
    to_char(o.issued_on, 'YYYY-MM-DD') AS issued_on,
    extract(year FROM o.issued_on)::int AS year,
    o.file_name, o.file_path, o.file_mime, o.file_size, o.pdf_path, o.pdf_error,
    to_char(o.parsed_at, 'YYYY-MM-DD HH24:MI') AS parsed_at
`;

/** Приказы с числом допусков, выданных по каждому. */
async function listOrders(directionId) {
  const { rows } = await db.query(`
    SELECT ${ORDER_FIELDS},
           (SELECT count(*)::int FROM personnel.employee_permits p WHERE p.order_id = o.id) AS permits
    FROM personnel.permit_orders o
    WHERE o.kind = 'permit' AND ($1::int IS NULL OR o.direction_id = $1)
    ORDER BY o.issued_on DESC, o.number
  `, [directionId || null]);
  return rows;
}

async function getOrder(id) {
  const { rows } = await db.query(`
    SELECT ${ORDER_FIELDS}, d.name AS direction_name, o.profile_id, pr.name AS profile_name,
           (SELECT count(*)::int FROM personnel.weapon_reservations r WHERE r.order_id = o.id AND r.cancelled_at IS NULL) AS reservations,
           (SELECT count(*)::int FROM personnel.employee_permits p WHERE p.order_id = o.id) AS permits,
           (SELECT count(*)::int FROM personnel.absences a WHERE a.order_id = o.id AND a.cancelled_at IS NULL) AS absences
    FROM personnel.permit_orders o
    LEFT JOIN personnel.permit_directions d ON d.id = o.direction_id
    LEFT JOIN parse.profiles pr ON pr.id = o.profile_id
    WHERE o.id = $1
  `, [id]);
  return rows[0] || null;
}

async function createOrder(data) {
  const { rows } = await db.query(`
    INSERT INTO personnel.permit_orders
        (direction_id, number, issued_on, title, note, source, created_by,
         file_name, file_path, file_mime, file_size, pdf_path, pdf_error, kind, profile_id)
    VALUES ($1, $2, $3::date, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15)
    RETURNING id
  `, [data.directionId || null, data.number, data.issuedOn, data.title || null, data.note || null,
    data.source || 'manual', data.userId || null,
    data.file ? data.file.fileName : null,
    data.file ? data.file.filePath : null,
    data.file ? data.file.mime : null,
    data.file ? data.file.size : null,
    data.file ? data.file.pdfPath : null,
    data.file ? data.file.pdfError : null,
    data.kind || 'permit', data.profileId || null]);
  return rows[0].id;
}

/** Приказы об отсутствии — с числом отмеченных по каждому. */
async function listAbsenceOrders() {
  const { rows } = await db.query(`
    SELECT ${ORDER_FIELDS},
           (SELECT count(*)::int FROM personnel.absences a WHERE a.order_id = o.id AND a.cancelled_at IS NULL) AS absences
    FROM personnel.permit_orders o
    WHERE o.kind = 'absence'
    ORDER BY o.issued_on DESC, o.number
  `);
  return rows;
}

/** Отсутствия, отмеченные по приказу. */
async function orderAbsences(orderId) {
  const { rows } = await db.query(`
    SELECT a.id, a.employee_id, e.unit_id, t.name AS reason,
           to_char(a.date_from, 'YYYY-MM-DD') AS date_from,
           CASE WHEN a.date_to = 'infinity' THEN 'infinity' ELSE to_char(a.date_to, 'YYYY-MM-DD') END AS date_to,
           concat_ws(' ', r.short_name, e.last_name, e.first_name, e.middle_name) AS person
    FROM personnel.absences a
    JOIN personnel.absence_types t ON t.id = a.absence_type_id
    JOIN personnel.employees e     ON e.id = a.employee_id
    LEFT JOIN core.ranks r         ON r.id = e.rank_id
    WHERE a.order_id = $1 AND a.cancelled_at IS NULL
    ORDER BY e.last_name
  `, [orderId]);
  return rows;
}

async function updateOrder(id, data) {
  await db.query(`
    UPDATE personnel.permit_orders
       SET direction_id = $2, number = $3, issued_on = $4::date, title = $5, note = $6
     WHERE id = $1
  `, [id, data.directionId, data.number, data.issuedOn, data.title || null, data.note || null]);
}

async function setOrderFile(id, file) {
  await db.query(`
    UPDATE personnel.permit_orders
       SET file_name = $2, file_path = $3, file_mime = $4, file_size = $5,
           pdf_path = $6, pdf_error = $7
     WHERE id = $1
  `, [id, file.fileName, file.filePath, file.mime, file.size, file.pdfPath, file.pdfError]);
}

async function deleteOrder(id) {
  await db.query('DELETE FROM personnel.permit_orders WHERE id = $1', [id]);
}

/** Кого допустил приказ: поименно, с видом допуска. */
async function orderPermits(orderId) {
  const { rows } = await db.query(`
    SELECT p.id, p.employee_id, p.permit_type_id, t.name AS permit_name, t.code AS permit_code,
           to_char(p.issued_at, 'YYYY-MM-DD') AS issued_at,
           to_char(p.expires_at, 'YYYY-MM-DD') AS expires_at,
           p.status, e.unit_id, e.last_name, e.first_name, e.middle_name,
           concat_ws(' ', e.last_name, e.first_name, e.middle_name) AS full_name,
           r.short_name AS rank_short, u.short_name AS unit_short
    FROM personnel.employee_permits p
    JOIN personnel.permit_types t  ON t.id = p.permit_type_id
    JOIN personnel.employees e     ON e.id = p.employee_id
    LEFT JOIN core.ranks r         ON r.id = e.rank_id
    LEFT JOIN core.units u         ON u.id = e.unit_id
    WHERE p.order_id = $1
    ORDER BY r.seniority DESC NULLS LAST, e.last_name
  `, [orderId]);
  return rows;
}

/** Выдача допуска человеку по приказу. */
async function grantPermit({ employeeId, permitTypeId, orderId, issuedAt, expiresAt, note }) {
  const { rows } = await db.query(`
    INSERT INTO personnel.employee_permits
        (employee_id, permit_type_id, order_id, issued_at, expires_at, status, document_ref, note)
    SELECT $1, $2, $3, $4::date, $5::date, 'active',
           concat('№ ', o.number, ' от ', to_char(o.issued_on, 'DD.MM.YYYY')), $6
    FROM personnel.permit_orders o WHERE o.id = $3
    RETURNING id
  `, [employeeId, permitTypeId, orderId, issuedAt, expiresAt || null, note || null]);
  return rows[0] ? rows[0].id : null;
}

async function revokePermit(id, status) {
  const { rowCount } = await db.query(
    'UPDATE personnel.employee_permits SET status = $2, updated_at = now() WHERE id = $1',
    [id, status],
  );
  return rowCount;
}

async function getPermit(id) {
  const { rows } = await db.query(`
    SELECT p.id, p.employee_id, p.permit_type_id, p.order_id, p.status, e.unit_id
    FROM personnel.employee_permits p
    JOIN personnel.employees e ON e.id = p.employee_id
    WHERE p.id = $1
  `, [id]);
  return rows[0] || null;
}

// ----------------------------------------------------------------------------
// Оружие по подразделениям
// ----------------------------------------------------------------------------

const WEAPON_ROW = `
  w.id, w.name, w.serial_number, w.kind, w.unit_id, w.owner_id, w.holder_id, w.sort_order, w.is_active,
  to_char(w.manufactured_on, 'YYYY-MM-DD') AS manufactured_on,
  extract(year FROM w.manufactured_on)::int AS year,
  concat_ws(' ', ro.short_name, o.last_name, o.first_name) AS owner_name,
  concat_ws(' ', rh.short_name, h.last_name) AS holder_name,
  (SELECT concat_ws(' ', rr.reason, 'с ' || to_char(rr.date_from, 'DD.MM.YYYY'), 'по ' || to_char(rr.date_to, 'DD.MM.YYYY'))
     FROM personnel.weapon_reservations rr
    WHERE rr.weapon_id = w.id AND rr.cancelled_at IS NULL AND rr.date_to >= CURRENT_DATE
    ORDER BY rr.date_from LIMIT 1) AS reserved`;
const WEAPON_JOINS = `
  FROM personnel.v_weapons w
  LEFT JOIN personnel.employees o ON o.id = w.owner_id
  LEFT JOIN core.ranks ro         ON ro.id = o.rank_id
  LEFT JOIN personnel.employees h ON h.id = w.holder_id
  LEFT JOIN core.ranks rh         ON rh.id = h.rank_id`;

/** Действующее оружие подразделений (null — всех). */
async function weaponsInUnits(unitIds) {
  const { rows } = await db.query(`
    SELECT ${WEAPON_ROW} ${WEAPON_JOINS}
    WHERE w.is_active AND w.unit_id IS NOT NULL AND ($1::int[] IS NULL OR w.unit_id = ANY($1::int[]))
    ORDER BY w.unit_id, w.sort_order, w.id
  `, [unitIds]);
  return rows;
}

/** Свободное оружие — вне подразделений (склад). */
async function weaponsInStock() {
  const { rows } = await db.query(`
    SELECT ${WEAPON_ROW} ${WEAPON_JOINS}
    WHERE w.is_active AND w.unit_id IS NULL
    ORDER BY w.kind, w.name, w.serial_number
  `);
  return rows;
}

async function getWeaponRow(id) {
  const { rows } = await db.query(`SELECT ${WEAPON_ROW} ${WEAPON_JOINS} WHERE w.id = $1`, [id]);
  return rows[0] || null;
}

/** В другое подразделение (null — на склад): закрепление снимается, в конец списка. */
async function moveWeapon(id, unitId) {
  await db.query(`
    UPDATE personnel.weapons SET unit_id = $2, owner_id = NULL,
      sort_order = (SELECT coalesce(max(sort_order), 0) + 10 FROM personnel.weapons
                    WHERE unit_id IS NOT DISTINCT FROM $2::int)
    WHERE id = $1
  `, [id, unitId]);
}

async function setWeaponOrder(unitId, ids) {
  await db.query(`
    UPDATE personnel.weapons w SET sort_order = o.n * 10
    FROM unnest($2::int[]) WITH ORDINALITY AS o(id, n)
    WHERE w.id = o.id AND w.unit_id = $1
  `, [unitId, ids]);
}

async function updateWeapon(id, { name, serialNumber, manufacturedOn, kind }) {
  await db.query(`UPDATE personnel.weapons SET name = $2, serial_number = $3, manufactured_on = $4, kind = $5
    WHERE id = $1`, [id, name, serialNumber, manufacturedOn, kind]);
}

/** Списание: из применения, из подразделения и от человека. */
async function decommissionWeapon(id) {
  await db.query(`UPDATE personnel.weapons SET is_active = false, unit_id = NULL, owner_id = NULL
    WHERE id = $1`, [id]);
}

// ----------------------------------------------------------------------------
// Занятость оружия на срок (караул, стрельбы — по приказу): на эти даты
// оружие не выдается на наряд.
// ----------------------------------------------------------------------------

async function reserveWeapon({ weaponId, employeeId, dateFrom, dateTo, reason, orderId, userId }) {
  const { rows } = await db.query(`
    INSERT INTO personnel.weapon_reservations (weapon_id, employee_id, date_from, date_to, reason, order_id, created_by)
    VALUES ($1, $2, $3, $4, $5, $6, $7) RETURNING id
  `, [weaponId, employeeId || null, dateFrom, dateTo, reason || null, orderId || null, userId || null]);
  return rows[0].id;
}

/** Занятость оружия, пересекающая даты (кроме снятой). */
async function weaponReservedOn(weaponId, dateFrom, dateTo) {
  const { rows } = await db.query(`
    SELECT id, reason, to_char(date_from, 'DD.MM.YYYY') AS date_from, to_char(date_to, 'DD.MM.YYYY') AS date_to
    FROM personnel.weapon_reservations
    WHERE weapon_id = $1 AND cancelled_at IS NULL AND date_from <= $3::date AND date_to >= $2::date
    LIMIT 1
  `, [weaponId, dateFrom, dateTo]);
  return rows[0] || null;
}

/** Занятость по приказу — для страницы приказа. */
async function orderReservations(orderId) {
  const { rows } = await db.query(`
    SELECT r.id, r.weapon_id, r.employee_id, e.unit_id, w.unit_id AS weapon_unit_id, r.reason, w.serial_number, w.kind, w.name,
           to_char(r.date_from, 'YYYY-MM-DD') AS date_from, to_char(r.date_to, 'YYYY-MM-DD') AS date_to,
           concat_ws(' ', rk.short_name, e.last_name, e.first_name) AS person
    FROM personnel.weapon_reservations r
    JOIN personnel.weapons w ON w.id = r.weapon_id
    LEFT JOIN personnel.employees e ON e.id = r.employee_id
    LEFT JOIN core.ranks rk ON rk.id = e.rank_id
    WHERE r.order_id = $1 AND r.cancelled_at IS NULL
    ORDER BY e.last_name, w.serial_number
  `, [orderId]);
  return rows;
}

async function getReservation(id) {
  const { rows } = await db.query('SELECT * FROM personnel.weapon_reservations WHERE id = $1', [id]);
  return rows[0] || null;
}

async function cancelReservation(id) {
  await db.query('UPDATE personnel.weapon_reservations SET cancelled_at = now() WHERE id = $1 AND cancelled_at IS NULL', [id]);
}

/** Действующее оружие — для узнавания по номеру в приказе. */
async function activeWeapons() {
  const { rows } = await db.query(`
    SELECT id, name, serial_number, kind, holder_id FROM personnel.v_weapons WHERE is_active ORDER BY serial_number
  `);
  return rows;
}

/** Приказы «прочие» (свои виды для разбора) — с видом и числом отметок. */
async function listOtherOrders() {
  const { rows } = await db.query(`
    SELECT ${ORDER_FIELDS}, o.profile_id, pr.name AS profile_name,
           (SELECT count(*)::int FROM personnel.absences a WHERE a.order_id = o.id AND a.cancelled_at IS NULL) AS absences,
           (SELECT count(*)::int FROM personnel.weapon_reservations r WHERE r.order_id = o.id AND r.cancelled_at IS NULL) AS reservations
    FROM personnel.permit_orders o
    JOIN parse.profiles pr ON pr.id = o.profile_id
    WHERE o.kind = 'other'
    ORDER BY pr.sort_order, pr.name, o.issued_on DESC, o.number
  `);
  return rows;
}

/**
 * Люди без оружия — за ними не числится ни одной действующей единицы
 * (командир с незакрепленным оружием подразделения — с оружием).
 */
async function unarmedPeople(unitIds) {
  const { rows } = await db.query(`
    SELECT e.id, e.unit_id, concat_ws(' ', r.short_name, e.last_name) AS short_name
    FROM personnel.employees e
    LEFT JOIN core.ranks r ON r.id = e.rank_id
    WHERE e.is_active AND e.unit_id IS NOT NULL AND ($1::int[] IS NULL OR e.unit_id = ANY($1::int[]))
      AND NOT EXISTS (SELECT 1 FROM personnel.v_weapons w WHERE w.is_active AND w.holder_id = e.id)
    ORDER BY e.unit_id, r.seniority DESC NULLS LAST, e.last_name
  `, [unitIds]);
  return rows;
}

/** Люди подразделения и вложенных — за кого можно закрепить оружие. */
async function peopleInSubtree(unitId) {
  const { rows } = await db.query(`
    WITH RECURSIVE tree AS (
      SELECT id FROM core.units WHERE id = $1
      UNION ALL SELECT u.id FROM core.units u JOIN tree t ON u.parent_id = t.id
    )
    SELECT e.id, concat_ws(' ', r.short_name, e.last_name, e.first_name) AS label, e.unit_id
    FROM personnel.employees e
    JOIN tree ON tree.id = e.unit_id
    LEFT JOIN core.ranks r ON r.id = e.rank_id
    WHERE e.is_active
    ORDER BY r.seniority DESC NULLS LAST, e.last_name
  `, [unitId]);
  return rows;
}

module.exports = {
  reserveWeapon,
  weaponReservedOn,
  orderReservations,
  getReservation,
  cancelReservation,
  activeWeapons,
  listOtherOrders,
  listAbsenceOrders,
  orderAbsences,
  setAbsenceEnd,
  createEmployee,
  updateEmployeeData,
  personnelNumberTaken,
  setExcluded,
  setRestored,
  listExcluded,
  unarmedPeople,
  weaponsInUnits,
  weaponsInStock,
  getWeaponRow,
  moveWeapon,
  setWeaponOrder,
  updateWeapon,
  decommissionWeapon,
  peopleInSubtree,
  directionIds,
  directionIdsWithin,
  setDirectionOrder,
  listRanks,
 listPermitTypes,listWeapons,createWeapon,
  weaponsOfEmployee,
  freeWeapons,
  getWeapon,
  setWeaponOwner,
  weaponLoans,
  countActive,
  listEmployees,
  listByIds,
  findAvailable,
  findCandidatesForPosts,
  listAbsentOn,
  findUnfitAssignments,
  addAbsence,
  listAbsencesOnDate,
  getAbsence,
  cancelAbsence,
  overlappingAbsences,
  listAbsenceTypes,
  listAbsencesFor,
  listPermitsFor,
  listAllPermitTypes,
  listDirections,
  createDirection,
  updateDirection,
  directionUsage,
  deleteDirection,
  listOrders,
  getOrder,
  createOrder,
  updateOrder,
  setOrderFile,
  deleteOrder,
  orderPermits,
  grantPermit,
  revokePermit,
  getPermit,
};
