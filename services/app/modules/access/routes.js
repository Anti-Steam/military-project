'use strict';

const express = require('express');
const service = require('./service');
const personnel = require('../personnel/service');
const org = require('../org/service');

const router = express.Router();

/**
 * Разбор точечных правок прав из формы.
 *
 * У каждого права три состояния: «как у роли», «выдать» и «отнять».
 * Записываются только два последних — набор роли хранить у человека незачем,
 * он и так следует из роли и должен меняться вместе с ней.
 */
function parsePermissions(body) {
  const items = [];

  for (const [key, value] of Object.entries(body)) {
    const match = /^perm_(.+)$/.exec(key);
    if (!match) continue;
    if (value === 'grant') items.push({ code: match[1], granted: true });
    if (value === 'revoke') items.push({ code: match[1], granted: false });
  }

  return items;
}

const backTo = (req, fallback) => {
  const next = String(req.query.next || req.body.next || '');
  return /^\/[^/\\]/.test(next) ? next : fallback;
};

// ----------------------------------------------------------------------------
// Вход
// ----------------------------------------------------------------------------

router.get('/login', (req, res) => {
  if (req.user) return res.redirect('/');
  return res.render('login', { title: 'Вход', error: null, login: '', next: req.query.next || '' });
});

router.post('/login', async (req, res, next) => {
  try {
    const { sessionId } = await service.login({
      login: req.body.login,
      password: req.body.password,
      ip: (req.ip || '').replace('::ffff:', ''),
      userAgent: req.headers['user-agent'],
    });

    service.setCookie(res, sessionId);
    res.redirect(backTo(req, '/'));
  } catch (err) {
    if (!err.userMessage) return next(err);
    res.status(err.status || 401).render('login', {
      title: 'Вход',
      error: err.message,
      login: String(req.body.login || ''),
      next: req.body.next || '',
    });
  }
});

router.post('/logout', async (req, res, next) => {
  try {
    await service.logout(req, res);
    res.redirect('/login');
  } catch (err) {
    next(err);
  }
});

// ----------------------------------------------------------------------------
// Свой пароль
// ----------------------------------------------------------------------------

router.get('/password', (req, res) => {
  res.render('password', {
    title: 'Смена пароля',
    error: null,
    forced: Boolean(req.user.must_change_password),
  });
});

router.post('/password', async (req, res, next) => {
  try {
    await service.changePassword(req.user.id, {
      current: req.body.current,
      next: req.body.next,
      repeat: req.body.repeat,
    });

    // После смены пароля все прежние сессии завершены.
    res.clearCookie('sid', { path: '/' });
    res.locals.currentUser = null;
    res.locals.can = () => false;
    res.render('password-done', { title: 'Пароль изменен' });
  } catch (err) {
    if (!err.userMessage) return next(err);
    res.status(err.status || 400).render('password', {
      title: 'Смена пароля',
      error: err.message,
      forced: Boolean(req.user.must_change_password),
    });
  }
});

// ----------------------------------------------------------------------------
// Учетные записи
// ----------------------------------------------------------------------------

router.get('/users', async (req, res, next) => {
  try {
    if (!service.require(req, res, 'user.manage')) return;
    res.render('users-list', { title: 'Учетные записи', users: await service.listUsers() });
  } catch (err) {
    next(err);
  }
});

router.get('/users/new', async (req, res, next) => {
  try {
    if (!service.require(req, res, 'user.manage')) return;

    const [roles, permissions, employees, units] = await Promise.all([
      service.listRoles(), service.listPermissions(), personnel.listEmployees(),
      org.listUnits(req.user),
    ]);

    res.render('user-edit', {
      title: 'Новая учетная запись',
      user: null,
      roles,
      employees,
      units,
      rows: permissions.map((p) => ({ ...p, byRole: false, override: null, effective: false })),
      issued: null,
    });
  } catch (err) {
    next(err);
  }
});

