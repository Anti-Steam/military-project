'use strict';

// Разграничение доступа — МС-5.
//
// Модель гибридная: РОЛЬ задает набор прав по умолчанию, точечная правка
// выдает право сверх роли либо отнимает его у конкретного человека. Так
// администратор разграничивает доступ и при заведении учетной записи, и
// после, не заводя новую роль ради одного исключения.
//
// Право названо по ДЕЙСТВИЮ, а не по роли: роль сотрудника меняется, смысл
// действия — нет. Перечень прав живет в справочнике (миграция 027), а не в
// коде: иначе выдать доступ нельзя было бы без правки исходного текста.
//
// Сессии серверные: в браузер уходит только случайный идентификатор. По нему
// ничего не прочитать и не подделать, а завершить чужую сессию можно
// немедленно — при смене пароля, прав или отключении учетной записи.

const crypto = require('node:crypto');
const queries = require('./queries');
const password = require('./password');
const v = require('../../lib/validation');

// Парольная политика раздела 6.4.
const MAX_ATTEMPTS = 3;
const LOCK_MINUTES = 10;

// Сессия СКОЛЬЗЯЩАЯ: живет неделю с последнего обращения, и каждое обращение
// сдвигает срок. Кто заходит хотя бы раз в неделю, повторно не входит; кто
// бросил рабочее место на неделю — входит заново.
//
// Предельный срок от входа отдельный и больше: сессия не должна жить вечно
// даже при ежедневной работе — украденная кука иначе служила бы бессрочно.
// 0 снимает предел совсем; делать так стоит только на стенде.
//
// Оба срока задаются в .env: подбираются опытом, а не выпуском версии.
function days(name, fallback) {
  const value = Number(process.env[name]);
  return Number.isFinite(value) && value >= 0 ? value : fallback;
}

const IDLE_HOURS = days('SESSION_IDLE_DAYS', 7) * 24;
const ABSOLUTE_HOURS = days('SESSION_MAX_DAYS', 30) * 24;

// Запись о продлении делается не на каждом обращении, а раз в час: запись в
// БД ради сдвига срока на секунду не нужна, а неделя от часа не зависит.
const RENEW_AFTER_HOURS = 1;

const COOKIE = 'sid';

// Куки помечаются Secure только там, где есть HTTPS: на стенде за Nginx с
// TLS признак включается в .env, при локальном запуске по http его нельзя
// ставить — браузер тогда куку просто не сохранит.
const SECURE_COOKIE = String(process.env.SESSION_SECURE || '').toLowerCase() === 'true';

// Страницы, доступные без входа.
const PUBLIC_PATHS = new Set(['/login']);

/** Случайный идентификатор на 256 бит: подобрать перебором невозможно. */
const randomId = () => crypto.randomBytes(32).toString('base64url');

function readCookie(req, name) {
  const header = req.headers.cookie;
  if (!header) return null;

  for (const part of header.split(';')) {
    const index = part.indexOf('=');
    if (index < 0) continue;
    if (part.slice(0, index).trim() === name) {
      try { return decodeURIComponent(part.slice(index + 1)); }
      catch { return null; }
    }
  }
  return null;
}

const clientIp = (req) => (req.ip || req.socket?.remoteAddress || '').replace('::ffff:', '');

// ----------------------------------------------------------------------------
// Вход и сессии
// ----------------------------------------------------------------------------

/**
 * Вход по логину и паролю.
 *
 * Ответ на неверный логин и на неверный пароль одинаков: разные сообщения
 * позволяют перебором выяснить, какие учетные записи существуют.
 */
