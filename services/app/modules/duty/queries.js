'use strict';

// SQL-запросы модуля «Наряды».
// Обращаться сюда напрямую вправе только duty/service.js.

const db = require('../../db/pool');

const DUTY_TYPE_FIELDS = `
    id, code, name, kind, start_time, duration_hours,
    recovery_sleep_days, recovery_off_days, rest_excludes_weekends, base_weight,
    allow_consecutive, holiday_rule, is_active, sort_order, order_template
`;

async function listDutyTypes() {
  const { rows } = await db.query(`
    SELECT ${DUTY_TYPE_FIELDS} FROM duty.duty_types WHERE is_active ORDER BY sort_order, code
  `);
  return rows;
}

/** Все виды нарядов, включая снятые с применения — для справочника. */
async function listAllDutyTypes() {
  const { rows } = await db.query(`
    SELECT ${DUTY_TYPE_FIELDS},
           (SELECT count(*)::int FROM duty.duty_posts p WHERE p.duty_type_id = t.id) AS posts,
           (SELECT count(*)::int FROM duty.duties d WHERE d.duty_type_id = t.id)     AS duties
    FROM duty.duty_types t ORDER BY is_active DESC, sort_order, code
  `);
  return rows;
}

async function createDutyType(data) {
  const { rows } = await db.query(`
    INSERT INTO duty.duty_types
        (code, name, kind, start_time, duration_hours, recovery_sleep_days,
         recovery_off_days, rest_excludes_weekends, base_weight, allow_consecutive,
         holiday_rule, sort_order)
    VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11,
            (SELECT coalesce(max(sort_order), 0) + 10 FROM duty.duty_types))
    RETURNING id
  `, [data.code, data.name, data.kind, data.startTime || null, data.durationHours || null,
    data.sleepDays, data.offDays, data.excludeWeekends, data.baseWeight,
    data.allowConsecutive, data.holidayRule]);
  return rows[0].id;
}

async function updateDutyType(id, data) {
  await db.query(`
    UPDATE duty.duty_types
       SET code = $2, name = $3, kind = $4, start_time = $5, duration_hours = $6,
           recovery_sleep_days = $7, recovery_off_days = $8, rest_excludes_weekends = $9,
           base_weight = $10, allow_consecutive = $11, is_active = $12,
           holiday_rule = $13
     WHERE id = $1
  `, [id, data.code, data.name, data.kind, data.startTime || null, data.durationHours || null,
    data.sleepDays, data.offDays, data.excludeWeekends, data.baseWeight,
    data.allowConsecutive, data.isActive, data.holidayRule]);
}

/** Расписание многосуточной смены: дни недели заступления и сдачи. */
async function setSchedules(dutyTypeId, items) {
  return db.transaction(async (client) => {
    await client.query('DELETE FROM duty.duty_type_schedules WHERE duty_type_id = $1', [dutyTypeId]);
    if (items.length === 0) return;

    await client.query(`
      INSERT INTO duty.duty_type_schedules (duty_type_id, start_weekday, end_weekday, start_time)
      SELECT $1, s, e, $4
      FROM unnest($2::int[], $3::int[]) AS a(s, e)
    `, [dutyTypeId, items.map((i) => i.startWeekday), items.map((i) => i.endWeekday),
      items[0].startTime || null]);
  });
}

/** Общие допуски вида наряда. */
async function setGeneralPermits(dutyTypeId, permitTypeIds) {
  return db.transaction(async (client) => {
    await client.query('DELETE FROM duty.duty_type_permits WHERE duty_type_id = $1', [dutyTypeId]);
    if (permitTypeIds.length === 0) return;

    await client.query(`
      INSERT INTO duty.duty_type_permits (duty_type_id, permit_type_id)
      SELECT $1, id FROM unnest($2::int[]) AS a(id)
    `, [dutyTypeId, permitTypeIds]);
  });
}

/** Что держит вид наряда: посты и наряды за все время. */
async function dutyTypeUsage(id) {
  const { rows } = await db.query(`
    SELECT (SELECT count(*)::int FROM duty.duty_posts WHERE duty_type_id = $1) AS posts,
           (SELECT count(*)::int FROM duty.duties     WHERE duty_type_id = $1) AS duties
  `, [id]);
  return rows[0];
}

/**
 * Удаление вида наряда СО ВСЕМ, что к нему относится.
 *
 * Порядок задан ссылками: назначения — наряды — посты — сам вид. Все одной
 * транзакцией: вид, удаленный наполовину, оставил бы наряды без правил.
 */
async function deleteDutyType(id) {
  return db.transaction(async (client) => {
    await client.query(`
      DELETE FROM duty.duty_assignments a
       USING duty.duties d
       WHERE a.duty_id = d.id AND d.duty_type_id = $1
    `, [id]);
    await client.query('DELETE FROM duty.duties WHERE duty_type_id = $1', [id]);
    await client.query('DELETE FROM duty.duty_posts WHERE duty_type_id = $1', [id]);
    await client.query('DELETE FROM duty.duty_types WHERE id = $1', [id]);
  });
}

async function getDutyType(id) {
  const { rows } = await db.query(`
    SELECT ${DUTY_TYPE_FIELDS} FROM duty.duty_types WHERE id = $1
  `, [id]);
  return rows[0] || null;
}

async function getSchedules(dutyTypeId) {
  const { rows } = await db.query(`
    SELECT start_weekday, end_weekday, start_time
    FROM duty.duty_type_schedules
    WHERE duty_type_id = $1
    ORDER BY start_weekday
  `, [dutyTypeId]);
  return rows;
}

/**
 * Общие допуски, обязательные для данного вида наряда.
 *
 * Постовые допуски сюда не попадают: они проверяются по каждому посту
 * отдельно, через наличие допуска именно к этому посту.
 */
async function getGeneralPermits(dutyTypeId) {
  const { rows } = await db.query(`
    SELECT pt.id AS permit_type_id, pt.code, pt.name
    FROM duty.duty_type_permits dtp
    JOIN personnel.permit_types pt ON pt.id = dtp.permit_type_id
    WHERE dtp.duty_type_id = $1
      AND NOT pt.is_post_specific
    ORDER BY pt.id
  `, [dutyTypeId]);
  return rows;
}

// ----------------------------------------------------------------------------
// Посты
// ----------------------------------------------------------------------------

const POST_FIELDS = `
    p.id, p.duty_type_id, p.unit_id, p.short_name, p.name,
    p.sort_order, p.is_active, p.required_permit_type_id, p.required_weapon_kind,
    p.start_time, p.duration_hours, p.recovery_sleep_days, p.per_day,
    p.allow_consecutive,
    to_char(p.rotation_since, 'YYYY-MM-DD') AS rotation_since,
    u.short_name AS unit_short
`;

/** Действующие посты вида наряда, в порядке вывода в приказе. */
async function listPosts(dutyTypeId) {
  const { rows } = await db.query(`
    SELECT ${POST_FIELDS}
    FROM duty.duty_posts p
    LEFT JOIN core.units u ON u.id = p.unit_id
    WHERE p.duty_type_id = $1 AND p.is_active
    ORDER BY p.sort_order, p.name
  `, [dutyTypeId]);
  return rows;
}

/** Все посты, включая выведенные из применения — для справочника. */
async function listAllPosts() {
  const { rows } = await db.query(`
    SELECT ${POST_FIELDS}, dt.code AS duty_code, dt.name AS duty_name
    FROM duty.duty_posts p
    JOIN duty.duty_types dt ON dt.id = p.duty_type_id
    LEFT JOIN core.units u  ON u.id = p.unit_id
    ORDER BY dt.sort_order, dt.code, p.sort_order, p.name
  `);
  return rows;
}

async function getPost(id) {
  const { rows } = await db.query(`
    SELECT ${POST_FIELDS}, dt.code AS duty_code
    FROM duty.duty_posts p
    JOIN duty.duty_types dt ON dt.id = p.duty_type_id
    LEFT JOIN core.units u  ON u.id = p.unit_id
    WHERE p.id = $1
  `, [id]);
  return rows[0] || null;
}

