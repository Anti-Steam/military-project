'use strict';

const express = require('express');
const service = require('./service');
const access = require('../access/service');
const duty = require('../duty/service');

const router = express.Router();

// Печатная форма приказа. Открывается в новой вкладке и печатается
// средствами браузера.
router.get('/duties/:id/order', async (req, res, next) => {
  try {
    if (!access.require(req, res, 'duty.view')) return;
    const order = await service.buildOrder(Number(req.params.id));

    if (!order) {
      return res.status(404).render('error', { title: 'Не найдено', message: 'Наряд не найден.' });
    }

    // Приказ охватывает весь приказной блок, поэтому назван по сроку выпуска,
    // а не по номеру одного наряда: нарядов в нем несколько.
    res.render('print/order', {
      title: `Приказ на наряд ${order.dutyType.code} от ${order.orderDate}`,
      ...order,
      doc: duty.orderLayout(order),
      back: '/duties',
    });
  } catch (err) {
    next(err);
  }
});

module.exports = router;