async function login({ login: loginName, password: plain, ip, userAgent }) {
  const name = String(loginName || '').trim();
  const from = String(ip || '') || 'неизвестен';
  const user = await queries.findByLogin(name);

  if (!user) {
    await queries.logEvent({ kind: 'login.fail', login: name, detail: 'нет такой записи', ip });
    v.fail('Неверный логин или пароль.', 401);
  }

  // Блокировка — по паре «запись + компьютер»: чужие неверные попытки
  // запирают вход только с того компьютера, откуда они шли.
  const lockedUntil = await queries.lockedFrom(user.id, from);
  if (lockedUntil) {
    await queries.logEvent({ kind: 'login.locked', userId: user.id, login: name, ip });
    v.fail(`Вход с этого компьютера заблокирован до ${new Date(lockedUntil).toLocaleTimeString('ru-RU')}.`, 423);
  }

  if (!user.is_active) {
    await queries.logEvent({ kind: 'login.fail', userId: user.id, login: name, detail: 'запись отключена', ip });
    v.fail('Неверный логин или пароль.', 401);
  }

  if (!await password.verify(plain, user.password_hash)) {
    const state = await queries.registerFailure(user.id, from, MAX_ATTEMPTS, LOCK_MINUTES);
    await queries.logEvent({
      kind: state.locked_until ? 'login.locked' : 'login.fail',
      userId: user.id, login: name, ip,
      detail: `попытка ${state.failed_attempts} из ${MAX_ATTEMPTS}`,
    });
    v.fail('Неверный логин или пароль.', 401);
  }

  await queries.registerSuccess(user.id, from);

  // Идентификатор сессии выдается заново при каждом входе: иначе заранее
  // подсунутый значение осталось бы действительным и после входа.
  const sessionId = randomId();
  await queries.createSession({
    id: sessionId,
    userId: user.id,
    csrfToken: randomId(),
    expiresAt: new Date(Date.now() + IDLE_HOURS * 3600 * 1000),
    ip,
    userAgent: String(userAgent || '').slice(0, 300),
  });

  await queries.logEvent({ kind: 'login.ok', userId: user.id, login: name, ip });
  return { sessionId, user };
}

async function logout(req, res) {
  const sessionId = readCookie(req, COOKIE);
  if (sessionId) {
    await queries.deleteSession(sessionId);
    await queries.logEvent({ kind: 'logout', userId: req.user?.id, ip: clientIp(req) });
  }
  res.clearCookie(COOKIE, { path: '/' });
}

function setCookie(res, sessionId) {
  res.cookie(COOKIE, sessionId, {
    httpOnly: true,
    sameSite: 'strict',
    secure: SECURE_COOKIE,
    path: '/',
    maxAge: IDLE_HOURS * 3600 * 1000,
  });
}

// ----------------------------------------------------------------------------
// Проверка прав
// ----------------------------------------------------------------------------

function can(user, action) {
  return Boolean(user && user.permissions && user.permissions.has(action));
}

/**
 * ВРИО командира на сегодня получает права роли «Командир» с зоной этого
 * подразделения — по дате, без правки учетной записи: кончился период —
 * кончились права. Роли выше командира не меняются (у них и так больше), у
 * командира своего подразделения зона остается прежней.
 */
async function applyActing(user) {
  if (!user || !user.employee_id || !['user', 'commander'].includes(user.role_code)) return user;
  const org = require('../org/service');
  const unit = await org.actingUnitToday(user.employee_id);
  if (!unit) return user;
  for (const code of await queries.rolePermissionCodes('commander')) user.permissions.add(code);
  if (user.role_code === 'user' || !user.scope_unit_id) user.scope_unit_id = unit;
  user.acting_unit_id = unit;
  return user;
}

/** Проверка права по идентификатору — для случаев вне запроса. */
async function authorizeUser(id, action) {
  if (!id) return false;
  return (await queries.effectivePermissions(id)).includes(action);
}

/**
 * Middleware: сессия, действующее лицо и его права.
 *
 * Без действующей сессии дальше пропускаются только страница входа и
 * статические файлы; остальное уводит на вход.
 */
