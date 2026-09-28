'use strict';

// SQL модуля «Журнал изменений» (МС-4). Журнал пишут триггеры базы
// (миграция 056); модуль его только читает.

const db = require('../../db/pool');

/**
 * Записи журнала с фильтрами. employeeId — все, что касается человека:
 * сама его запись и записи, где он указан (отсутствия, должность, оружие,
 * наряды, допуски).
 */
async function listChanges({ from, to, table, userId, employeeId, limit, before }) {
  const { rows } = await db.query(`
    SELECT c.id, c.changed_at, c.user_id, u.login, c.table_name, c.row_id, c.action, c.old_data, c.new_data
    FROM audit.changes c
    LEFT JOIN core.users u ON u.id = c.user_id
    WHERE ($1::date IS NULL OR c.changed_at >= $1::date)
      AND ($2::date IS NULL OR c.changed_at < $2::date + 1)
      AND ($3::text IS NULL OR c.table_name = $3)
      AND ($4::int IS NULL OR c.user_id = $4)
      AND ($5::text IS NULL
           OR (c.table_name = 'personnel.employees' AND c.row_id = $5)
           OR coalesce(c.new_data ->> 'employee_id', c.old_data ->> 'employee_id') = $5
           OR (c.table_name = 'personnel.weapons'
               AND (c.new_data ->> 'owner_id' = $5 OR c.old_data ->> 'owner_id' = $5)))
      AND ($7::bigint IS NULL OR c.id < $7)
    ORDER BY c.id DESC
    LIMIT $6
  `, [from || null, to || null, table || null, userId || null,
    employeeId ? String(employeeId) : null, limit, before || null]);
  return rows;
}

async function listAuthors() {
  const { rows } = await db.query(`
    SELECT DISTINCT u.id, u.login FROM audit.changes c JOIN core.users u ON u.id = c.user_id ORDER BY u.login
  `);
  return rows;
}

/** Подписи к номерам в записях: люди, подразделения, посты, виды нарядов. */
async function labels(ids) {
  const { rows } = await db.query(`
    SELECT 'employee' AS kind, e.id, concat_ws(' ', r.short_name, e.last_name, left(e.first_name, 1) || '.') AS label
      FROM personnel.employees e LEFT JOIN core.ranks r ON r.id = e.rank_id WHERE e.id = ANY($1::int[])
    UNION ALL SELECT 'unit', id, short_name FROM core.units WHERE id = ANY($2::int[])
    UNION ALL SELECT 'post', id, name FROM duty.duty_posts WHERE id = ANY($3::int[])
    UNION ALL SELECT 'type', id, code FROM duty.duty_types WHERE id = ANY($4::int[])
  `, [ids.employee, ids.unit, ids.post, ids.type]);
  return rows;
}

module.exports = { listChanges, listAuthors, labels };
