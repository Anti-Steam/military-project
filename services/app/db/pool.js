'use strict';

// Единая точка доступа к БД для всего сервиса (раздел 3.2 ТЗ).
// Модули не создают собственных подключений — только используют этот пул.

const { Pool } = require('pg');
const { AsyncLocalStorage } = require('node:async_hooks');
const context = new AsyncLocalStorage();
// Кто работает — для журнала изменений (audit.changes): запрос пользователя
// выполняется внутри asUser(), и база узнает его номер параметром
// app.user_id. Вне asUser() (миграции, служебные работы) — «система».
const actor = new AsyncLocalStorage();
const WRITE = /^\s*(insert|update|delete|with|merge)\b/i;
const config = require('../config');

const pool = new Pool({
  ...config.db,
  max: 10,                       // до 50 одновременных пользователей — запас достаточный
  idleTimeoutMillis: 30000,
  connectionTimeoutMillis: 5000,
});

pool.on('error', (err) => {
  console.error('Ошибка простаивающего соединения с БД:', err.message);
});

/**
 * Выполнить запрос. Значения передаются ТОЛЬКО параметрами ($1, $2, ...) —
 * подстановка значений в текст запроса недопустима.
 */
function query(text, params) {
  const state=context.getStore();
  const userId=actor.getStore();
  // Запись вне транзакции от имени пользователя — короткой транзакцией с его
  // номером, чтобы журнал знал автора. Чтение — как обычно.
  if(!state && userId && WRITE.test(text)) return transaction(() => query(text, params));
  if(!state) return pool.query(text,params);
  const result=state.queue.then(()=>state.client.query(text,params));
  state.queue=result.catch(()=>{});
  return result;
}

/**
 * Выполнить несколько запросов в одной транзакции.
 * Колбэку передается клиент; при исключении выполняется откат.
 */
async function transaction(fn) {
  // Вложенная транзакция — точка сохранения внутри внешней: если вложенная
  // часть падает, откатывается только она, и внешний код, поймавший ошибку,
  // не продолжает с ее половиной записей.
  const outer = context.getStore();
  if (outer) {
    outer.savepoints = (outer.savepoints || 0) + 1;
    const name = `nested_${outer.savepoints}`;
    await query(`SAVEPOINT ${name}`);
    try {
      const result = await fn(outer.client);
      await query(`RELEASE SAVEPOINT ${name}`);
      return result;
    } catch (err) {
      await query(`ROLLBACK TO SAVEPOINT ${name}`);
      throw err;
    }
  }
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    // Все изменения MVP используют одну блокировку до конца транзакции.
    // Проверка и запись сериализованы, включая оружие и календарь.
    await client.query('SELECT pg_advisory_xact_lock(734821)');
    const userId = actor.getStore();
    if (userId) await client.query("SELECT set_config('app.user_id', $1, true)", [String(userId)]);
    const result = await context.run({client,queue:Promise.resolve()}, () => fn(client));
    await client.query('COMMIT');
    return result;
  } catch (err) {
    await client.query('ROLLBACK');
    throw err;
  } finally {
    client.release();
  }
}

/** Выполнить fn от имени пользователя: его изменения журнал запишет за ним. */
function asUser(userId, fn) {
  return userId ? actor.run(Number(userId), fn) : fn();
}

module.exports = { pool, query, transaction, asUser };