async function attach(req, res, next) {
  res.locals.currentUser = null;
  res.locals.can = () => false;
  res.locals.csrf = '';
  res.set('Cache-Control', 'no-store');
  try {
    const sessionId = readCookie(req, COOKIE);
    const session = sessionId ? await queries.findSession(sessionId) : null;

    if (session) {
      const born = new Date(session.session_created_at).getTime();
      if (ABSOLUTE_HOURS > 0 && Date.now() - born > ABSOLUTE_HOURS * 3600 * 1000) {
        // Предельный срок сессии истек: ее нужно открыть заново входом.
        await queries.deleteSession(session.session_id);
        res.clearCookie(COOKIE, { path: '/' });
        return res.redirect('/login');
      }

      const permissions = new Set(await queries.effectivePermissions(session.user_id));

      req.user = {
        id: session.user_id,
        login: session.login,
        role_code: session.role_code,
        role_level: session.role_level,
        employee_id: session.employee_id,
        // Закрепленное подразделение: пользователь видит и ведет его вместе
        // со всеми вложенными. NULL — вся часть.
        scope_unit_id: session.scope_unit_id,
        must_change_password: session.must_change_password,
        permissions,
      };
      await applyActing(req.user);
      req.session = { id: session.session_id, csrfToken: session.csrf_token };

      // Срок продлевается от ЭТОГО обращения. В браузере кука перевыдается
      // тоже: у нее свой срок хранения, и без перевыдачи браузер выбросил бы
      // ее через неделю от входа, хотя сессия в базе еще жива.
      const remains = new Date(session.expires_at).getTime() - Date.now();
      if (remains < (IDLE_HOURS - RENEW_AFTER_HOURS) * 3600 * 1000) {
        const idleEnd = Date.now() + IDLE_HOURS * 3600 * 1000;
        const expiresAt = new Date(ABSOLUTE_HOURS > 0
          ? Math.min(idleEnd, born + ABSOLUTE_HOURS * 3600 * 1000)
          : idleEnd);
        await queries.touchSession(session.session_id, expiresAt);
        setCookie(res, session.session_id);
      }
    }

    res.locals.currentUser = req.user || null;
    res.locals.can = (action) => can(req.user, action);
    res.locals.csrf = req.session ? req.session.csrfToken : '';

    if (!req.user) {
      if (PUBLIC_PATHS.has(req.path)) return next();
      if (req.method !== 'GET') return res.status(401).render('error', {
        title: 'Требуется вход', message: 'Сессия закончилась. Войдите заново.',
      });
      return res.redirect(`/login?next=${encodeURIComponent(req.originalUrl)}`);
    }

    // Временный пароль меняется до начала работы: иначе он остается
    // действующим ровно столько, сколько человеку удобно.
    if (req.user.must_change_password && !['/password', '/logout'].includes(req.path)) {
      if (req.method !== 'GET') {
        return res.status(403).render('error', {
          title: 'Смените пароль', message: 'До смены временного пароля действия недоступны.',
        });
      }
      return res.redirect('/password');
    }

    return next();
  } catch (err) {
    return next(err);
  }
}

/**
 * Защита от запросов, отправленных с чужой страницы.
 *
 * Связка из двух проверок: кука помечена SameSite=strict и потому не уходит
 * при переходе с другого сайта, а в каждой форме лежит одноразовое значение
 * из сессии. Первое отсекает подделку на стороне браузера, второе — случай,
 * когда браузер старый и признак не соблюдает.
 */
function csrf(req, res, next) {
  if (req.method !== 'POST') return next();
  if (!req.session) return next();

  // Форма с файлом приходит многочастной, и тело разбирает сам обработчик:
  // читать его дважды нельзя. Проверку он делает вызовом checkToken — она та
  // же самая, только в другом месте.
  if (String(req.headers?.['content-type'] || '').startsWith('multipart/form-data')) return next();

  const sent = String(req.body?._csrf || '');
  const expected = req.session.csrfToken;

  const sentBytes = Buffer.from(sent);
  const expectedBytes = Buffer.from(expected);
  if (sentBytes.length === expectedBytes.length
      && crypto.timingSafeEqual(sentBytes, expectedBytes)) {
    return next();
  }

  return res.status(403).render('error', {
    title: 'Запрос отклонен',
    message: 'Страница устарела или запрос пришел со стороны. Откройте страницу заново.',
  });
}

/**
 * Та же проверка токена, но вызываемая из обработчика — для форм с файлом,
 * тело которых разбирается вручную.
 */
function checkToken(req, sent) {
  const expected = req.session ? req.session.csrfToken : '';
  const sentBytes = Buffer.from(String(sent || ''));
  const expectedBytes = Buffer.from(String(expected || ''));

  if (sentBytes.length !== expectedBytes.length
      || !crypto.timingSafeEqual(sentBytes, expectedBytes)) {
    const err = new Error('Страница устарела или запрос пришел со стороны. '
      + 'Откройте страницу заново.');
    err.userMessage = true;
    err.status = 403;
    throw err;
  }
}

