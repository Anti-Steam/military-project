'use strict';

// Хранение паролей.
//
// Применяется scrypt из штатного node:crypto с параметрами, рекомендованными
// OWASP Password Storage Cheat Sheet: N = 2^17, r = 8, p = 1.
//
// Argon2id считается предпочтительным, но требует собирать нативный модуль.
// Стенд разворачивается офлайн на Astra Linux, и зависимость, которую нельзя
// установить без интернета и компилятора, там дороже разницы в стойкости.
// Формат хранения содержит имя алгоритма и параметры, поэтому переход на
// argon2id сведется к добавлению ветки в verify и смене hash.
//
// Соль случайная у каждого пароля: одинаковые пароли дают разные строки, и
// таблица заранее посчитанных хешей бесполезна.

const crypto = require('node:crypto');
const { promisify } = require('node:util');

const scrypt = promisify(crypto.scrypt);

const ALGO = 'scrypt';
const N = 1 << 17;
const R = 8;
const P = 1;
const KEY_LENGTH = 32;
const SALT_LENGTH = 16;

// maxmem по умолчанию (32 МиБ) мал для N = 2^17: нужно примерно 128 * N * r.
const MAX_MEM = 256 * 1024 * 1024;

/** Хеш пароля в виде scrypt$N$r$p$соль$ключ (соль и ключ — base64). */
async function hash(plain) {
  const salt = crypto.randomBytes(SALT_LENGTH);
  const key = await scrypt(normalize(plain), salt, KEY_LENGTH, { N, r: R, p: P, maxmem: MAX_MEM });
  return [ALGO, N, R, P, salt.toString('base64'), key.toString('base64')].join('$');
}

/**
 * Проверка пароля.
 *
 * Сравнение идет за постоянное время: обычное сравнение строк выдает длину
 * совпавшего начала временем ответа.
 */
async function verify(plain, stored) {
  if (typeof plain !== 'string' || typeof stored !== 'string') return false;

  const parts = stored.split('$');
  if (parts.length !== 6 || parts[0] !== ALGO) return false;

  const [, n, r, p, salt, key] = parts;
  const expected = Buffer.from(key, 'base64');
  if (expected.length !== KEY_LENGTH || Buffer.from(salt, 'base64').length !== SALT_LENGTH) return false;

  let actual;
  try {
    actual = await scrypt(normalize(plain), Buffer.from(salt, 'base64'), expected.length,
      { N: Number(n), r: Number(r), p: Number(p), maxmem: MAX_MEM });
  } catch {
    return false;
  }

  return actual.length === expected.length && crypto.timingSafeEqual(actual, expected);
}

/**
 * Приведение пароля к единому виду перед хешированием.
 *
 * Нормализация Unicode нужна потому, что одна и та же буква с ударением или
 * «й» набирается двумя разными последовательностями байтов; без нее пароль,
 * набранный в другой раскладке или на другой клавиатуре, не подойдет.
 */
function normalize(plain) {
  return String(plain).normalize('NFKC');
}

/**
 * Временный пароль для новой учетной записи.
 *
 * Из алфавита исключены знаки, неразличимые при переписывании от руки:
 * 0 и O, 1, l и I. Временный пароль диктуют человеку голосом либо передают
 * на бумаге, и «не та единица» стоит дороже пары бит стойкости.
 */
const ALPHABET = 'ABCDEFGHJKMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789';

function temporary(length = 12) {
  const bytes = crypto.randomBytes(length);
  let out = '';
  for (const byte of bytes) out += ALPHABET[byte % ALPHABET.length];
  return out;
}

/**
 * Требования к паролю.
 *
 * Длина важнее состава: NIST рекомендует не требовать смешения регистров и
 * знаков, а требовать длину. Принудительная смена по сроку тоже не вводится
 * — она гонит людей к паролям вида «Осень2026!», которые подбираются первыми.
 *
 * Минимальная длина вынесена в настройку PASSWORD_MIN_LENGTH. На время
 * отладки стенда ее опускают, чтобы не набирать длинный пароль при каждой
 * проверке; перед опытной эксплуатацией настройку убирают и возвращается
 * значение по умолчанию. Послабление видно в одном месте, а не разбросано
 * по коду.
 */
const DEFAULT_MIN_LENGTH = 10;
const MIN_LENGTH = Math.max(1, Number(process.env.PASSWORD_MIN_LENGTH) || DEFAULT_MIN_LENGTH);

// Прочие придирки имеют смысл только при настоящей длине: при отладочном
// минимуме они мешали бы вводить короткий пароль и ничего не защищали.
const STRICT = MIN_LENGTH >= 8;

function problems(plain, login) {
  const value = String(plain || '');
  const out = [];

  if (value.length < MIN_LENGTH) out.push(`Пароль короче ${MIN_LENGTH} знаков.`);

  if (STRICT) {
    if (/^\s|\s$/.test(value)) out.push('Пароль начинается или кончается пробелом.');
    if (login && value.toLowerCase().includes(String(login).toLowerCase())) {
      out.push('Пароль содержит логин.');
    }
  }

  return out;
}

module.exports = { hash, verify, temporary, problems, MIN_LENGTH, DEFAULT_MIN_LENGTH };
