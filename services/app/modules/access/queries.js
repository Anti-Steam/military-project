'use strict';

// SQL модуля разграничения доступа.
// Обращаться сюда напрямую вправе только access/service.js.

const db = require('../../db/pool');

const USER_FIELDS = `
    u.id, u.login, u.role_code, u.employee_id, u.is_active,
    u.failed_attempts, u.locked_until, u.must_change_password,
    u.password_changed_at, u.last_login_at, u.created_at, u.scope_unit_id
`;

async function findByLogin(login) {
  const { rows } = await db.query(
    `SELECT ${USER_FIELDS}, u.password_hash FROM core.users u WHERE lower(u.login) = lower($1)`,
    [login],
  );
  return rows[0] || null;
}

async function findById(id) {
  const { rows } = await db.query(`SELECT ${USER_FIELDS} FROM core.users u WHERE u.id = $1`, [id]);
  return rows[0] || null;
}

/** Учетные записи вместе с сотрудником и числом точечных правок прав. */
async function listUsers() {
  const { rows } = await db.query(`
    SELECT ${USER_FIELDS},
           r.name AS role_name, r.level AS role_level,
           su.short_name AS scope_unit_short,
           concat_ws(' ', e.last_name, e.first_name, e.middle_name) AS full_name,
           un.short_name AS unit_short,
           -- Вход заблокирован с этих компьютеров (после неверных попыток).
           (SELECT max(f.locked_until) FROM core.login_failures f
             WHERE f.user_id = u.id AND f.locked_until > now()) AS locked_ip_until,
           (SELECT string_agg(f.ip, ', ' ORDER BY f.ip) FROM core.login_failures f
             WHERE f.user_id = u.id AND f.locked_until > now()) AS locked_ips,
           count(up.permission_code) FILTER (WHERE up.granted)::int      AS granted_extra,
           count(up.permission_code) FILTER (WHERE NOT up.granted)::int  AS revoked_extra
    FROM core.users u
    JOIN core.roles r ON r.code = u.role_code
    LEFT JOIN personnel.employees e ON e.id = u.employee_id
    LEFT JOIN core.units un         ON un.id = e.unit_id
    LEFT JOIN core.units su         ON su.id = u.scope_unit_id
    LEFT JOIN core.user_permissions up ON up.user_id = u.id
    GROUP BY u.id, r.name, r.level, su.short_name, e.last_name, e.first_name, e.middle_name, un.short_name
    ORDER BY r.level, u.login
  `);
  return rows;
}

async function listRoles() {
  const { rows } = await db.query('SELECT code, name, level FROM core.roles ORDER BY level');
  return rows;
}

async function listPermissions() {
  const { rows } = await db.query(
    'SELECT code, name, section, sort_order FROM core.permissions ORDER BY sort_order',
  );
  return rows;
}

/** Права роли — набор по умолчанию. */
async function rolePermissions(roleCode) {
  const { rows } = await db.query(
    'SELECT permission_code FROM core.role_permissions WHERE role_code = $1',
    [roleCode],
  );
  return rows.map((r) => r.permission_code);
}

/** Точечные правки прав конкретной учетной записи. */
async function userPermissions(userId) {
  const { rows } = await db.query(`
    SELECT permission_code, granted, note, granted_at
    FROM core.user_permissions WHERE user_id = $1
  `, [userId]);
  return rows;
}

/**
 * Действующие права: набор роли, исправленный точечными правками.
 *
 * Запрет сильнее роли — иначе отнять право у одного человека было бы нечем.
 */
async function effectivePermissions(userId) {
  const { rows } = await db.query(`
    SELECT p.code
    FROM core.users u
    CROSS JOIN core.permissions p
    LEFT JOIN core.role_permissions rp
           ON rp.role_code = u.role_code AND rp.permission_code = p.code
    LEFT JOIN core.user_permissions up
           ON up.user_id = u.id AND up.permission_code = p.code
    WHERE u.id = $1
      AND u.is_active
      AND coalesce(up.granted, rp.permission_code IS NOT NULL)
  `, [userId]);
  return rows.map((r) => r.code);
}

/** Права роли — для прав ВРИО командира (роль «Командир»). */
async function rolePermissionCodes(roleCode) {
  const { rows } = await db.query(
    'SELECT permission_code FROM core.role_permissions WHERE role_code = $1', [roleCode]);
  return rows.map((r) => r.permission_code);
}