/** Проверка права в обработчике. Сама отвечает отказом, если права нет. */
function require_(req, res, action) {
  if (can(req.user, action)) return true;

  res.status(403).render('error', {
    title: 'Недостаточно прав',
    message: `Действие «${action}» не входит в ваши права. Обратитесь к администратору.`,
  });
  return false;
}

// ----------------------------------------------------------------------------
// Учетные записи
// ----------------------------------------------------------------------------

async function listUsers() {
  return queries.listUsers();
}

async function listRoles() {
  return queries.listRoles();
}

async function listPermissions() {
  return queries.listPermissions();
}

/** Учетная запись вместе с правами роли и точечными правками. */
async function getUser(id) {
  const user = await queries.findById(v.id(id));
  if (!user) return null;

  const [ofRole, own, permissions] = await Promise.all([
    queries.rolePermissions(user.role_code),
    queries.userPermissions(user.id),
    queries.listPermissions(),
  ]);

  const byRole = new Set(ofRole);
  const overrides = new Map(own.map((o) => [o.permission_code, o.granted]));

  return {
    user,
    rows: permissions.map((p) => ({
      ...p,
      byRole: byRole.has(p.code),
      override: overrides.has(p.code) ? overrides.get(p.code) : null,
      effective: overrides.has(p.code) ? overrides.get(p.code) : byRole.has(p.code),
    })),
  };
}

const LOGIN_PATTERN = /^[a-z][a-z0-9._-]{2,31}$/;

/**
 * Согласованность записи:
 *   - командир — только с подразделением: без него он видел бы и вел всю
 *     часть (подразделение и есть его зона);
 *   - исключенный из списков не работает в системе: запись на него не
 *     заводится и не включается.
 */
async function checkAccountFields({ roleCode, employeeId, scopeUnitId, isActive }) {
  if (roleCode === 'commander' && !scopeUnitId) {
    v.fail('Командиру укажите подразделение: без него он получил бы доступ ко всей части.');
  }
  if (employeeId && isActive) {
    const [person] = await require('../personnel/service').getByIds([v.id(employeeId)]);
    if (person && !person.is_active) v.fail('Сотрудник исключен из списков — учетная запись на него не включается.');
  }
}

/**
 * Исключение из списков: учетные записи человека отключаются, сеансы
 * завершаются. Последнего администратора так не отключить — сначала
 * назначьте другого.
 */
async function disableForEmployee(employeeId, actorId) {
  const users = await queries.listUsers();
  const own = users.filter((u) => u.employee_id === employeeId && u.is_active);
  if (own.some((u) => u.role_code === 'admin')
      && !users.some((u) => u.role_code === 'admin' && u.is_active && u.employee_id !== employeeId)) {
    v.fail('Сотрудник — последний действующий администратор системы: сначала назначьте другого.');
  }
  for (const u of own) {
    await queries.deactivate(u.id);
    const closed = await queries.deleteUserSessions(u.id);
    await queries.logEvent({ kind: 'user.update', userId: u.id, actorId,
      detail: `отключена: владелец исключен из списков, завершено сессий ${closed}` });
  }
  return own.length;
}

/**
 * Заведение учетной записи.
 *
 * Пароль выдается системой и подлежит смене при первом входе: администратор
 * видит его один раз и передает человеку. Так рабочий пароль не знает никто,
 * кроме владельца, и действия под учетной записью нельзя списать на того,
 * кто ее завел.
 *
 * @returns {{id:number, password:string}} временный пароль возвращается
 *   ОДИН раз и нигде не сохраняется.
 */
async function createUser({ login: loginName, roleCode, employeeId, scopeUnitId, permissions, actorId }) {
  const name = String(loginName || '').trim().toLowerCase();
  if (!LOGIN_PATTERN.test(name)) {
    v.fail('Логин: от 3 до 32 знаков, латиница, цифры, точка, дефис, подчеркивание; начинается с буквы.');
  }

  const roles = await queries.listRoles();
  if (!roles.some((r) => r.code === roleCode)) v.fail('Неизвестная роль.');
  await checkAccountFields({ roleCode, employeeId, scopeUnitId, isActive: true });

  const temporary = password.temporary();
  const id = await queries.createUser({
    login: name,
    passwordHash: await password.hash(temporary),
    roleCode,
    employeeId: employeeId ? v.id(employeeId) : null,
    scopeUnitId: scopeUnitId ? v.id(scopeUnitId) : null,
    createdBy: actorId,
  });

  if (permissions && permissions.length > 0) {
    await queries.setUserPermissions(id, permissions, actorId);
  }

  await queries.logEvent({
    kind: 'user.create', userId: id, actorId,
    detail: `логин ${name}, роль ${roleCode}`
      + (scopeUnitId ? `, подразделение ${scopeUnitId}` : ', вся часть'),
  });

  return { id, password: temporary };
}