async function createPost({ dutyTypeId, unitId, shortName, name, sortOrder, requiredPermitTypeId, requiredWeaponKind, allowConsecutive }) {
  const { rows } = await db.query(`
    INSERT INTO duty.duty_posts (duty_type_id, unit_id, short_name, name, sort_order,
                                 required_permit_type_id, required_weapon_kind, allow_consecutive)
    VALUES ($1, $2, $3, $4,
            -- Новый пост — в конец своего вида; порядок потом перетаскивается.
            COALESCE($5, (SELECT coalesce(max(sort_order), 0) + 10
                          FROM duty.duty_posts WHERE duty_type_id = $1)),
            $6, $7, $8)
    RETURNING id
  `, [dutyTypeId, unitId || null, shortName || null, name, sortOrder ?? null,
    requiredPermitTypeId || null, requiredWeaponKind || null, allowConsecutive ?? null]);
  return rows[0].id;
}

// Подразделение поста здесь не правится: оно задается очередью заступающих
// (setPostUnits). Иначе о принадлежности поста было бы два мнения.
async function updatePost(id, { dutyTypeId, shortName, name, sortOrder, isActive, requiredPermitTypeId, requiredWeaponKind, allowConsecutive }) {
  await db.query(`
    UPDATE duty.duty_posts
       SET duty_type_id = COALESCE($8, duty_type_id),
           short_name = $2,
           name       = $3,
           -- Порядок задается перетаскиванием, форма его не присылает. При
           -- переносе в другой вид пост встает в конец нового вида.
           sort_order = CASE
             WHEN $4::int IS NOT NULL THEN $4::int
             WHEN $8::int IS NOT NULL AND $8::int <> duty_type_id THEN
               (SELECT coalesce(max(q.sort_order), 0) + 10
                FROM duty.duty_posts q WHERE q.duty_type_id = $8::int)
             ELSE sort_order END,
           is_active  = $5, required_permit_type_id=$6, required_weapon_kind=$7,
           allow_consecutive = $9
     WHERE id = $1
  `, [id, shortName || null, name, sortOrder ?? null, isActive, requiredPermitTypeId || null,
    requiredWeaponKind || null, dutyTypeId || null, allowConsecutive ?? null]);
  if(!isActive) await db.query(`DELETE FROM duty.duty_assignments a USING duty.duties d
    WHERE a.duty_id=d.id AND a.post_id=$1 AND d.start_date>CURRENT_DATE AND d.status<>'cancelled'`,[id]);
}

// ----------------------------------------------------------------------------
// Наряды
// ----------------------------------------------------------------------------

async function listUnits() {
  const { rows } = await db.query(`
    SELECT id, name, short_name, parent_id
    FROM core.units
    WHERE is_active
    ORDER BY sort_order, short_name
  `);
  return rows;
}

/**
 * Идентификаторы сотрудников, уже назначенных в наряд, пересекающийся
 * по времени с указанным периодом. Отмененные наряды не учитываются.
 */
async function findBusyEmployeeIds(startsAt, endsAt, exceptDutyId) {
  // Занятость берется по интервалу НАЗНАЧЕНИЯ, а не наряда: посменный пост
  // внутри многосуточной смены занимает человека только на свой выход.
  const { rows } = await db.query(`
    SELECT DISTINCT a.employee_id
    FROM duty.v_assignment_periods a
    WHERE a.status <> 'cancelled'
      AND a.starts_at < $2
      AND a.ends_at   > $1
      AND NOT (a.duty_id = ANY($3::int[]))
  `, [startsAt, endsAt, Array.isArray(exceptDutyId) ? exceptDutyId : exceptDutyId ? [exceptDutyId] : []]);
  return rows.map((r) => r.employee_id);
}

/**
 * Замещение постов существующего наряда.
 *
 * Изменяются только те посты, значение которых отличается от текущего:
 * иначе перезапись всего состава сбросила бы признак источника назначения
 * у постов, которых правка не касалась, и предложенный системой состав
 * молча превратился бы в назначенный вручную.
 *
 * Место в наряде задается постом И сутками выхода: у постоянного состава
 * сутки пустые, у посменного поста (ПТСО, ПУД) один и тот же пост занимает
 * несколько мест — по одному на каждый день смены.
 *
 * @param {Array<{postId:number, onDate:?string, employeeId:?number}>} slots
 * @returns {number} число измененных мест
 */
async function updateAssignments(dutyId, slots, userId, source = 'manual') {
  return db.transaction(async (client) => {
    const { rows: current } = await client.query(`
      SELECT post_id, to_char(on_date, 'YYYY-MM-DD') AS on_date, employee_id
      FROM duty.duty_assignments WHERE duty_id = $1
    `, [dutyId]);

    const key = (postId, onDate) => `${postId}|${onDate || ''}`;
    const currentBySlot = new Map(current.map((r) => [key(r.post_id, r.on_date), r.employee_id]));

    const freed = [];
    const taken = [];

    for (const slot of slots) {
      const now = currentBySlot.get(key(slot.postId, slot.onDate));
      const was = now === undefined ? null : now;
      if (was === slot.employeeId) continue;

      if (was !== null) freed.push(slot);
      if (slot.employeeId !== null) taken.push(slot);
    }

    if (freed.length === 0 && taken.length === 0) return 0;

    if (freed.length > 0) {
      await client.query(`
        DELETE FROM duty.duty_assignments da
        USING unnest($2::int[], $3::date[]) AS f(post_id, on_date)
        WHERE da.duty_id = $1 AND da.post_id = f.post_id
          AND coalesce(da.on_date, '-infinity'::date) = coalesce(f.on_date, '-infinity'::date)
      `, [dutyId, freed.map((f) => f.postId), freed.map((f) => f.onDate || null)]);
    }

    if (taken.length > 0) {
      await client.query(`
        INSERT INTO duty.duty_assignments (duty_id, post_id, employee_id, on_date, source)
        SELECT $1, post_id, employee_id, on_date, $5
        FROM unnest($2::int[], $3::int[], $4::date[]) AS a(post_id, employee_id, on_date)
      `, [dutyId, taken.map((t) => t.postId), taken.map((t) => t.employeeId),
        taken.map((t) => t.onDate || null), source]);
    }

    // Состав изменился — прежнее утверждение к нему уже не относится
    await client.query(`
      UPDATE duty.duties
         SET status = 'draft',
             approved_at = NULL,
             approved_by = NULL,
             unapproved_at = now(),
             unapproved_by = $2
       WHERE id = $1 AND status = 'approved' AND start_date>CURRENT_DATE
    `, [dutyId, userId || null]);

    return freed.length + taken.length;
  });
}

/**
 * Наряды, сданные незадолго до указанного момента, вместе с нормой отдыха
 * своего вида. Нужны для проверки отсыпного: он отсчитывается от дня сдачи.
 *
 * Окно в 14 суток заведомо перекрывает самую длинную норму отдыха
 * (двое суток без учета выходных у ОО).
 */
async function findRecentDutyEnds(before, exceptIds=[]) {
  const { rows } = await db.query(`
    SELECT DISTINCT
           a.employee_id,
           to_char(a.ends_at, 'YYYY-MM-DD') AS end_date,
           a.recovery_sleep_days,
           a.rest_excludes_weekends,
           a.duty_code,
           a.duty_type_id,
           a.post_id,
           p.name AS post_name
    FROM duty.v_assignment_periods a
    JOIN duty.duty_posts p ON p.id = a.post_id
    WHERE a.status <> 'cancelled'
      AND a.ends_at <= $1
      AND a.ends_at >  $1::timestamptz - interval '740 days'
      AND NOT (a.duty_id=ANY($2::int[]))
  `, [before,exceptIds]);
  return rows;
}