async function createUser({ login, passwordHash, roleCode, employeeId, scopeUnitId, createdBy }) {
  const { rows } = await db.query(`
    INSERT INTO core.users (login, password_hash, role_code, employee_id, scope_unit_id,
                            must_change_password, password_changed_at, created_by)
    VALUES ($1, $2, $3, $4, $6, true, now(), $5)
    RETURNING id
  `, [login, passwordHash, roleCode, employeeId || null, createdBy || null, scopeUnitId || null]);
  return rows[0].id;
}

async function updateUser(id, { roleCode, employeeId, isActive, scopeUnitId }) {
  await db.query(`
    UPDATE core.users
       SET role_code = $2, employee_id = $3, is_active = $4, scope_unit_id = $5,
           updated_at = now()
     WHERE id = $1
  `, [id, roleCode, employeeId || null, isActive, scopeUnitId || null]);
}

/**
 * Замена точечных правок прав одним действием.
 *
 * Правки переписываются целиком: форма присылает итоговое состояние, и
 * дописывание к прежнему набору оставило бы снятые галочки в силе.
 */
async function setUserPermissions(userId, items, actorId) {
  return db.transaction(async (client) => {
    await client.query('DELETE FROM core.user_permissions WHERE user_id = $1', [userId]);

    if (items.length > 0) {
      await client.query(`
        INSERT INTO core.user_permissions (user_id, permission_code, granted, granted_by)
        SELECT $1, code, granted, $4
        FROM unnest($2::text[], $3::boolean[]) AS a(code, granted)
      `, [userId, items.map((i) => i.code), items.map((i) => i.granted), actorId || null]);
    }
  });
}

async function setPassword(id, passwordHash, mustChange) {
  await db.query(`
    UPDATE core.users
       SET password_hash = $2, must_change_password = $3, password_changed_at = now(),
           failed_attempts = 0, locked_until = NULL, updated_at = now()
     WHERE id = $1
  `, [id, passwordHash, mustChange]);
  await db.query('DELETE FROM core.login_failures WHERE user_id = $1', [id]);
}

// Неверные попытки — по паре «учетная запись + адрес компьютера»: с чужого
// компьютера человека не запереть, блокируется вход только оттуда.

/** Блокировка входа с этого адреса (null — нет). */
async function lockedFrom(userId, ip) {
  const { rows } = await db.query(`
    SELECT locked_until FROM core.login_failures WHERE user_id = $1 AND ip = $2 AND locked_until > now()
  `, [userId, ip]);
  return rows[0] ? rows[0].locked_until : null;
}

/** Неудачная попытка входа; при исчерпании — блокировка на указанный срок. */
async function registerFailure(id, ip, limit, lockMinutes) {
  const { rows } = await db.query(`
    INSERT INTO core.login_failures AS f (user_id, ip, failed_attempts, locked_until)
    VALUES ($1, $2, 1, CASE WHEN $3 <= 1 THEN now() + make_interval(mins => $4) END)
    ON CONFLICT (user_id, ip) DO UPDATE SET
      failed_attempts = CASE WHEN f.locked_until <= now() THEN 1 ELSE f.failed_attempts + 1 END,
      locked_until = CASE WHEN (CASE WHEN f.locked_until <= now() THEN 1 ELSE f.failed_attempts + 1 END) >= $3
                          THEN now() + make_interval(mins => $4) END,
      updated_at = now()
    RETURNING failed_attempts, locked_until
  `, [id, ip, limit, lockMinutes]);
  return rows[0];
}

async function registerSuccess(id, ip) {
  await db.query('DELETE FROM core.login_failures WHERE user_id = $1 AND ip = $2', [id, ip]);
  await db.query('UPDATE core.users SET last_login_at = now(), updated_at = now() WHERE id = $1', [id]);
}

/** Снять блокировку — со всех компьютеров. */
async function unlock(id) {
  await db.query('DELETE FROM core.login_failures WHERE user_id = $1', [id]);
}

/** Отключить учетную запись (исключение владельца из списков). */
async function deactivate(id) {
  await db.query('UPDATE core.users SET is_active = false, updated_at = now() WHERE id = $1', [id]);
}

// ----------------------------------------------------------------------------
// Сессии
// ----------------------------------------------------------------------------

async function createSession({ id, userId, csrfToken, expiresAt, ip, userAgent }) {
  await db.query(`
    INSERT INTO core.sessions (id, user_id, csrf_token, expires_at, ip, user_agent)
    VALUES ($1, $2, $3, $4, $5, $6)
  `, [id, userId, csrfToken, expiresAt, ip || null, userAgent || null]);
}

