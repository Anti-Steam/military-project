'use strict';

const express = require('express');
const service = require('./service');
const access = require('../access/service');
const v = require('../../lib/validation');

const router = express.Router();

// Журнал изменений: кто, когда, что изменил. Фильтры — даты, раздел,
// пользователь, человек (всё о нем: запись, отсутствия, должность, оружие,
// наряды). Постранично — «раньше» от последней показанной записи.
router.get('/audit', async (req, res, next) => {
  try {
    if (!access.require(req, res, 'audit.view')) return;
    const q = req.query;
    const filters = {
      from: v.isDate(String(q.from || '')) ? q.from : null,
      to: v.isDate(String(q.to || '')) ? q.to : null,
      table: service.TABLES[q.table] ? q.table : null,
      userId: Number(q.user) || null,
      employeeId: Number(q.employee) || null,
      before: Number(q.before) || null,
    };
    const [page, authors] = await Promise.all([service.journal(filters), service.listAuthors()]);
    res.render('audit', {
      title: 'Журнал изменений', ...page, authors, tables: service.TABLES, filters,
    });
  } catch (err) {
    next(err);
  }
});

module.exports = router;