/**
 * Сотрудники, находящиеся в наряде в указанные сутки.
 *
 * День СДАЧИ в наряд не входит: смену в этот день принимает следующий
 * состав, а сдавший уходит в отсыпной — тем же днем, с которого отсчитывается
 * отдых. Иначе сутки сдачи считались бы дважды: и нарядом, и отсыпным.
 *
 * Многодневная смена (ОО) занимает все свои сутки, кроме дня сдачи. Выход
 * посменного поста, начинающийся и кончающийся в один день (ПТСО 1, ПУД),
 * занимает эти одни сутки: правило «кроме дня сдачи» отняло бы у него
 * единственные.
 */
async function findEmployeesOnDuty(onDate) {
  const { rows } = await db.query(`
    SELECT DISTINCT a.employee_id, a.duty_code, p.name AS post_name
    FROM duty.v_assignment_periods a
    JOIN duty.duty_posts p ON p.id = a.post_id
    WHERE a.status <> 'cancelled'
      AND a.starts_at::date <= $1::date
      AND $1::date < GREATEST(a.ends_at::date, a.starts_at::date + 1)
  `, [onDate]);
  return rows;
}

/**
 * Сотрудники, уже назначенные в наряд, заступающий в один из указанных дней.
 *
 * Нужны для проверки отсыпного вперед: отсыпной нового наряда не должен
 * накрывать наряд, в который человек уже назначен. Проверки только назад
 * недостаточно — наряды создаются в произвольном порядке, и наряд, вставленный
 * в пропуск задним числом, о завтрашнем назначении иначе не узнает.
 */
async function findEmployeesStartingOn(days, exceptIds=[]) {
  if (!days || days.length === 0) return [];
  const { rows } = await db.query(`
    SELECT DISTINCT a.employee_id
    FROM duty.v_assignment_periods a
    WHERE a.status <> 'cancelled'
      AND to_char(a.starts_at, 'YYYY-MM-DD') = ANY($1::text[])
      AND NOT (a.duty_id=ANY($2::int[]))
  `, [days,exceptIds]);
  return rows.map((r) => r.employee_id);
}

/**
 * Накопленная нагрузка по сотрудникам за период.
 *
 * Вес наряда складывается из двух частей:
 *   • базовый вес вида, умноженный на коэффициент дня — наряд в нерабочий
 *     день тяжелее равного ему в рабочий;
 *   • вес отсыпного: сутки после наряда человек недоступен, и это часть
 *     платы за наряд. Без него многодневная смена ОО, дающая двое суток
 *     отдыха, выглядела бы для балансировки такой же, как суточный наряд
 *     с одними сутками.
 *
 * Нагрузка НЕ хранится, а считается по фактическим назначениям: хранимая
 * сумма разошлась бы с ними при любой правке состава задним числом.
 *
 * Оба коэффициента приняты предварительно (см. открытый вопрос 6).
 */
async function employeeWorkload(from, to, weekendFactor = 1.5, sleepFactor = 0.5) {
  const { rows } = await db.query(`
    SELECT a.employee_id,
           round(sum(
               a.base_weight * CASE
                   WHEN cd.kind = 'workday' THEN 1
                   WHEN cd.kind = 'holiday' THEN $3::numeric
                   WHEN extract(isodow FROM a.starts_at) >= 6 THEN $3::numeric
                   ELSE 1
               END
               + coalesce(a.recovery_sleep_days, 0) * $4::numeric
           ), 2)::float AS weight,
           count(*)::int AS duties
    FROM duty.v_assignment_periods a
    LEFT JOIN core.calendar_days cd ON cd.day = (a.starts_at AT TIME ZONE current_setting('TimeZone'))::date
    WHERE a.status <> 'cancelled'
      AND a.starts_at >= $1::date
      AND a.starts_at <  $2::date
    GROUP BY a.employee_id
  `, [from, to, weekendFactor, sleepFactor]);
  return rows;
}

/** Число действующих постов вида наряда — сколько человек требуется. */
async function countActivePosts(dutyTypeId) {
  const { rows } = await db.query(`
    SELECT count(*)::int AS n
    FROM duty.duty_posts
    WHERE duty_type_id = $1 AND is_active
  `, [dutyTypeId]);
  return rows[0].n;
}

/**
 * Наряды вида за период, вместе с числом назначенных и числом назначений,
 * сделанных системой. Дата заступления возвращается строкой: она служит
 * ключом дня в календаре и не должна зависеть от смещения при передаче.
 */
async function listDutiesInRange(dutyTypeId, from, to, unitId) {
  const { rows } = await db.query(`
    SELECT d.id, d.starts_at, d.ends_at, d.status, d.unit_id, d.approved_snapshot,
           to_char(d.starts_at, 'YYYY-MM-DD') AS start_date,
           u.short_name AS unit_short,
           count(da.id) FILTER (WHERE EXISTS(SELECT 1 FROM duty.duty_posts p WHERE p.id=da.post_id AND p.is_active))::int AS assigned_count,
           count(da.id) FILTER (WHERE da.on_date IS NULL AND EXISTS(SELECT 1 FROM duty.duty_posts p WHERE p.id=da.post_id AND p.is_active))::int AS permanent_assigned,
           count(da.id) FILTER (WHERE da.source = 'auto')::int AS auto_count,
           array_remove(array_agg(da.note), NULL) AS notes,
           sc.counts AS shift_counts
    FROM duty.duties d
    JOIN core.units u ON u.id = d.unit_id
    LEFT JOIN duty.duty_assignments da ON da.duty_id = d.id
    -- Замещенные выходы посменных постов по суткам: в графике каждые сутки
    -- многосуточной смены показывают СВОЕ заполнение.
    LEFT JOIN LATERAL (
      SELECT jsonb_object_agg(x.on_date, x.n) AS counts
      FROM (SELECT to_char(da2.on_date, 'YYYY-MM-DD') AS on_date, count(*) AS n
            FROM duty.duty_assignments da2
            JOIN duty.duty_posts p2 ON p2.id = da2.post_id AND p2.is_active
            WHERE da2.duty_id = d.id AND da2.on_date IS NOT NULL
            GROUP BY 1) x
    ) sc ON true
    WHERE d.duty_type_id = $1
      AND d.starts_at >= $2::date
      AND d.starts_at <  $3::date + 1
      AND ($4::int IS NULL OR $4::int IS NOT NULL)
    GROUP BY d.id, u.short_name, sc.counts
    ORDER BY d.starts_at, (d.status='cancelled') DESC
  `, [dutyTypeId, from, to, unitId || null]);
  return rows;
}

/**
 * Назначения за период вместе с периодом наряда и нормой отдыха его вида.
 *
 * Нужны для проверки уже назначенного состава. Отбор кандидатов проверяет
 * человека в момент назначения, но условия меняются ПОСЛЕ: объявляется
 * нерабочий день, и отсыпной, считаемый без учета выходных, удлиняется;
 * истекает допуск; человек уходит в отпуск. Назначение при этом остается
 * в базе, и без повторной проверки наряд выглядит укомплектованным.
 *
 * Запас в 14 суток назад нужен потому, что отсыпной от наряда, сданного до
 * начала периода, может накрывать его первые дни.
 */
async function listAssignmentsInRange(from, to) {
  const { rows } = await db.query(`
    SELECT a.duty_id, a.employee_id, a.post_id, a.is_override, a.override_checks,
           a.starts_at, a.ends_at, a.duty_type_id,
           to_char(a.on_date, 'YYYY-MM-DD') AS on_date,
           to_char(a.start_date, 'YYYY-MM-DD') AS start_date,
           to_char(d.starts_at, 'YYYY-MM-DD') AS duty_start_date,
           a.recovery_sleep_days, a.rest_excludes_weekends, a.duty_code,
           a.allow_consecutive
    FROM duty.v_assignment_periods a
    JOIN duty.duties d ON d.id = a.duty_id
    WHERE a.status <> 'cancelled'
      AND a.ends_at >= $1::date - 740
      AND a.starts_at <  $2::date + 1
    ORDER BY a.employee_id, a.starts_at
  `, [from, to]);
  return rows;
}