/**
 * Правка учетной записи и ее прав.
 *
 * Сессии владельца завершаются: права изменились, и продолжать работу с
 * прежними нельзя. Человек входит заново и получает новый набор.
 */
async function updateUser(id, { roleCode, employeeId, isActive, scopeUnitId, permissions, actorId }) {
  const userId = v.id(id);
  const before = await queries.findById(userId);
  if (!before) v.fail('Учетная запись не найдена.', 404);

  const roles = await queries.listRoles();
  if (!roles.some((r) => r.code === roleCode)) v.fail('Неизвестная роль.');
  await checkAccountFields({ roleCode, employeeId, scopeUnitId, isActive });

  // Последний администратор не должен исчезнуть: без него систему некому
  // будет разблокировать.
  if ((before.role_code === 'admin' && roleCode !== 'admin') || (before.is_active && !isActive)) {
    const admins = (await queries.listUsers())
      .filter((u) => u.role_code === 'admin' && u.is_active && u.id !== userId);
    if (before.role_code === 'admin' && admins.length === 0) {
      v.fail('Это последний действующий администратор: сначала назначьте другого.');
    }
  }

  await queries.updateUser(userId, {
    roleCode, employeeId, isActive, scopeUnitId: scopeUnitId ? v.id(scopeUnitId) : null,
  });
  await queries.setUserPermissions(userId, permissions || [], actorId);
  const administrators = (await queries.listUsers()).filter(u => u.role_code === 'admin' && u.is_active);
  let canManage = false;
  for (const admin of administrators) {
    if (await authorizeUser(admin.id, 'user.manage')) canManage = true;
  }
  if (!canManage) v.fail('Должен остаться действующий администратор с правом управления учетными записями.');
  const closed = await queries.deleteUserSessions(userId);

  await queries.logEvent({
    kind: 'user.update', userId, actorId,
    detail: `роль ${roleCode}, ${isActive ? 'действует' : 'отключена'}, `
      + `точечных правок ${(permissions || []).length}, завершено сессий ${closed}`,
  });
}

/** Выдача нового временного пароля взамен забытого. */
async function resetPassword(id, actorId) {
  const userId = v.id(id);
  const temporary = password.temporary();

  await queries.setPassword(userId, await password.hash(temporary), true);
  await queries.deleteUserSessions(userId);
  await queries.logEvent({ kind: 'password.reset', userId, actorId });

  return temporary;
}

async function unlock(id, actorId) {
  const userId = v.id(id);
  await queries.unlock(userId);
  await queries.logEvent({ kind: 'user.unlock', userId, actorId });
}

/**
 * Смена собственного пароля.
 *
 * Прежний пароль спрашивается даже у того, кто уже вошел: оставленное без
 * присмотра рабочее место иначе позволяет сменить пароль и запереть хозяина.
 */
async function changePassword(userId, { current, next: plain, repeat }) {
  const user = await queries.findByLogin((await queries.findById(userId)).login);

  if (!await password.verify(current, user.password_hash)) {
    await queries.logEvent({ kind: 'password.fail', userId, detail: 'неверный прежний пароль' });
    v.fail('Прежний пароль указан неверно.');
  }

  if (plain !== repeat) v.fail('Новый пароль и повтор не совпадают.');

  const problems = password.problems(plain, user.login);
  if (problems.length > 0) v.fail(problems.join(' '));

  if (await password.verify(plain, user.password_hash)) v.fail('Новый пароль совпадает с прежним.');

  await queries.setPassword(userId, await password.hash(plain), false);
  await queries.deleteUserSessions(userId);
  await queries.logEvent({ kind: 'password.change', userId, actorId: userId });
}

