'use strict';

const express = require('express');
const service = require('./service');
const access = require('../access/service');
const sortable = require('../../lib/sortable');
const db = require('../../db/pool');

const router = express.Router();

const today = () => {
  const d = new Date();
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
};

const fail = (res, err, next) => {
  if (!err.userMessage) return next(err);
  return res.status(err.status || 400).render('error', { title: 'Ошибка', message: err.message });
};

// ----------------------------------------------------------------------------
// Структура подразделений
// ----------------------------------------------------------------------------

// После правки возвращаемся к тому же подразделению — раскрытым, вместе с
// вышестоящими: иначе после каждого сохранения дерево сворачивалось бы.
const backTo = (unitId) => (unitId ? `/units?open=${unitId}#unit-${unitId}` : '/units');

router.get('/units', async (req, res, next) => {
  try {
    if (!access.require(req, res, 'unit.manage')) return;

    // Дерево вместе с людьми: нажатие на подразделение раскрывает его
    // личный состав и вложенные подразделения.
    const [tree, units] = await Promise.all([
      service.personnelTree(req.user), service.listUnits(req.user),
    ]);

    const parentOf = new Map(units.map((u) => [u.id, u.parent_id]));
    const opened = new Set();
    for (let id = Number(req.query.open) || null; id; id = parentOf.get(id)) opened.add(id);

    res.render('units', {
      title: 'Подразделения',
      tree,
      units,
      opened,
      scoped: Boolean(req.user.scope_unit_id),
      canTransfer: access.can(req.user, 'personnel.assign'),
      canStaff: access.can(req.user, 'staff.manage'),
      // За штатом — одним списком внизу страницы, под всеми подразделениями.
      unplaced: await service.unplaced(req.user),
      // Кто сегодня отсутствует — пометкой у фамилии (отметка — в карточке).
      absentToday: new Map((await require('../personnel/service').listAbsencesOnDate(today()))
        .map((a) => [a.employee_id, a])),
    });
  } catch (err) {
    next(err);
  }
});

router.post('/units', async (req, res, next) => {
  try {
    if (!access.require(req, res, 'unit.manage')) return;

    await service.createUnit(req.user, {
      parentId: req.body.parentId,
      name: req.body.name,
      shortName: req.body.shortName,
    });

    res.redirect(backTo(req.body.parentId));
  } catch (err) {
    fail(res, err, next);
  }
});

router.post('/units/:id', async (req, res, next) => {
  try {
    if (!access.require(req, res, 'unit.manage')) return;

    // Окно «изменить» сохраняется целиком, одной транзакцией: подразделение,
    // новое вложенное (если заполнено) и новые должности (если есть).
    const list = (x) => (Array.isArray(x) ? x : [x]).map((t) => String(t || '').trim()).filter(Boolean);
    await db.transaction(async () => {
      await service.updateUnit(req.user, req.params.id, {
        name: req.body.name,
        shortName: req.body.shortName,
        parentId: req.body.parentId,
        isActive: req.body.isActive === 'on',
      });
      const childName = String(req.body.childName || '').trim();
      const childShort = String(req.body.childShort || '').trim();
      if (childName || childShort) {
        await service.createUnit(req.user, { parentId: req.params.id, name: childName, shortName: childShort });
      }
      for (const title of list(req.body.newPositions)) {
        await service.addPosition(req.user, req.params.id, title);
      }
    });

    res.redirect(backTo(req.params.id));
  } catch (err) {
    fail(res, err, next);
  }
});

// Порядок вложенных подразделений — перетаскиванием в дереве.
router.post('/units/:id/order', sortable.orderHandler(access, 'unit.manage',
  (req, ids) => service.reorderChildren(req.user, req.params.id, ids)));

// Командир подразделения — занимающий его командирскую должность; какая
// должность командирская, отмечает кадровик.
router.post('/positions/:id/commander', async (req, res, next) => {
  try {
    if (!access.require(req, res, 'staff.manage')) return;
    await service.setCommanderPosition(req.user, req.params.id);
    res.redirect(backTo(Number(req.body.unitId) || null));
  } catch (err) {
    fail(res, err, next);
  }
});