/** Наряды вида, заступающие в указанные дни. */
async function findDutiesOnDates(dutyTypeId, dates, unitId) {
  if (!dates || dates.length === 0) return [];

  const { rows } = await db.query(`
    SELECT d.id, d.starts_at, d.ends_at, d.status, d.unit_id, d.approved_snapshot, d.note,
           to_char(d.starts_at, 'YYYY-MM-DD') AS start_date,
           u.short_name AS unit_short,
           u.name AS unit_name
    FROM duty.duties d
    JOIN core.units u ON u.id = d.unit_id
    WHERE d.duty_type_id = $1
      AND d.status <> 'cancelled'
      AND to_char(d.starts_at, 'YYYY-MM-DD') = ANY($2::text[])
      AND ($3::int IS NULL OR $3::int IS NOT NULL)
    ORDER BY d.starts_at
  `, [dutyTypeId, dates, unitId || null]);
  return rows;
}

/** Состав нескольких нарядов сразу — для приказа на весь блок. */
async function getAssignmentsForDuties(dutyIds) {
  if (!dutyIds || dutyIds.length === 0) return [];

  const { rows } = await db.query(`
    SELECT da.id, da.weapon_id, da.duty_id, da.employee_id, da.is_override, da.override_reason, da.override_checks, da.note,
           to_char(da.on_date, 'YYYY-MM-DD') AS on_date,
           p.id AS post_id, p.name AS post_name, p.short_name AS post_short,
           p.start_time, p.duration_hours,
           p.sort_order
    FROM duty.duty_assignments da
    JOIN duty.duty_posts p ON p.id = da.post_id
    WHERE da.duty_id = ANY($1::int[])
    ORDER BY da.duty_id, p.sort_order, p.name, da.on_date
  `, [dutyIds]);
  return rows;
}

/** Утверждение нескольких нарядов одним действием — приказ подписывается целиком. */
async function approveDuties(dutyIds, userId) {
  if (!dutyIds || dutyIds.length === 0) return 0;

  const { rowCount } = await db.query(`
    UPDATE duty.duties
       SET status = 'approved', approved_at = now(), approved_by = $2
     WHERE id = ANY($1::int[]) AND status <> 'cancelled' AND status <> 'approved'
  `, [dutyIds, userId || null]);
  return rowCount;
}

async function unapproveDuties(dutyIds, userId) {
  if (!dutyIds || dutyIds.length === 0) return 0;

  const { rowCount } = await db.query(`
    UPDATE duty.duties
       SET status = 'draft', approved_at = NULL, approved_by = NULL,
           unapproved_at = now(), unapproved_by = $2
     WHERE id = ANY($1::int[]) AND status = 'approved' AND start_date>CURRENT_DATE
  `, [dutyIds, userId || null]);
  return rowCount;
}

/**
 * Замена одного человека на посту с указанием причины.
 *
 * Отличается от правки состава тем, что затрагивает РОВНО один пост и
 * обязательно сопровождается примечанием: замена вносится при утверждении
 * приказа, когда состав в остальном уже согласован, и через месяц должно
 * быть видно, почему в приказе оказался не тот, кого предложила система.
 *
 * @param {?number} employeeId  null — пост освобождается
 * @returns {boolean} было ли изменение
 */
async function replaceAssignment(dutyId, postId, employeeId, note, userId, onDate = null) {
  return db.transaction(async (client) => {
    const { rows: current } = await client.query(`
      SELECT employee_id FROM duty.duty_assignments
      WHERE duty_id = $1 AND post_id = $2
        AND coalesce(on_date, '-infinity'::date) = coalesce($3::date, '-infinity'::date)
    `, [dutyId, postId, onDate]);

    const now = current.length > 0 ? current[0].employee_id : null;
    if (now === employeeId) return false;

    if (now !== null) {
      await client.query(`
        DELETE FROM duty.duty_assignments
        WHERE duty_id = $1 AND post_id = $2
          AND coalesce(on_date, '-infinity'::date) = coalesce($3::date, '-infinity'::date)
      `, [dutyId, postId, onDate]);
    }

    if (employeeId !== null) {
      await client.query(`
        INSERT INTO duty.duty_assignments
               (duty_id, post_id, employee_id, on_date, source, note, noted_by, noted_at)
        VALUES ($1, $2, $3, $6, 'manual', $4, $5, now())
      `, [dutyId, postId, employeeId, note || null, userId || null, onDate]);
    }

    return true;
  });
}

/**
 * Приказы на наряд вида — сохраненные при утверждении формы приказа. Приказ
 * на несколько суток (выходные) — одна строка: наряды одного приказа
 * объединяются по сроку выпуска.
 */
async function listStoredOrders(dutyTypeId) {
  const { rows } = await db.query(`
    SELECT to_char(d.order_deadline, 'YYYY-MM-DD') AS order_date,
           min(d.id) AS duty_id, count(*)::int AS days,
           min(d.starts_at) AS starts_at, max(d.ends_at) AS ends_at,
           bool_and(d.status = 'approved') AS approved,
           max(d.approved_at) AS approved_at,
           max((d.order_snapshot ->> 'templateVersion')) AS template_version
    FROM duty.duties d
    WHERE d.duty_type_id = $1 AND d.order_snapshot IS NOT NULL AND d.status <> 'cancelled'
    GROUP BY d.order_deadline
    ORDER BY d.order_deadline DESC
  `, [dutyTypeId]);
  return rows;
}

/** Снять человека со всех нарядов, заступающих после сегодняшних суток. */
async function dropFutureAssignments(employeeId) {
  const { rows } = await db.query(`
    DELETE FROM duty.duty_assignments da USING duty.duties d
    WHERE da.duty_id = d.id AND da.employee_id = $1 AND d.start_date > CURRENT_DATE AND d.status <> 'cancelled'
    RETURNING d.duty_type_id, to_char(d.start_date, 'YYYY-MM-DD') AS start_date
  `, [employeeId]);
  return rows;
}

/**
 * Снятие сотрудника со всех нарядов, заступающих в указанном периоде.
 *
 * Человек, недоступный на эти даты, не может оставаться ни в одном наряде
 * периода — снятие только с текущего оставило бы его в остальных.
 *
 * Наряды, потерявшие человека, возвращаются в состояние проекта: состав
 * изменился, и прежнее утверждение к нему уже не относится.
 */
async function withdrawEmployee(employeeId, dateFrom, dateTo, userId) {
  return db.transaction(async (client) => {
    const { rows: affected } = await client.query(`
      DELETE FROM duty.duty_assignments da
      USING duty.v_assignment_periods a, duty.duties d
      WHERE a.id = da.id AND da.duty_id = d.id
        AND da.employee_id = $1
        AND d.status <> 'cancelled'
        AND a.ends_at > $2::date
        AND a.starts_at < $3::date + 1
      RETURNING d.id AS duty_id
    `, [employeeId, dateFrom, dateTo]);

    const dutyIds = [...new Set(affected.map((r) => r.duty_id))];

    if (dutyIds.length > 0) {
      await client.query(`
        UPDATE duty.duties
           SET status = 'draft',
               approved_at = NULL,
               approved_by = NULL,
               unapproved_at = now(),
               unapproved_by = $2
         WHERE id = ANY($1::int[]) AND status = 'approved' AND start_date>CURRENT_DATE
      `, [dutyIds, userId || null]);
    }

    return dutyIds;
  });
}

// ----------------------------------------------------------------------------
// Справочник празднично-выходных дней
// ----------------------------------------------------------------------------

/** Отклонения от обычной недели за период. */
async function listCalendarDays(from, to) {
  const { rows } = await db.query(`
    SELECT to_char(day, 'YYYY-MM-DD') AS day, kind, name
    FROM core.calendar_days
    WHERE day >= $1::date AND day <= $2::date
    ORDER BY day
  `, [from, to]);
  return rows;
}