// Виды событий журнала доступа — группами для фильтра.
const EVENT_GROUPS = {
  login: ['login.ok', 'logout'],
  fail: ['login.fail', 'login.locked', 'password.fail'],
  password: ['password.change', 'password.reset', 'password.initial'],
  users: ['user.create', 'user.update', 'user.unlock', 'sessions.end'],
};

/**
 * Журнал доступа. Число — последние события (как раньше); объект —
 * фильтры: даты, учетная запись, группа событий, листание «раньше».
 */
async function listEvents(filter = {}) {
  if (typeof filter === 'number') return queries.listEvents({ limit: filter });
  const date = (x) => (v.isDate(String(x || '')) ? String(x) : null);
  return queries.listEvents({
    limit: 200,
    before: Number(filter.before) > 0 ? Number(filter.before) : null,
    from: date(filter.from),
    to: date(filter.to),
    login: String(filter.login || '').trim() || null,
    kinds: EVENT_GROUPS[filter.group] || null,
  });
}

/** Действующие сеансы записи (current — тот, из которого смотрят). */
async function listSessions(userId, currentId) {
  const rows = await queries.listUserSessions(v.id(userId));
  return rows.map(({ id, ...row }) => ({ ...row, current: id === currentId }));
}

/**
 * Завершить сеансы: все (администратор — потерян пропуск, оставлен
 * компьютер) или все, кроме текущего (сам человек — «выйти на других
 * компьютерах»).
 */
async function endSessions(userId, actorId, exceptId = null) {
  const id = v.id(userId);
  const closed = exceptId ? await queries.deleteOtherSessions(id, exceptId) : await queries.deleteUserSessions(id);
  await queries.logEvent({ kind: 'sessions.end', userId: id, actorId,
    detail: `завершено сеансов: ${closed}${exceptId ? ' (кроме текущего)' : ''}` });
  return closed;
}

/**
 * Готовность к первому входу.
 *
 * В начальном наполнении пароль администратора не задан (заглушка из
 * миграции 001). Запускатель вызывает это при старте: если войти нельзя,
 * выдается временный пароль и печатается ОДИН раз в консоль того, кто
 * поднимает стенд.
 *
 * @returns {?{login:string, password:string}} null — вход уже возможен
 */
async function ensureInitialPassword() {
  const { rows } = await require('../../db/pool').query(`
    SELECT id, login FROM core.users
    WHERE is_active AND role_code = 'admin' AND password_hash NOT LIKE 'scrypt$%'
    ORDER BY id LIMIT 1
  `);

  if (rows.length === 0) return null;

  const temporary = password.temporary();
  await queries.setPassword(rows[0].id, await password.hash(temporary), true);
  await queries.logEvent({ kind: 'password.initial', userId: rows[0].id, detail: 'выдан запускателем' });

  return { login: rows[0].login, password: temporary };
}

module.exports = {
  MAX_ATTEMPTS,
  LOCK_MINUTES,
  attach,
  csrf,
  checkToken,
  applyActing,
  // Сроки сессии — для проверок: они сверяются с настройкой, а не с числом.
  SESSION_LIMITS: { idleHours: IDLE_HOURS, absoluteHours: ABSOLUTE_HOURS },
  can,
  require: require_,
  authorizeUser,
  login,
  logout,
  setCookie,
  listUsers,
  listRoles,
  listPermissions,
  getUser,
  createUser,
  disableForEmployee,
  updateUser,
  resetPassword,
  unlock,
  changePassword,
  listEvents,
  EVENT_GROUPS,
  listSessions,
  endSessions,
  ensureInitialPassword,
  purgeExpiredSessions: queries.purgeExpiredSessions,
};

// Проверки, изменения, отзыв сессий и аудит фиксируются вместе.
for (const name of ['createUser', 'updateUser', 'disableForEmployee', 'resetPassword', 'changePassword', 'unlock', 'ensureInitialPassword']) {
  const fn = module.exports[name];
  module.exports[name] = (...args) => require('../../db/pool').transaction(() => fn(...args));
}

module.exports.login = async (...args) => {
  const result = await require('../../db/pool').transaction(async () => {
    try { return await login(...args); }
    catch (error) {
      // Отказ входа сохраняет счетчик попыток и событие в журнале.
      if (error.userMessage) return { error };
      throw error;
    }
  });
  if (result.error) throw result.error;
  return result;
};