router.post('/units/:id/delete', async (req, res, next) => {
  try {
    if (!access.require(req, res, 'unit.manage')) return;
    const unit = await service.getUnit(req.params.id);
    await service.removeUnit(req.user, req.params.id);
    res.redirect(backTo(unit && unit.parent_id));
  } catch (err) {
    fail(res, err, next);
  }
});

// ----------------------------------------------------------------------------
// Распределение личного состава
// ----------------------------------------------------------------------------

// Перевод на вакантную должность — перетаскиванием во вкладке
// «Подразделения» (с подтверждением) и из карточки человека. Возврат — туда,
// откуда переводили.
function safeBack(back, fallback) {
  const text = String(back || '');
  return /^\/(units|personnel\/\d+)(?:[/?#]|$)/.test(text) && !text.includes('\\') ? text : fallback;
}

router.post('/personnel/transfer', async (req, res, next) => {
  try {
    if (!access.require(req, res, 'personnel.assign')) return;
    await service.transferEmployee(req.user, req.body.employeeId, req.body.positionId);
    const position = await service.positionOf(req.body.employeeId);
    res.redirect(safeBack(req.body.back, backTo(position && position.unit_id)));
  } catch (err) {
    fail(res, err, next);
  }
});

// ----------------------------------------------------------------------------
// Штат: должности (кадровик и администратор)
// ----------------------------------------------------------------------------

// Порядок должностей подразделения — перетаскиванием за «⠿».
router.post('/units/:id/positions/order', sortable.orderHandler(access, 'staff.manage',
  (req, ids) => service.reorderPositions(req.user, req.params.id, ids)));

// ВРИО командира: кандидаты (JSON — окно «изменить» подгружает их само),
// назначение на период, отмена. Ведет кадровик.
router.get('/units/:id/acting', async (req, res, next) => {
  try {
    if (!access.require(req, res, 'staff.manage')) return;
    res.json(await service.actingPanel(req.user, req.params.id));
  } catch (err) {
    if (err.userMessage) return res.status(err.status || 400).json({ message: err.message });
    next(err);
  }
});

router.post('/units/:id/acting', async (req, res, next) => {
  try {
    if (!access.require(req, res, 'staff.manage')) return;
    await service.assignActing(req.user, {
      unitId: req.params.id, employeeId: req.body.employeeId,
      dateFrom: req.body.dateFrom, dateTo: req.body.dateTo, reason: req.body.reason,
    }, req.user.id);
    res.redirect(backTo(Number(req.params.id)));
  } catch (err) {
    fail(res, err, next);
  }
});

router.post('/acting/:id/cancel', async (req, res, next) => {
  try {
    if (!access.require(req, res, 'staff.manage')) return;
    const acting = await service.cancelActing(req.user, req.params.id);
    res.redirect(backTo(acting.unit_id));
  } catch (err) {
    fail(res, err, next);
  }
});

// Человек «в корзину» — за штат: должность становится вакантной.
router.post('/personnel/:id/release', async (req, res, next) => {
  try {
    if (!access.require(req, res, 'staff.manage')) return;
    const released = await service.releaseEmployee(req.user, req.params.id);
    res.redirect(backTo(released ? released.unit_id : null));
  } catch (err) {
    fail(res, err, next);
  }
});

// Перенос должности в другое подразделение — вместе с тем, кто ее занимает.
router.post('/positions/:id/move', async (req, res, next) => {
  try {
    if (!access.require(req, res, 'staff.manage')) return;
    await service.movePosition(req.user, req.params.id, req.body.unitId);
    res.redirect(backTo(Number(req.body.unitId) || null));
  } catch (err) {
    fail(res, err, next);
  }
});

// Настройка должности из ее строки: наименование и «командирская».
router.post('/positions/:id', async (req, res, next) => {
  try {
    if (!access.require(req, res, 'staff.manage')) return;
    await service.updatePosition(req.user, req.params.id, {
      title: req.body.title,
      isCommander: req.body.commanderField ? req.body.isCommander === 'on' : undefined,
    });
    res.redirect(backTo(Number(req.body.unitId) || null));
  } catch (err) {
    fail(res, err, next);
  }
});

router.post('/positions/:id/delete', async (req, res, next) => {
  try {
    if (!access.require(req, res, 'staff.manage')) return;
    const removed = await service.removePosition(req.user, req.params.id);
    res.redirect(backTo(removed.unit_id));
  } catch (err) {
    fail(res, err, next);
  }
});

module.exports = router;