/**
 * Сессия вместе с владельцем. Просроченные и принадлежащие отключенным
 * учетным записям не возвращаются: проверка идет при каждом обращении, а не
 * только при входе.
 */
async function findSession(id) {
  const { rows } = await db.query(`
    SELECT s.id AS session_id, s.user_id, s.csrf_token, s.expires_at,
           -- Имя не должно совпадать с полем учетной записи: иначе предельный
           -- срок сессии считался бы от даты заведения записи.
           s.created_at AS session_created_at,
           ${USER_FIELDS}, r.level AS role_level
    FROM core.sessions s
    JOIN core.users u ON u.id = s.user_id
    JOIN core.roles r ON r.code = u.role_code
    WHERE s.id = $1 AND s.expires_at > now() AND u.is_active
  `, [id]);
  return rows[0] || null;
}

async function touchSession(id, expiresAt) {
  await db.query(
    'UPDATE core.sessions SET last_seen_at = now(), expires_at = $2 WHERE id = $1',
    [id, expiresAt],
  );
}

async function deleteSession(id) {
  await db.query('DELETE FROM core.sessions WHERE id = $1', [id]);
}

/** Завершение всех сессий учетной записи: смена пароля, прав, отключение. */
async function deleteUserSessions(userId) {
  const { rowCount } = await db.query('DELETE FROM core.sessions WHERE user_id = $1', [userId]);
  return rowCount;
}

/** Действующие сеансы записи: где и когда вошли, когда были в последний раз. */
async function listUserSessions(userId) {
  const { rows } = await db.query(`
    SELECT id, created_at, last_seen_at, expires_at, ip, user_agent
    FROM core.sessions WHERE user_id = $1 AND expires_at > now()
    ORDER BY last_seen_at DESC
  `, [userId]);
  return rows;
}

/** Завершить все сеансы, кроме указанного (текущего). */
async function deleteOtherSessions(userId, keepId) {
  const { rowCount } = await db.query('DELETE FROM core.sessions WHERE user_id = $1 AND id <> $2', [userId, keepId]);
  return rowCount;
}

async function purgeExpiredSessions() {
  const { rowCount } = await db.query('DELETE FROM core.sessions WHERE expires_at <= now()');
  return rowCount;
}

// ----------------------------------------------------------------------------
// Журнал событий
// ----------------------------------------------------------------------------

async function logEvent({ kind, userId, actorId, login, detail, ip }) {
  await db.query(`
    INSERT INTO core.security_events (kind, user_id, actor_id, login, detail, ip)
    VALUES ($1, $2, $3, $4, $5, $6)
  `, [kind, userId || null, actorId || null, login || null, detail || null, ip || null]);
}

/**
 * События журнала доступа: новые первыми, с фильтрами. before — id, с
 * которого листать дальше («Раньше →»); login — учетная запись (ее события
 * и выполненные ею), в том числе набранный при входе несуществующий логин.
 */
async function listEvents({ limit = 200, before = null, from = null, to = null, login = null, kinds = null } = {}) {
  const { rows } = await db.query(`
    SELECT e.id, e.at, e.kind, e.login, e.detail, e.ip,
           u.login AS user_login, a.login AS actor_login
    FROM core.security_events e
    LEFT JOIN core.users u ON u.id = e.user_id
    LEFT JOIN core.users a ON a.id = e.actor_id
    WHERE ($2::bigint IS NULL OR e.id < $2)
      AND ($3::date IS NULL OR e.at >= $3::date)
      AND ($4::date IS NULL OR e.at < $4::date + 1)
      AND ($5::text IS NULL OR lower(coalesce(u.login, e.login)) = lower($5) OR lower(a.login) = lower($5))
      AND ($6::text[] IS NULL OR e.kind = ANY($6))
    ORDER BY e.id DESC
    LIMIT $1
  `, [limit, before, from, to, login, kinds]);
  return rows;
}

module.exports = {
  listUserSessions,
  deleteOtherSessions,
  lockedFrom,
  deactivate,
  rolePermissionCodes,
  findByLogin,
  findById,
  listUsers,
  listRoles,
  listPermissions,
  rolePermissions,
  userPermissions,
  effectivePermissions,
  createUser,
  updateUser,
  setUserPermissions,
  setPassword,
  registerFailure,
  registerSuccess,
  unlock,
  createSession,
  findSession,
  touchSession,
  deleteSession,
  deleteUserSessions,
  purgeExpiredSessions,
  logEvent,
  listEvents,
};