/**
 * Отметка периода целиком.
 *
 * Нерабочие дни объявляются периодами, а не поодиночке: новогодние каникулы
 * — это восемь дней одним основанием. Хранятся они по-прежнему по суткам,
 * потому что перенос отдельного дня внутри периода — обычное дело.
 *
 * @returns {number} число отмеченных суток
 */
async function setCalendarRange(dateFrom, dateTo, kind, name) {
  const { rowCount } = await db.query(`
    INSERT INTO core.calendar_days (day, kind, name)
    SELECT d::date, $3, $4
    FROM generate_series($1::date, $2::date, interval '1 day') AS d
    ON CONFLICT (day) DO UPDATE SET kind = excluded.kind, name = excluded.name
  `, [dateFrom, dateTo, kind, name || null]);
  return rowCount;
}

async function deleteCalendarRange(dateFrom, dateTo) {
  const { rowCount } = await db.query(
    'DELETE FROM core.calendar_days WHERE day >= $1::date AND day <= $2::date',
    [dateFrom, dateTo],
  );
  return rowCount;
}

async function listDuties(limit = 50) {
  const { rows } = await db.query(`
    SELECT d.id, d.starts_at, d.ends_at, d.status,
           dt.code AS duty_code, dt.name AS duty_name,
           u.short_name AS unit_short,
           count(da.id)::int AS assigned_count
    FROM duty.duties d
    JOIN duty.duty_types dt ON dt.id = d.duty_type_id
    JOIN core.units u       ON u.id = d.unit_id
    LEFT JOIN duty.duty_assignments da ON da.duty_id = d.id
    GROUP BY d.id, dt.code, dt.name, u.short_name
    ORDER BY d.starts_at DESC
    LIMIT $1
  `, [limit]);
  return rows;
}

async function getDuty(id) {
  const { rows } = await db.query(`
    SELECT d.id, d.starts_at, d.ends_at, d.status, d.note, d.approved_snapshot, d.order_snapshot, d.order_deadline,
           dt.id   AS duty_type_id,
           dt.code AS duty_code,
           dt.name AS duty_name,
           u.id    AS unit_id,
           u.name  AS unit_name,
           u.short_name AS unit_short
    FROM duty.duties d
    JOIN duty.duty_types dt ON dt.id = d.duty_type_id
    JOIN core.units u       ON u.id = d.unit_id
    WHERE d.id = $1
  `, [id]);
  return rows[0] || null;
}

/** Назначения наряда: пост и назначенный на него сотрудник. */
async function getAssignments(dutyId) {
  const { rows } = await db.query(`
    SELECT da.id, da.weapon_id, da.employee_id,
           da.is_override,
           da.override_reason, da.override_checks,
           da.note,
           to_char(da.on_date, 'YYYY-MM-DD') AS on_date,
           p.id         AS post_id,
           p.name       AS post_name,
           p.short_name AS post_short,
           p.start_time, p.duration_hours,
           p.sort_order
    FROM duty.duty_assignments da
    JOIN duty.duty_posts p ON p.id = da.post_id
    WHERE da.duty_id = $1
    ORDER BY p.sort_order, p.name, da.on_date
  `, [dutyId]);
  return rows;
}

/**
 * Создание наряда вместе с составом в одной транзакции.
 * @param {Array<{postId:number, employeeId:number, onDate:?string}>} assignments
 *   onDate — сутки выхода посменного поста; null у постоянного состава.
 */
async function createDuty({ dutyTypeId, unitId, startsAt, endsAt, assignments, note, userId, source = 'manual' }) {
  return db.transaction(async (client) => {
    const { rows } = await client.query(`
      INSERT INTO duty.duties (duty_type_id, unit_id, starts_at, ends_at, status, note,created_by)
      VALUES ($1, $2, $3, $4, 'draft', $5,$6)
      RETURNING id
    `, [dutyTypeId, unitId, startsAt, endsAt, note || null,userId || null]);

    const dutyId = rows[0].id;

    if (assignments.length > 0) {
      await client.query(`
        INSERT INTO duty.duty_assignments (duty_id, post_id, employee_id, on_date, source)
        SELECT $1, post_id, employee_id, on_date, $5
        FROM unnest($2::int[], $3::int[], $4::date[]) AS a(post_id, employee_id, on_date)
      `, [
        dutyId,
        assignments.map((a) => a.postId),
        assignments.map((a) => a.employeeId),
        assignments.map((a) => a.onDate || null),
        source,
      ]);
    }

    return dutyId;
  });
}

async function markOverride(dutyId,postId,reason,checks,userId,onDate=null) {
 await db.query(`UPDATE duty.duty_assignments SET is_override=true,override_reason=$3,override_checks=$4,override_by=$5
 WHERE duty_id=$1 AND post_id=$2
   AND coalesce(on_date,'-infinity'::date)=coalesce($6::date,'-infinity'::date)`,
 [dutyId,postId,reason,checks,userId,onDate]);
}
async function saveSnapshot(dutyId,snapshot,order,deadline) {
 await db.query('UPDATE duty.duties SET approved_snapshot=$2,order_snapshot=$3,order_deadline=$4 WHERE id=$1',
 [dutyId,JSON.stringify(snapshot),JSON.stringify(order),deadline]);
}
async function listFutureDuties() {
 return (await db.query("SELECT id,duty_type_id,unit_id,starts_at,ends_at,order_deadline FROM duty.duties WHERE start_date>CURRENT_DATE AND status<>'cancelled' ORDER BY starts_at")).rows;
}
async function rootUnit() {
 const {rows}=await db.query('SELECT id FROM core.units WHERE parent_id IS NULL AND is_active ORDER BY id LIMIT 1');
 if(!rows.length) require('../../lib/validation').fail('Не заведена часть в справочнике подразделений.');
 return rows[0].id;
}

// ----------------------------------------------------------------------------
// Ответственное подразделение
// ----------------------------------------------------------------------------





// ----------------------------------------------------------------------------
// Очередь заступления
// ----------------------------------------------------------------------------

/** Настройки подбора. Хранятся в БД: коэффициенты подбираются опытом. */
async function listSettings() {
  const { rows } = await db.query(
    'SELECT key, value::float AS value, name, description FROM core.settings ORDER BY key',
  );
  return rows;
}

async function setSetting(key, value, userId) {
  const { rowCount } = await db.query(`
    UPDATE core.settings SET value = $2, updated_by = $3, updated_at = now() WHERE key = $1
  `, [key, value, userId || null]);
  return rowCount;
}

/**
 * Последнее заступление каждого сотрудника до указанного момента.
 *
 * Считается по ВСЕМ видам нарядов: человек устает от любого наряда, и очередь
 * на ОД должна падать после суточного наряда тоже.
 */
/**
 * Сутки СДАЧИ последнего наряда, начатого до указанного момента: от них
 * считается готовность — сутки простоя. От заступления считать нельзя:
 * многосуточная смена засчитывалась бы простоем, и вернувшийся с недельной
 * смены на следующий день оказывался бы «готовее» того, кто неделю отдыхал.
 */
async function lastDutyEnds(before) {
  const { rows } = await db.query(`
    SELECT a.employee_id, to_char(max(a.ends_at), 'YYYY-MM-DD') AS last_date
    FROM duty.v_assignment_periods a
    WHERE a.status <> 'cancelled' AND a.starts_at < $1
    GROUP BY a.employee_id
  `, [before]);
  return rows;
}

/** Веса званий по постам вида наряда. */
async function listPostRankWeights(dutyTypeId) {
  const { rows } = await db.query(`
    SELECT w.post_id, w.rank_id, w.weight::float AS weight
    FROM duty.post_rank_weights w
    JOIN duty.duty_posts p ON p.id = w.post_id
    WHERE $1::int IS NULL OR p.duty_type_id = $1
  `, [dutyTypeId || null]);
  return rows;
}