router.post('/users', async (req, res, next) => {
  try {
    if (!service.require(req, res, 'user.manage')) return;

    const { id, password } = await service.createUser({
      login: req.body.login,
      roleCode: String(req.body.roleCode || ''),
      employeeId: req.body.employeeId || null,
      scopeUnitId: req.body.scopeUnitId || null,
      permissions: parsePermissions(req.body),
      actorId: req.user.id,
    });

    // Временный пароль показывается один раз: в базе его нет, повторить
    // показ невозможно — только выдать новый.
    res.render('user-created', {
      title: 'Учетная запись заведена',
      login: String(req.body.login).trim().toLowerCase(),
      password,
      id,
    });
  } catch (err) {
    if (!err.userMessage) return next(err);
    res.status(err.status || 400).render('error', { title: 'Ошибка', message: err.message });
  }
});

router.get('/users/:id', async (req, res, next) => {
  try {
    if (!service.require(req, res, 'user.manage')) return;

    const found = await service.getUser(req.params.id);
    if (!found) {
      return res.status(404).render('error', { title: 'Не найдено', message: 'Учетная запись не найдена.' });
    }

    const [roles, employees, units, sessions] = await Promise.all([
      service.listRoles(), personnel.listEmployees(), org.listUnits(req.user),
      service.listSessions(found.user.id, req.session.id),
    ]);

    res.render('user-edit', {
      title: `Учетная запись ${found.user.login}`,
      user: found.user,
      sessions,
      rows: found.rows,
      roles,
      employees,
      units,
      issued: null,
    });
  } catch (err) {
    next(err);
  }
});

router.post('/users/:id', async (req, res, next) => {
  try {
    if (!service.require(req, res, 'user.manage')) return;

    await service.updateUser(req.params.id, {
      roleCode: String(req.body.roleCode || ''),
      employeeId: req.body.employeeId || null,
      isActive: req.body.isActive === 'on',
      scopeUnitId: req.body.scopeUnitId || null,
      permissions: parsePermissions(req.body),
      actorId: req.user.id,
    });

    res.redirect('/users');
  } catch (err) {
    if (!err.userMessage) return next(err);
    res.status(err.status || 400).render('error', { title: 'Ошибка', message: err.message });
  }
});

router.post('/users/:id/reset', async (req, res, next) => {
  try {
    if (!service.require(req, res, 'user.manage')) return;

    const found = await service.getUser(req.params.id);
    if (!found) {
      return res.status(404).render('error', { title: 'Не найдено', message: 'Учетная запись не найдена.' });
    }

    const password = await service.resetPassword(req.params.id, req.user.id);
    res.render('user-created', {
      title: 'Выдан новый пароль',
      login: found.user.login,
      password,
      id: found.user.id,
    });
  } catch (err) {
    next(err);
  }
});

// Завершить все сеансы записи: потерян пропуск, оставлен компьютер.
router.post('/users/:id/sessions/end', async (req, res, next) => {
  try {
    if (!service.require(req, res, 'user.manage')) return;
    await service.endSessions(req.params.id, req.user.id);
    res.redirect(`/users/${Number(req.params.id)}#sessions`);
  } catch (err) {
    next(err);
  }
});

router.post('/users/:id/unlock', async (req, res, next) => {
  try {
    if (!service.require(req, res, 'user.manage')) return;
    await service.unlock(req.params.id, req.user.id);
    res.redirect('/users');
  } catch (err) {
    next(err);
  }
});

// Журнал событий безопасности: входы, отказы, блокировки, правки прав.
router.get('/security', async (req, res, next) => {
  try {
    if (!service.require(req, res, 'user.manage')) return;
    const filter = {
      from: String(req.query.from || ''), to: String(req.query.to || ''),
      login: String(req.query.login || '').trim(), group: String(req.query.group || ''),
      before: req.query.before || '',
    };
    const events = await service.listEvents(filter);
    res.render('security-log', { title: 'Журнал доступа', events, filter, groups: Object.keys(service.EVENT_GROUPS),
      // «Раньше →» — страница полная, значит дальше могут быть еще.
      older: events.length === 200 ? events[events.length - 1].id : null });
  } catch (err) {
    next(err);
  }
});

module.exports = router;
