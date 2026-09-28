'use strict';

const express = require('express');
const service = require('./service');
const access = require('../access/service');
const personnel = require('../personnel/service');
const v = require('../../lib/validation');

const router = express.Router();

// Разбор ведет тот, кто ведет приказы этого вида; полный документ — только
// пользователю без ограничения подразделения (как и сам PDF приказа).
const orderRight = (order) => (order && ['absence', 'other'].includes(order.kind) ? 'absence.manage' : 'permit.manage');
const fail = (res, err, next) => {
  if (!err.userMessage) return next(err);
  res.status(err.status || 400).render('error', { title: 'Ошибка', message: err.message });
};
async function allowed(req, res, orderId) {
  const order = await personnel.getOrder(v.id(orderId));
  if (!order) v.fail('Приказ не найден.', 404);
  if (req.user.scope_unit_id) v.fail('Разбор приказа доступен только пользователю без ограничения подразделения.', 403);
  return access.require(req, res, orderRight(order)) ? order : null;
}

router.get('/permits/orders/:id/parse', async (req, res, next) => {
  try {
    if (!await allowed(req, res, req.params.id)) return;
    const result = await service.review(Number(req.params.id), { again: req.query.again === '1' });
    res.render(result.order.kind === 'other' ? 'order-parse-profile' : 'order-parse', { title: `Разбор приказа № ${result.order.number}`, ...result,
      applied: req.query.applied || null, failed: req.query.failed || null });
  } catch (err) { fail(res, err, next); }
});

// Принять проверенные строки: поля строк — employee_N, value_N, weapon_N,
// from_N, to_N, accept_N (N — номер строки; count — сколько строк в форме).
router.post('/permits/orders/:id/parse/apply', async (req, res, next) => {
  try {
    if (!await allowed(req, res, req.params.id)) return;
    const count = Math.min(Number(req.body.count) || 0, 2000);
    const rows = [];
    for (let i = 0; i < count; i += 1) {
      if (req.body[`accept_${i}`] !== 'on') continue;
      rows.push({
        employeeId: Number(req.body[`employee_${i}`]) || null,
        valueId: req.body[`value_${i}`] || null,
        weaponId: Number(req.body[`weapon_${i}`]) || null,
        dateFrom: String(req.body[`from_${i}`] || ''),
        dateTo: String(req.body[`to_${i}`] || ''),
      });
    }
    const results = await service.apply(Number(req.params.id), rows, req.user.id);
    const ok = results.filter((x) => x.ok).length;
    const bad = results.filter((x) => !x.ok).map((x) => x.message);
    res.redirect(`/permits/orders/${Number(req.params.id)}/parse?applied=${ok}`
      + (bad.length ? `&failed=${encodeURIComponent(bad.slice(0, 5).join('; '))}` : ''));
  } catch (err) { fail(res, err, next); }
});

// Словарь разбора и виды приказов: что как пишется и что делать с людьми.
// Действуют на разбор всей части — ведет тот, кто ведет приказы, и без
// ограничения подразделением (как и сам разбор).
const canDictionary = (req) => !req.user.scope_unit_id
  && (access.can(req.user, 'permit.manage') || access.can(req.user, 'absence.manage'));
const denyDictionary = (req, res) => res.status(403).render('error', { title: 'Недостаточно прав',
  message: 'Словарь разбора и виды приказов ведет пользователь без ограничения подразделения: они действуют на всю часть.' });

router.get('/orders/parse', async (req, res, next) => {
  try {
    if (!canDictionary(req)) return denyDictionary(req, res);
    const [phrases, dict, sections, profiles] = await Promise.all([service.listPhrases(), service.dictionary(),
      service.listSections(), service.listProfiles()]);
    res.render('order-parse-dictionary', { title: 'Словарь разбора приказов', phrases, dict, sections, profiles,
      kinds: service.KINDS, open: String(req.query.open || '') });
  } catch (err) { next(err); }
});

router.post('/orders/parse/phrases', async (req, res, next) => {
  try {
    if (!canDictionary(req)) return denyDictionary(req, res);
    await service.addPhrase(req.body, req.user.id);
    const back = String(req.body.back || '');
    res.redirect(/^\/permits\/orders\/\d+\/parse$/.test(back) ? back
      : `/orders/parse?open=${encodeURIComponent(String(req.body.kind || ''))}#section-${encodeURIComponent(String(req.body.kind || ''))}`);
  } catch (err) { fail(res, err, next); }
});

// Свои виды приказов («Приказ на караул»): как узнать и что делать с людьми.
router.post('/orders/parse/profiles', async (req, res, next) => {
  try {
    if (!canDictionary(req)) return denyDictionary(req, res);
    const id = await service.createProfile(req.body, req.user.id);
    res.redirect(`/orders/parse?open=profile-${id}#profile-${id}`);
  } catch (err) { fail(res, err, next); }
});

router.post('/orders/parse/profiles/:id', async (req, res, next) => {
  try {
    if (!canDictionary(req)) return denyDictionary(req, res);
    await service.updateProfile(req.params.id, req.body);
    res.redirect(`/orders/parse?open=profile-${Number(req.params.id)}#profile-${Number(req.params.id)}`);
  } catch (err) { fail(res, err, next); }
});

router.post('/orders/parse/profiles/:id/delete', async (req, res, next) => {
  try {
    if (!canDictionary(req)) return denyDictionary(req, res);
    await service.removeProfile(req.params.id);
    res.redirect('/orders/parse#profiles');
  } catch (err) { fail(res, err, next); }
});

router.post('/orders/parse/phrases/:id/delete', async (req, res, next) => {
  try {
    if (!canDictionary(req)) return denyDictionary(req, res);
    await service.deletePhrase(req.params.id);
    res.redirect('/orders/parse');
  } catch (err) { fail(res, err, next); }
});

module.exports = router;