async function setPostRankWeights(postId, items) {
  return db.transaction(async (client) => {
    await client.query('DELETE FROM duty.post_rank_weights WHERE post_id = $1', [postId]);
    if (items.length === 0) return;

    await client.query(`
      INSERT INTO duty.post_rank_weights (post_id, rank_id, weight)
      SELECT $1, rank_id, weight
      FROM unnest($2::int[], $3::numeric[]) AS a(rank_id, weight)
    `, [postId, items.map((i) => i.rankId), items.map((i) => i.weight)]);
  });
}

/** Личные поправки к постам. */
async function listEmployeePostWeights(dutyTypeId) {
  const { rows } = await db.query(`
    SELECT w.employee_id, w.post_id, w.weight::float AS weight, w.note
    FROM personnel.employee_post_weights w
    JOIN duty.duty_posts p ON p.id = w.post_id
    WHERE $1::int IS NULL OR p.duty_type_id = $1
  `, [dutyTypeId || null]);
  return rows;
}

async function setEmployeePostWeight(employeeId, postId, weight, note, userId) {
  if (weight === null) {
    const { rowCount } = await db.query(
      'DELETE FROM personnel.employee_post_weights WHERE employee_id = $1 AND post_id = $2',
      [employeeId, postId],
    );
    return rowCount;
  }

  const { rowCount } = await db.query(`
    INSERT INTO personnel.employee_post_weights (employee_id, post_id, weight, note, updated_by)
    VALUES ($1, $2, $3, $4, $5)
    ON CONFLICT (employee_id, post_id)
      DO UPDATE SET weight = excluded.weight, note = excluded.note,
                    updated_by = excluded.updated_by, updated_at = now()
  `, [employeeId, postId, weight, note || null, userId || null]);
  return rowCount;
}

/** Замещенные места за период: наряд, пост и сутки выхода. */
async function listAssignedSlots(dutyTypeId, from, to) {
  const { rows } = await db.query(`
    SELECT da.duty_id, da.post_id, to_char(da.on_date, 'YYYY-MM-DD') AS on_date,
           to_char(d.starts_at, 'YYYY-MM-DD') AS start_date
    FROM duty.duty_assignments da
    JOIN duty.duties d      ON d.id = da.duty_id AND d.status <> 'cancelled'
    JOIN duty.duty_posts p  ON p.id = da.post_id AND p.is_active
    WHERE d.duty_type_id = $1 AND d.starts_at >= $2::date AND d.starts_at < $3::date + 1
  `, [dutyTypeId, from, to]);
  return rows;
}

/** Очередь подразделений по постам вида наряда. */
async function listPostUnits(dutyTypeId) {
  const { rows } = await db.query(`
    SELECT pu.post_id, pu.turn, pu.unit_id, u.short_name AS unit_short
    FROM duty.post_units pu
    JOIN duty.duty_posts p ON p.id = pu.post_id
    JOIN core.units u      ON u.id = pu.unit_id
    WHERE $1::int IS NULL OR p.duty_type_id = $1
    ORDER BY pu.post_id, pu.turn
  `, [dutyTypeId || null]);
  return rows;
}

/** Замена очереди поста целиком: форма присылает итоговый порядок. */
async function setPostUnits(postId, unitIds, rotationSince) {
  return db.transaction(async (client) => {
    await client.query('DELETE FROM duty.post_units WHERE post_id = $1', [postId]);

    if (unitIds.length > 0) {
      await client.query(`
        INSERT INTO duty.post_units (post_id, turn, unit_id)
        SELECT $1, ordinality, unit_id
        FROM unnest($2::int[]) WITH ORDINALITY AS a(unit_id, ordinality)
      `, [postId, unitIds]);
    }

    // Принадлежность поста — СЛЕДСТВИЕ очереди, а не отдельная настройка:
    // одно заступающее подразделение и есть подразделение поста; несколько
    // (или ни одного) — пост общий. Два поля об одном расходились при первой
    // же правке.
    await client.query(`
      UPDATE duty.duty_posts
         SET rotation_since = $2,
             unit_id        = $3
       WHERE id = $1
    `, [postId, unitIds.length > 1 ? rotationSince : null,
      unitIds.length === 1 ? unitIds[0] : null]);
  });
}

/**
 * Закрепленный за постами личный состав.
 *
 * Возвращаются только идентификаторы: фамилии живут в модуле «Личный состав»,
 * и тянуть их сюда соединением значило бы завести вторую дверь в чужой модуль.
 */
async function listPostEmployees(postId) {
  const { rows } = await db.query(`
    SELECT post_id, employee_id, note
    FROM duty.post_employees
    WHERE $1::int IS NULL OR post_id = $1
    ORDER BY post_id, employee_id
  `, [postId || null]);
  return rows;
}

/**
 * Закрепленный состав поста — ВСЕМ набором: форма поста присылает перечень
 * целиком, и сравнивать его с прежним поштучно незачем.
 */
async function setPostEmployees(postId, employeeIds, userId) {
  return db.transaction(async (client) => {
    await client.query('DELETE FROM duty.post_employees WHERE post_id = $1', [postId]);
    if (employeeIds.length === 0) return;

    await client.query(`
      INSERT INTO duty.post_employees (post_id, employee_id, created_by)
      SELECT $1, id, $3 FROM unnest($2::int[]) AS a(id)
    `, [postId, employeeIds, userId || null]);
  });
}

/**
 * Что держит пост: назначения в наряды и допуски, выданные к нему.
 *
 * Прошлые наряды ссылаются на пост, и стирать его значило бы стирать историю,
 * поэтому такой пост только снимается с применения. Все прочее — очередь
 * подразделений, точечные закрепления, веса — удаляется вместе с постом:
 * это его собственные настройки, и держать их незачем.
 */
async function postUsage(id) {
  const { rows } = await db.query(`
    SELECT (SELECT count(*)::int FROM duty.duty_assignments WHERE post_id = $1)      AS assignments,
           (SELECT count(*)::int FROM personnel.employee_permits WHERE post_id = $1) AS permits,
           (SELECT count(*)::int FROM duty.post_units WHERE post_id = $1)            AS units,
           ((SELECT count(*) FROM duty.post_responsibilities WHERE post_id = $1)
            + (SELECT count(*) FROM duty.post_rank_weights WHERE post_id = $1)
            + (SELECT count(*) FROM personnel.employee_post_weights WHERE post_id = $1))::int
               AS settings
  `, [id]);
  return rows[0];
}

/** Сколько назначений у каждого поста: от этого зависит, можно ли его удалить. */
async function postAssignmentCounts() {
  const { rows } = await db.query(`
    SELECT post_id, count(*)::int AS n FROM duty.duty_assignments GROUP BY post_id
  `);
  return rows;
}

/**
 * Снятие с применения и возврат.
 *
 * Снятый пост уходит из будущих, еще не наступивших нарядов — то же правило,
 * что при снятии из карточки поста: состав не должен держать место, которого
 * больше нет. Прошлые наряды не трогаются.
 */
/**
 * Новая версия шаблона приказа: запись в историю и текущий шаблон вида.
 * template = null — возврат к шаблону по умолчанию (тоже версия).
 * @returns {number} номер версии
 */
async function setOrderTemplate(typeId, template, reason, userId) {
  return db.transaction(async () => {
    const json = template === null ? null : JSON.stringify(template);
    const { rows } = await db.query(`
      INSERT INTO duty.order_template_versions (duty_type_id, version, template, reason, created_by)
      SELECT $1, coalesce(max(version), 0) + 1, $2::jsonb, $3, $4
      FROM duty.order_template_versions WHERE duty_type_id = $1
      RETURNING version
    `, [typeId, json, reason, userId || null]);
    await db.query('UPDATE duty.duty_types SET order_template = $2 WHERE id = $1', [typeId, json]);
    return rows[0].version;
  });
}

/** История шаблона приказа вида: новые сверху. */
async function orderTemplateVersions(typeId) {
  const { rows } = await db.query(`
    SELECT v.id, v.version, v.template, v.reason, v.created_at, u.login AS author
    FROM duty.order_template_versions v
    LEFT JOIN core.users u ON u.id = v.created_by
    WHERE v.duty_type_id = $1
    ORDER BY v.version DESC
  `, [typeId]);
  return rows;
}


