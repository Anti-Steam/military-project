'use strict';

// Общие средства проверок.
//
// Проверка — обычная async-функция, экспортированная из файла в tests/checks.
// Имя функции становится именем проверки. Ничего регистрировать вручную не
// нужно: запускатель сам находит файлы и функции. Добавление новой проверки —
// это добавление функции, а не правка запускателя.

const assert = require('node:assert/strict');

/** Накопитель утверждений одной проверки. */
class Case {
  constructor(name) {
    this.name = name;
    this.failures = [];
    this.count = 0;
  }

  /** Строгое равенство. */
  is(actual, expected, label) {
    this.count += 1;
    try {
      assert.deepStrictEqual(actual, expected);
    } catch {
      this.failures.push(`${label}: ожидалось ${JSON.stringify(expected)}, получено ${JSON.stringify(actual)}`);
    }
  }

  /** Условие истинно. */
  ok(condition, label) {
    this.count += 1;
    if (!condition) this.failures.push(label);
  }

  /** Вызов должен завершиться отказом. */
  async fails(fn, label) {
    this.count += 1;
    try {
      await fn();
      this.failures.push(`${label}: отказа не было`);
    } catch {
      // Отказ — это и есть ожидаемый исход.
    }
  }
}

const BASE = process.env.CHECK_URL || 'http://localhost:3000';

// Проверки ходят по страницам как настоящий пользователь: система закрыта
// входом, и обходить его ради проверок значило бы проверять не то, что
// работает у людей. Для этого заводится служебная учетная запись, она же
// удаляется после прогона — пароль нигде не хранится.
const CHECK_LOGIN = 'check.runner';
const CHECK_PASSWORD = require('node:crypto').randomBytes(24).toString('base64url');

let cookie = null;
let csrf = null;

async function signIn() {
  const access = require('../services/app/modules/access/service');
  const db = require('../services/app/db/pool');

  await db.query('DELETE FROM core.users WHERE login = $1', [CHECK_LOGIN]);
  const { id } = await access.createUser({
    login: CHECK_LOGIN, roleCode: 'admin', permissions: [], actorId: null,
  });

  // Временный пароль подлежит смене при первом входе — задается сразу
  // рабочий, иначе все страницы уводили бы на форму смены.
  const password = require('../services/app/modules/access/password');
  await db.query(
    'UPDATE core.users SET password_hash = $2, must_change_password = false WHERE id = $1',
    [id, await password.hash(CHECK_PASSWORD)],
  );

  const response = await fetch(`${BASE}/login`, {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ login: CHECK_LOGIN, password: CHECK_PASSWORD }).toString(),
    redirect: 'manual',
  });

  const set = response.headers.get('set-cookie');
  if (!set) throw new Error('вход служебной учетной записи не удался');
  cookie = set.split(';')[0];

  // Токен формы берется с любой страницы: он один на сессию.
  const page = await fetch(`${BASE}/password`, { headers: { cookie } });
  csrf = (/name="_csrf" value="([^"]+)"/.exec(await page.text()) || [])[1] || null;
}

async function signOut() {
  const db = require('../services/app/db/pool');
  await db.query('DELETE FROM core.users WHERE login = $1', [CHECK_LOGIN]);
  cookie = null;
}

/**
 * Запрос к работающему приложению. Если оно не запущено, проверки страниц
 * сообщают об этом, а не падают с непонятной ошибкой сети.
 */
async function get(path) {
  const response = await fetch(BASE + path, { headers: cookie ? { cookie } : {}, redirect: 'manual' });
  return {
    status: response.status,
    body: await response.text(),
    // Заголовки нужны проверкам сессии: срок куки виден только в Set-Cookie.
    setCookie: response.headers.get('set-cookie'),
    // fetch сам просит и распаковывает gzip; заголовок остается для проверок.
    encoding: response.headers.get('content-encoding'),
  };
}

/** Тело формы: массив значений отправляется несколькими полями, как браузер. */
function formBody(fields) {
  const body = new URLSearchParams();
  for (const [key, value] of Object.entries(fields)) {
    if (Array.isArray(value)) value.forEach((item) => body.append(key, item));
    else body.append(key, value);
  }
  body.append('_csrf', csrf || '');
  return body.toString();
}

async function post(path, fields) {
  const headers = { 'content-type': 'application/x-www-form-urlencoded' };
  if (cookie) headers.cookie = cookie;

  const response = await fetch(BASE + path, {
    method: 'POST',
    headers,
    body: formBody(fields),
    redirect: 'manual',
  });
  return { status: response.status, location: response.headers.get('location') };
}

/**
 * Отправка формы с файлом: тело собирает вызывающая проверка, здесь только
 * кука и тип содержимого. Обычный post() для этого не годится — многочастное
 * тело собирается из двоичных кусков.
 */
async function raw(path, body, contentType) {
  const headers = { 'content-type': contentType };
  if (cookie) headers.cookie = cookie;

  const response = await fetch(BASE + path, {
    method: 'POST', headers, body, redirect: 'manual',
  });
  return { status: response.status, location: response.headers.get('location') };
}

/** Токен формы текущей сессии — для многочастных форм, где его кладут руками. */
function token() {
  return csrf || '';
}

async function serverAlive() {
  try {
    await fetch(BASE + '/', { signal: AbortSignal.timeout(1500) });
    return true;
  } catch {
    return false;
  }
}

module.exports = {
  Case, get, post, raw, token, serverAlive, signIn, signOut, BASE, CHECK_LOGIN,
};