/** Порядок видов нарядов по перечню: 10, 20, 30… */
async function setDutyTypeOrder(ids) {
  await db.query(`
    UPDATE duty.duty_types t SET sort_order = o.n * 10
    FROM unnest($1::int[]) WITH ORDINALITY AS o(id, n)
    WHERE t.id = o.id
  `, [ids]);
}

/**
 * Порядок постов вида наряда по перечню: 10, 20, 30… — с шагом, чтобы пост
 * можно было вставить между соседями и вручную, полем «Порядок в приказе».
 */
async function setPostOrder(typeId, ids) {
  await db.query(`
    UPDATE duty.duty_posts p SET sort_order = o.n * 10
    FROM unnest($2::int[]) WITH ORDINALITY AS o(id, n)
    WHERE p.id = o.id AND p.duty_type_id = $1
  `, [typeId, ids]);
}

async function setPostActive(id, active) {
  return db.transaction(async (client) => {
    await client.query('UPDATE duty.duty_posts SET is_active = $2 WHERE id = $1', [id, active]);
    if (!active) {
      await client.query(`DELETE FROM duty.duty_assignments a USING duty.duties d
        WHERE a.duty_id = d.id AND a.post_id = $1 AND d.start_date > CURRENT_DATE
          AND d.status <> 'cancelled'`, [id]);
    }
  });
}

async function deletePost(id) {
  await db.query('DELETE FROM duty.duty_posts WHERE id = $1', [id]);
}

/** Точечные закрепления постов за период. */
async function listPostResponsibilities(dutyTypeId, from, to) {
  const { rows } = await db.query(`
    SELECT pr.post_id, to_char(pr.on_date, 'YYYY-MM-DD') AS on_date,
           pr.unit_id, pr.note, u.short_name AS unit_short
    FROM duty.post_responsibilities pr
    JOIN duty.duty_posts p ON p.id = pr.post_id
    JOIN core.units u      ON u.id = pr.unit_id
    WHERE p.duty_type_id = $1 AND pr.on_date >= $2::date AND pr.on_date <= $3::date
  `, [dutyTypeId, from, to]);
  return rows;
}

async function setPostResponsibility(postId, onDate, unitId, note, userId) {
  if (!unitId) {
    const { rowCount } = await db.query(
      'DELETE FROM duty.post_responsibilities WHERE post_id = $1 AND on_date = $2::date',
      [postId, onDate],
    );
    return rowCount;
  }

  const { rowCount } = await db.query(`
    INSERT INTO duty.post_responsibilities (post_id, on_date, unit_id, note, assigned_by)
    VALUES ($1, $2::date, $3, $4, $5)
    ON CONFLICT (post_id, on_date)
      DO UPDATE SET unit_id = excluded.unit_id, note = excluded.note,
                    assigned_by = excluded.assigned_by, assigned_at = now()
  `, [postId, onDate, unitId, note || null, userId || null]);
  return rowCount;
}

// ----------------------------------------------------------------------------
// Оружие на наряд
//
// Человеку без своего оружия нужного вида оружие выбирают при назначении —
// из оружия тех, кто не занят в эти и следующие сутки: оружие получают до
// заступления, а владелец не может отдать его, пока сам не сменится. Выбор
// хранится в назначении (weapon_id).
//
// «Окно» места — с начала суток заступления до конца суток после сдачи:
// [дата заступления, дата сдачи + 1). Два окна одного оружия не должны
// пересекаться, и владелец не должен НЕСТИ это оружие в наряде внутри окна.
// Владелец в наряде без оружия (или с другим видом) оружию не помеха — такое
// оружие предлагается первым.
// ----------------------------------------------------------------------------

const WINDOW_START = (alias) => `${alias}.starts_at::date::timestamptz`;
const WINDOW_END = (alias) => `(${alias}.ends_at::date + 1)::timestamptz`;
const PERSON_LABEL = (alias, rank) => `concat_ws(' ', ${rank}.short_name, ${alias}.last_name)`;

/**
 * Владелец сам несет это оружие в наряде, пересекающем окно: стоит на посту,
 * где выдается оружие того же вида, и ходит со своим (чужое ему не выбрано).
 * Наряд без оружия или с другим видом владельцу оружие не нужен — оно
 * свободно, и его как раз выгоднее всего отдать.
 */
const OWNER_CARRIES = (weapon, ws, we) => `
  SELECT 1 FROM duty.v_assignment_periods o
  JOIN duty.duty_assignments od ON od.id = o.id
  JOIN duty.duty_posts op       ON op.id = o.post_id
  WHERE ${weapon}.holder_id IS NOT NULL AND o.employee_id = ${weapon}.holder_id
    AND o.status <> 'cancelled' AND o.starts_at < ${we} AND o.ends_at > ${ws}
    AND op.required_weapon_kind = ${weapon}.kind AND od.weapon_id IS NULL`;

/** Владелец в наряде внутри окна, но оружие ему там не нужно. */
const OWNER_ON_DUTY = (weapon, ws, we) => `
  SELECT 1 FROM duty.v_assignment_periods o
  WHERE ${weapon}.holder_id IS NOT NULL AND o.employee_id = ${weapon}.holder_id
    AND o.status <> 'cancelled' AND o.starts_at < ${we} AND o.ends_at > ${ws}`;

/**
 * Оружие по назначениям: что требует пост, есть ли у человека годное свое,
 * какое выбрано и не нарушено ли правило (владелец в наряде, оружие выдано
 * другому в пересекающееся окно).
 */
async function weaponStatus(assignmentIds) {
  if (!assignmentIds || assignmentIds.length === 0) return [];
  const { rows } = await db.query(`
    WITH a AS (
      SELECT a.id, a.employee_id, da.weapon_id, p.required_weapon_kind AS kind,
             ${WINDOW_START('a')} AS ws, ${WINDOW_END('a')} AS we
      FROM duty.v_assignment_periods a
      JOIN duty.duty_assignments da ON da.id = a.id
      JOIN duty.duty_posts p        ON p.id = a.post_id
      WHERE a.id = ANY($1::int[])
    )
    SELECT a.id AS assignment_id, a.employee_id, a.kind,
           lw.id AS loan_id, lw.kind AS loan_kind, lw.name AS loan_name,
           lw.serial_number AS loan_serial, lw.is_active AS loan_active,
           extract(year FROM lw.manufactured_on)::int AS loan_year,
           ${PERSON_LABEL('lo', 'lr')} AS loan_owner,
           own.id AS own_id, own.name AS own_name, own.serial_number AS own_serial,
           extract(year FROM own.manufactured_on)::int AS own_year,
           CASE WHEN EXISTS (${OWNER_CARRIES('lw', 'a.ws', 'a.we')})
                THEN ${PERSON_LABEL('lo', 'lr')} END AS owner_busy,
           (SELECT ${PERSON_LABEL('e', 'r')}
              FROM duty.v_assignment_periods o
              JOIN duty.duty_assignments od ON od.id = o.id
              JOIN personnel.employees e ON e.id = o.employee_id
              LEFT JOIN core.ranks r     ON r.id = e.rank_id
             WHERE od.weapon_id = a.weapon_id AND o.id <> a.id AND o.status <> 'cancelled'
               AND ${WINDOW_START('o')} < a.we AND ${WINDOW_END('o')} > a.ws
             LIMIT 1) AS given_to
    FROM a
    LEFT JOIN personnel.v_weapons lw ON lw.id = a.weapon_id
    LEFT JOIN personnel.employees lo ON lo.id = lw.holder_id
    LEFT JOIN core.ranks lr          ON lr.id = lo.rank_id
    LEFT JOIN LATERAL (
      -- Свое годное: закреплено за человеком, нужного вида и не выдано
      -- другому на пересекающееся окно.
      -- Свое — числящееся за человеком: закрепленное, а у командира еще и
      -- незакрепленное оружие его подразделения.
      SELECT w.* FROM personnel.v_weapons w
      WHERE w.holder_id = a.employee_id AND w.is_active AND w.kind = a.kind
        AND NOT EXISTS (SELECT 1 FROM personnel.weapon_reservations z
                        WHERE z.weapon_id = w.id AND z.cancelled_at IS NULL
                          AND z.date_from::timestamptz < a.we AND (z.date_to + 1)::timestamptz > a.ws)
        AND NOT EXISTS (
          SELECT 1 FROM duty.v_assignment_periods o
          JOIN duty.duty_assignments od ON od.id = o.id
          WHERE od.weapon_id = w.id AND o.id <> a.id AND o.status <> 'cancelled'
            AND ${WINDOW_START('o')} < a.we AND ${WINDOW_END('o')} > a.ws)
      ORDER BY w.id LIMIT 1
    ) own ON true
  `, [assignmentIds]);
  return rows;
}

/**
 * Свободное оружие для групп мест: одна группа — один вид оружия и одно
 * окно. Свободно оружие, владелец которого не стоит в наряде внутри окна
 * (или владельца нет — оружие в хранилище) и которое не выдано никому на
 * пересекающееся окно.
 *
 * @param {Array<{key:string, from:string, to:string, kind:string}>} groups
 *   from/to — даты окна: сутки заступления и сутки после сдачи (включительно)
 */
async function freeWeapons(groups) {
  if (!groups || groups.length === 0) return [];
  const { rows } = await db.query(`
    WITH g AS (
      SELECT key, from_day::timestamptz AS ws, (to_day + 1)::timestamptz AS we, kind
      FROM unnest($1::text[], $2::date[], $3::date[], $4::text[]) AS g(key, from_day, to_day, kind)
    )
    SELECT g.key, w.id, w.name, w.serial_number, w.kind, w.holder_id AS owner_id,
           extract(year FROM w.manufactured_on)::int AS year,
           ${PERSON_LABEL('o', 'r')} AS owner,
           EXISTS (${OWNER_ON_DUTY('w', 'g.ws', 'g.we')}) AS owner_on_duty
    FROM g
    JOIN personnel.v_weapons w   ON w.is_active AND w.kind = g.kind
    LEFT JOIN personnel.employees o ON o.id = w.holder_id
    LEFT JOIN core.ranks r          ON r.id = o.rank_id
    WHERE NOT EXISTS (${OWNER_CARRIES('w', 'g.ws', 'g.we')})
      -- Занято на срок (караул, стрельбы — по приказу).
      AND NOT EXISTS (SELECT 1 FROM personnel.weapon_reservations z
                      WHERE z.weapon_id = w.id AND z.cancelled_at IS NULL
                        AND z.date_from::timestamptz < g.we AND (z.date_to + 1)::timestamptz > g.ws)
      AND NOT EXISTS (
            SELECT 1 FROM duty.v_assignment_periods a
            JOIN duty.duty_assignments da ON da.id = a.id
            WHERE da.weapon_id = w.id AND a.status <> 'cancelled'
              AND ${WINDOW_START('a')} < g.we AND ${WINDOW_END('a')} > g.ws)
    -- Первым — оружие владельцев, заступающих туда, где оно им не нужно:
    -- оно гарантированно лежит без дела.
    ORDER BY g.key, EXISTS (${OWNER_ON_DUTY('w', 'g.ws', 'g.we')}) DESC,
             o.last_name NULLS FIRST, w.serial_number
  `, [groups.map((x) => x.key), groups.map((x) => x.from), groups.map((x) => x.to),
    groups.map((x) => x.kind)]);
  return rows;
}

/** Кто владеет действующим оружием какого вида: { rifle: [ids], pistol: [ids] }. */
async function armedOwners() {
  const { rows } = await db.query(`
    SELECT kind, array_agg(DISTINCT holder_id) AS ids
    FROM personnel.v_weapons WHERE is_active AND holder_id IS NOT NULL
    GROUP BY kind
  `);
  return Object.fromEntries(rows.map((r) => [r.kind, r.ids]));
}

/**
 * Выбранное оружие мест наряда. Меняет только отличающиеся; возвращает
 * число измененных мест.
 *
 * @param {Array<{postId:number, onDate:?string, weaponId:?number}>} items
 */
async function setAssignmentWeapons(dutyId, items) {
  if (items.length === 0) return 0;
  const { rowCount } = await db.query(`
    UPDATE duty.duty_assignments da SET weapon_id = x.weapon_id
    FROM unnest($2::int[], $3::date[], $4::int[]) AS x(post_id, on_date, weapon_id)
    WHERE da.duty_id = $1 AND da.post_id = x.post_id
      AND coalesce(da.on_date, '-infinity'::date) = coalesce(x.on_date, '-infinity'::date)
      AND da.weapon_id IS DISTINCT FROM x.weapon_id
  `, [dutyId, items.map((i) => i.postId), items.map((i) => i.onDate || null),
    items.map((i) => i.weaponId ?? null)]);
  return rowCount;
}

/**
 * Наряды человека за период (для «Моих данных»): вид, пост, время, статус
 * приказа и выданное оружие. Отмененные не показываются.
 */
async function employeeAssignments(employeeId, from, to) {
  const { rows } = await db.query(`
    SELECT a.id, a.duty_id, a.status, to_char(a.start_date, 'YYYY-MM-DD') AS start_date,
           a.starts_at, a.ends_at, dt.name AS duty_name, dt.code AS duty_code, p.name AS post_name,
           w.name AS weapon_name, w.serial_number
    FROM duty.v_assignment_periods a
    JOIN duty.duty_types dt       ON dt.id = a.duty_type_id
    JOIN duty.duty_posts p        ON p.id = a.post_id
    JOIN duty.duty_assignments da ON da.id = a.id
    LEFT JOIN personnel.weapons w ON w.id = da.weapon_id
    WHERE a.employee_id = $1 AND a.status <> 'cancelled'
      AND a.start_date BETWEEN $2::date AND $3::date
    ORDER BY a.starts_at
  `, [employeeId, from, to]);
  return rows;
}

module.exports = {
  employeeAssignments,
  listStoredOrders,
  dropFutureAssignments,
  weaponStatus,
  freeWeapons,
  armedOwners,
  setAssignmentWeapons,
  setPostOrder,
  setDutyTypeOrder,
  setOrderTemplate,
  orderTemplateVersions,
 markOverride,saveSnapshot,listFutureDuties,rootUnit,
  listDutyTypes,
  listAllDutyTypes,
  createDutyType,
  updateDutyType,
  setSchedules,
  setGeneralPermits,
  dutyTypeUsage,
  deleteDutyType,
  getDutyType,
  getSchedules,
  getGeneralPermits,
  listPosts,
  listAllPosts,
  getPost,
  createPost,
  updatePost,
  listUnits,
  findBusyEmployeeIds,
  findRecentDutyEnds,
  findEmployeesOnDuty,
  findEmployeesStartingOn,
  employeeWorkload,
  countActivePosts,
  listDutiesInRange,
  findDutiesOnDates,
  listAssignmentsInRange,
  getAssignmentsForDuties,
  approveDuties,
  unapproveDuties,
  replaceAssignment,
  withdrawEmployee,
  updateAssignments,
  listSettings,
  setSetting,
  lastDutyEnds,
  listPostRankWeights,
  setPostRankWeights,
  listEmployeePostWeights,
  setEmployeePostWeight,
  listAssignedSlots,
  listPostUnits,
  setPostUnits,
  postUsage,
  deletePost,
  postAssignmentCounts,
  setPostActive,
  listPostEmployees,
  setPostEmployees,
  listPostResponsibilities,
  setPostResponsibility,
  listCalendarDays,
  setCalendarRange,
  deleteCalendarRange,
  listDuties,
  getDuty,
  getAssignments,
  createDuty,
};
