'use strict';

const express = require('express');
const service = require('./service');
const v=require('../../lib/validation');
const access=require('../access/service');
const db=require('../../db/pool');

// Сведения о нарядах живут в модуле «Наряды», и обращаться к их таблицам
// отсюда нельзя — только через его публичный интерфейс. Обратной зависимости
// нет: duty/service подключает personnel/service, но не personnel/routes,
// поэтому кольца не возникает.
const dutyService = require('../duty/service');
const orderparse = require('../orderparse/service');
const upload = require('../../lib/upload');
const sortable = require('../../lib/sortable');
const documents = require('../../lib/documents');
const org = require('../org/service');
const muster = require('./muster');

const router = express.Router();

/** Сегодняшняя дата в формате YYYY-MM-DD по местному времени. */
function today() {
  const now = new Date();
  const offset = now.getTimezoneOffset() * 60 * 1000;
  return new Date(now.getTime() - offset).toISOString().slice(0, 10);
}

// ----------------------------------------------------------------------------
// Строевая записка
//
// Форма — приложение № 10 к Уставу внутренней службы ВС РФ. Расчет ведется
// «сегодня на завтра» (раздел 9.2), поэтому по умолчанию открываются
// ЗАВТРАШНИЕ сутки: записка подается накануне.
//
// Ниже записки — тот же личный состав деревом подразделений, и уже там
// проставляются отсутствия. Наряд и отсыпной руками не вносятся: они
// вычисляются из назначений, и вторая запись о том же разошлась бы с первой.
// ----------------------------------------------------------------------------

/**
 * Данные записки на дату: дерево с состоянием людей и сам расчет.
 *
 * Собирается один раз и для экрана, и для бланка: печать, посчитанная
 * отдельно, рано или поздно разойдется с тем, что видел человек.
 */
async function musterOn(user, onDate) {
  const [tree, units, absences, duty, types] = await Promise.all([
    org.personnelTree(user),
    org.listUnits(user),
    service.listAbsencesOnDate(onDate),
    dutyService.getDutyState(onDate),
    service.listAbsenceTypes(),
  ]);

  const byEmployee = new Map(absences.map((a) => [a.employee_id, a]));

  // Состояние дописывается прямо к людям в дереве: страница показывает
  // структуру подразделений, а не плоский список.
  const mark = (nodes) => nodes.forEach((unit) => {
    unit.employees = unit.employees.map((e) => {
      const absence = byEmployee.get(e.id) || null;
      return {
        ...e,
        absence,
        absentReason: absence ? absence.reason : null,
        onDuty: duty.onDuty.get(e.id) || null,
        resting: duty.resting.get(e.id) || null,
        justRested: duty.justRested.get(e.id) || null,
      };
    });
    mark(unit.children);
  });
  mark(tree);

  return {
    tree,
    units,
    types,
    report: muster.build({ tree, absences: byEmployee, dutyState: duty, onDate }),
  };
}

router.get('/personnel', async (req, res, next) => {
  try {
    if (!access.require(req, res, 'personnel.view')) return;
    const date = String(req.query.date || '');
    const onDate = v.isDate(date) ? date : plusDays(today(), 1);

    const { report } = await musterOn(req.user, onDate);

    res.render('muster', {
      title: 'Строевая записка',
      report,
      onDate,
      today: today(),
      scoped: Boolean(req.user.scope_unit_id),
      canAbsence: access.can(req.user, 'absence.manage'),
    });
  } catch (err) {
    next(err);
  }
});

// Список личного состава отдельной страницей: полторы сотни человек с
// формами отметки отсутствия и перевода заметно тяжелее записки, и держать
// их вместе значит замедлять обе. Состояние на дату считается тем же кодом.
// ----------------------------------------------------------------------------
// Вкладка «Личный состав»: люди по подразделениям (без вакансий), поиск,
// прием на службу; правка и исключение — в карточке человека.
// ----------------------------------------------------------------------------

router.get('/people', async (req, res, next) => {
  try {
    if (!access.require(req, res, 'personnel.view')) return;
    const [tree, units, absences, unplaced, excluded] = await Promise.all([
      org.personnelTree(req.user), org.listUnits(req.user), service.listAbsencesOnDate(today()),
      org.unplaced(req.user), service.listExcluded(req.user),
    ]);
    res.render('people', {
      title: 'Личный состав', tree, units, unplaced, excluded,
      absentToday: new Map(absences.map((a) => [a.employee_id, a])),
      canStaff: access.can(req.user, 'staff.manage'),
    });
  } catch (err) {
    next(err);
  }
});

router.get('/people/new', async (req, res, next) => {
  try {
    if (!access.require(req, res, 'staff.manage')) return;
    const [ranks, vacancies, units] = await Promise.all([
      service.listRanks(), org.vacantPositions(req.user), org.listUnits(req.user),
    ]);
    res.render('person-new', {
      title: 'Принять на службу', ranks, vacancies,
      transferUnits: units.map((u) => ({ id: u.id, parent: u.parent_id, name: u.short_name })),
    });
  } catch (err) {
    next(err);
  }
});

const failPeople = (res, err, next) => {
  if (!err.userMessage) return next(err);
  res.status(err.status || 400).render('error', { title: 'Ошибка', message: err.message });
};

router.post('/people', async (req, res, next) => {
  try {
    if (!access.require(req, res, 'staff.manage')) return;
    const id = await db.transaction(() => service.hireEmployee(req.user, req.body));
    res.redirect(`/personnel/${id}`);
  } catch (err) { failPeople(res, err, next); }
});

router.post('/personnel/:id/data', async (req, res, next) => {
  try {
    if (!access.require(req, res, 'staff.manage')) return;
    await service.editEmployee(req.user, req.params.id, req.body);
    res.redirect(`/personnel/${Number(req.params.id)}#data`);
  } catch (err) { failPeople(res, err, next); }
});

// Исключение из списков: должность, оружие, командирство, ВРИО — сняты;
// будущие наряды — сняты (их приказы в проект); прошлое — сохраняется.
router.post('/personnel/:id/exclude', async (req, res, next) => {
  try {
    if (!access.require(req, res, 'staff.manage')) return;
    await db.transaction(async () => {
      await service.excludeEmployee(req.user, req.params.id, req.body.reason);
      await dutyService.dropFromFutureDuties(Number(req.params.id), req.user.id);
    });
    res.redirect(`/personnel/${Number(req.params.id)}#data`);
  } catch (err) { failPeople(res, err, next); }
});

router.post('/personnel/:id/restore', async (req, res, next) => {
  try {
    if (!access.require(req, res, 'staff.manage')) return;
    await service.restoreEmployee(req.user, req.params.id);
    res.redirect(`/personnel/${Number(req.params.id)}#data`);
  } catch (err) { failPeople(res, err, next); }
});

router.get('/personnel/roster', async (req, res, next) => {
  try {
    if (!access.require(req, res, 'personnel.view')) return;
    const date = String(req.query.date || '');
    const onDate = v.isDate(date) ? date : plusDays(today(), 1);

    const { tree, units, types } = await musterOn(req.user, onDate);

    res.render('roster', {
      title: 'Личный состав',
      tree,
      units,
      types,
      onDate,
      scoped: Boolean(req.user.scope_unit_id),
      canAbsence: access.can(req.user, 'absence.manage'),
    });
  } catch (err) {
    next(err);
  }
});

// Печатный бланк записки — лицевая и оборотная стороны.
router.get('/personnel/print', async (req, res, next) => {
  try {
    if (!access.require(req, res, 'personnel.view')) return;
    const date = String(req.query.date || '');
    const onDate = v.isDate(date) ? date : plusDays(today(), 1);

    const { report } = await musterOn(req.user, onDate);

    res.render('print/muster', {
      title: `Строевая записка на ${onDate}`,
      report,
      // Наименование берется из корня области видимости: у командира роты
      // записка своя, и шапка должна называть его подразделение.
      unitName: report.rows[0] ? report.rows[0].name : '',
      // Прикомандированные в системе пока не ведутся. Перечень передается
      // пустым, и раздел в бланк не попадает — пустой раздел в документе
      // означал бы лист, который подписывают ни за чем.
      attached: [],
      printedAt: new Date(),
    });
  } catch (err) {
    next(err);
  }
});

// Отметка об отсутствии. Вносится руками; те же правила достанутся разбору
// приказа (МС-3), поэтому проверки живут в сервисе, а не в форме.
router.post('/personnel/:id/absence', async (req, res, next) => {
  try {
    if (!access.require(req, res, 'absence.manage')) return;

    const id = v.id(req.params.id);
    const [employee] = await service.getByIds([id]);
    if (!employee) v.fail('Человек не найден.', 404);
    await org.assertInScope(req.user, employee.unit_id, 'подразделение');

    await service.recordAbsence({
      employeeId: id,
      typeCode: String(req.body.typeCode || ''),
      dateFrom: String(req.body.dateFrom || ''),
      dateTo: String(req.body.dateTo || ''),
      documentRef: req.body.documentRef,
      note: req.body.note,
      openEnded: req.body.openEnded === 'on',
      orderId: req.body.orderId || null,
      userId: req.user.id,
    });

    res.redirect(back(req, `#emp-${id}`));
  } catch (err) {
    if (!err.userMessage) return next(err);
    res.status(err.status || 400).render('error', { title: 'Ошибка', message: err.message });
  }
});

// Досрочное прекращение отсутствия (любого, в т.ч. бессрочного): дата, по
// которую человек отсутствовал. «Снять» — другое: отсутствия не было.
router.post('/absences/:id/end', async (req, res, next) => {
  try {
    if (!access.require(req, res, 'absence.manage')) return;
    const absence = await service.getAbsence(v.id(req.params.id));
    if (!absence) v.fail('Запись об отсутствии не найдена.', 404);
    await org.assertInScope(req.user, absence.unit_id, 'подразделение');
    await service.endAbsence(absence.id, String(req.body.dateTo || ''));
    res.redirect(back(req, `#emp-${absence.employee_id}`));
  } catch (err) {
    if (!err.userMessage) return next(err);
    res.status(err.status || 400).render('error', { title: 'Ошибка', message: err.message });
  }
});

router.post('/absences/:id/cancel', async (req, res, next) => {
  try {
    if (!access.require(req, res, 'absence.manage')) return;

    const absence = await service.getAbsence(v.id(req.params.id));
    if (!absence) v.fail('Запись об отсутствии не найдена.', 404);
    await org.assertInScope(req.user, absence.unit_id, 'подразделение');

    await service.cancelAbsence(absence.id, req.user.id);
    res.redirect(back(req, `#emp-${absence.employee_id}`));
  } catch (err) {
    if (!err.userMessage) return next(err);
    res.status(err.status || 400).render('error', { title: 'Ошибка', message: err.message });
  }
});

/**
 * Возврат после отметки: в карточку человека (back=/personnel/<id>) — к
 * разделу отсутствий; иначе в список личного состава на ту же дату.
 */
function back(req, anchor) {
  const date = String(req.body.back || '');
  if (/^\/personnel\/\d+$/.test(date)) return `${date}#absences`;
  return `/personnel/roster${v.isDate(date) ? `?date=${date}` : ''}${anchor}`;
}

/** Дата через указанное число суток от сегодняшней. */
function plusDays(date, days) {
  const base = new Date(`${date}T12:00:00`);
  base.setDate(base.getDate() + days);
  const offset = base.getTimezoneOffset() * 60 * 1000;
  return new Date(base.getTime() - offset).toISOString().slice(0, 10);
}

// ----------------------------------------------------------------------------
// Карточка человека
//
// Отвечает на вопрос «почему его предлагают или не предлагают»: состояние на
// сегодня, допуски, очередь заступления по частям и личные поправки к постам.
// Поправки правятся и здесь, и на странице «Подбор» со стороны поста — это
// одна и та же запись, показанная с двух сторон.
// ----------------------------------------------------------------------------

router.get('/personnel/:id', async (req, res, next) => {
  try {
    if (!access.require(req, res, 'personnel.view')) return;

    const id = v.id(req.params.id);
    const onDate = today();

    const [employee] = await service.getByIds([id]);
    if (!employee) v.fail('Человек не найден.', 404);
    await org.assertInScope(req.user, employee.unit_id, 'подразделение');

    const [permits, posts, personal, rankWeights, dutyState, queueState, unitPath, absences,
      permitTypes, orders, weapons]
      = await Promise.all([
        service.listPermitsFor(id, onDate),
        dutyService.listAllPosts(),
        dutyService.listEmployeePostWeights(null, id),
        dutyService.listPostRankWeights(null),
        dutyService.getDutyState(onDate),
        dutyService.employeeQueueState(id, onDate),
        // За штатом подразделения нет — и пути к нему тоже.
        employee.unit_id ? org.path(employee.unit_id) : [],
        service.listAbsencesFor(id, onDate, plusDays(onDate, 180)),
        service.listPermitTypes(),
        service.listOrders(null),
        service.weaponsOf(id),
      ]);

    const personalByPost = new Map(personal.map((w) => [w.post_id, w]));
    const rankByPost = new Map(
      rankWeights.filter((w) => w.rank_id === employee.rank_id).map((w) => [w.post_id, w.weight]),
    );
    const validPermits = new Set(permits.filter((p) => p.valid).map((p) => p.permit_type_id));

    // Посты сгруппированы по виду наряда: их три десятка, и без разбивки
    // таблица перестает читаться.
    const groups = [];
    for (const post of posts.filter((p) => p.is_active)) {
      let group = groups.find((g) => g.code === post.duty_code);
      if (!group) {
        group = { code: post.duty_code, name: post.duty_name, posts: [] };
        groups.push(group);
      }

      const own = personalByPost.get(post.id);
      group.posts.push({
        id: post.id,
        name: post.name,
        unit: post.unit_short,
        rankWeight: rankByPost.has(post.id) ? rankByPost.get(post.id) : null,
        weight: own ? own.weight : '',
        note: own ? own.note : '',
        // Поправка к посту, к которому нет допуска, ни на что не влияет:
        // допуск — запрет, и весами он не обходится.
        permitted: !post.required_permit_type_id || validPermits.has(post.required_permit_type_id),
      });
    }

    res.render('employee-card', {
      title: employee.short_name,
      employee,
      unitPath,
      permits,
      absences,
      groups,
      queueState,
      onDate,
      onDuty: dutyState.onDuty.get(id) || null,
      resting: dutyState.resting.get(id) || null,
      justRested: dutyState.justRested.get(id) || null,
      corrections: personal.length,
      permitTypes,
      orders,
      weapons,
      absenceTypes: await service.listAbsenceTypes(),
      absenceOrders: (await service.listAbsenceOrders()).slice(0, 50),
      canAbsence: access.can(req.user, 'absence.manage'),
      ranks: await service.listRanks(),
      canStaff: access.can(req.user, 'staff.manage'),
      canManageQueue: access.can(req.user, 'queue.manage'),
      // Перевод на вакантную должность — в пределах своего подразделения;
      // кадровику и администратору — любого на любую.
      canTransfer: access.can(req.user, 'personnel.assign'),
      vacancies: access.can(req.user, 'personnel.assign') ? await org.vacantPositions(req.user) : [],
      // Подразделения зоны — для выбора по уровням: рота → взвод → отделение.
      transferUnits: access.can(req.user, 'personnel.assign')
        ? (await org.listUnits(req.user)).map((u) => ({ id: u.id, parent: u.parent_id, name: u.short_name }))
        : [],
      canManagePermits: access.can(req.user, 'permit.manage'),
    });
  } catch (err) {
    next(err);
  }
});

router.post('/personnel/:id/post-weights', async (req, res, next) => {
  try {
    if (!access.require(req, res, 'queue.manage')) return;

    const id = v.id(req.params.id);
    const [employee] = await service.getByIds([id]);
    if (!employee) v.fail('Человек не найден.', 404);
    await org.assertInScope(req.user, employee.unit_id, 'подразделение');

    // Записываются только изменившиеся поправки: карточка отправляет все три
    // десятка постов сразу, и без сравнения каждое сохранение переписывало бы
    // весь перечень исключений вместе с датами правки.
    await db.transaction(async () => {
    const current = new Map(
      (await dutyService.listEmployeePostWeights(null, id)).map((w) => [w.post_id, w]),
    );

    for (const [key, value] of Object.entries(req.body)) {
      const match = /^weight_(\d+)$/.exec(key);
      if (!match) continue;

      const postId = Number(match[1]);
      const was = current.get(postId);
      const weight = String(value).trim();
      const note = String(req.body[`note_${postId}`] || '').trim();

      const sameWeight = was ? String(was.weight) === weight : weight === '';
      if (sameWeight && (weight === '' || (was.note || '') === note)) continue;

      await dutyService.setEmployeePostWeight({
        employeeId: id, postId, weight, note, userId: req.user.id,
      });
    }
    });

    res.redirect(`/personnel/${id}`);
  } catch (err) {
    if (!err.userMessage) return next(err);
    res.status(err.status || 400).render('error', { title: 'Ошибка', message: err.message });
  }
});


// ----------------------------------------------------------------------------
// Приказы на допуск
//
// Каталог: направление — год — приказ. Приказ открывается ПДФ-ом, чем бы его
// ни прислали: DOC пересохраняется при загрузке, потому что читать документ
// должны все одинаково и без офисного пакета на рабочем месте.
// ----------------------------------------------------------------------------

// ----------------------------------------------------------------------------
// «Приказы»: хранилище приказов по назначению — допуски, отсутствия и
// приказы на наряды (по вкладке на вид наряда).
// ----------------------------------------------------------------------------

/** Вкладки раздела «Приказы»: какая открыта и какие виды нарядов есть. */
async function ordersTabs(req, active) {
  return {
    active,
    dutyTypes: access.can(req.user, 'duty.view') ? await dutyService.listDutyTypes() : [],
  };
}

/** Право на приказ реестра — по его виду. */
// «Прочие» (свои виды — караул и т. п.) отмечают отсутствия — право как у отсутствий.
const orderRight = (order) => (order && ['absence', 'other'].includes(order.kind) ? 'absence.manage' : 'permit.manage');
const ORDER_TAB = { permit: 'permits', absence: 'absences', other: 'other' };
const ORDER_LIST = { permit: '/permits', absence: '/orders/absences', other: '/orders/other' };

// ----------------------------------------------------------------------------
// «Мои данные»: свое — без права просмотра личного состава. Наряды,
// допуски, отсутствия, закрепленное оружие; сеансы и смена пароля.
// ----------------------------------------------------------------------------

router.get('/me', async (req, res, next) => {
  try {
    const onDate = today();
    const sessions = await access.listSessions(req.user.id, req.session.id);
    const id = req.user.employee_id;
    const [employee] = id ? await service.getByIds([id]) : [];
    if (!employee) {
      return res.render('me', { title: 'Мои данные', employee: null, sessions, onDate });
    }
    const [unitPath, duties, permits, absences, weapons] = await Promise.all([
      employee.unit_id ? org.path(employee.unit_id) : [],
      dutyService.employeeAssignments(id, plusDays(onDate, -30), plusDays(onDate, 60)),
      service.listPermitsFor(id, onDate),
      service.listAbsencesFor(id, plusDays(onDate, -30), plusDays(onDate, 180)),
      service.weaponsOf(id),
    ]);
    res.render('me', { title: 'Мои данные', employee, unitPath, duties, permits, absences, weapons, sessions, onDate });
  } catch (err) {
    next(err);
  }
});

// Выйти на других компьютерах: текущий сеанс остается.
router.post('/me/sessions/end-others', async (req, res, next) => {
  try {
    await access.endSessions(req.user.id, req.user.id, req.session.id);
    res.redirect('/me#sessions');
  } catch (err) {
    next(err);
  }
});

router.get('/orders', (req, res) => res.redirect('/permits'));

router.get('/orders/absences', async (req, res, next) => {
  try {
    if (!access.require(req, res, 'personnel.view')) return;
    const orders = await service.listAbsenceOrders();
    const years = new Map();
    for (const o of orders) {
      if (!years.has(o.year)) years.set(o.year, []);
      years.get(o.year).push(o);
    }
    res.render('orders-absences', {
      title: 'Приказы — отсутствия', years: [...years.entries()],
      tabs: await ordersTabs(req, 'absences'),
      canManage: access.can(req.user, 'absence.manage'),
      maxSize: Math.round(upload.MAX_BYTES / (1024 * 1024)),
    });
  } catch (err) {
    next(err);
  }
});

// «Прочие»: приказы своих видов (караул и т. п.) — по виду, затем по годам.
router.get('/orders/other', async (req, res, next) => {
  try {
    if (!access.require(req, res, 'personnel.view')) return;
    const [orders, profiles] = await Promise.all([service.listOtherOrders(), orderparse.listProfiles()]);
    res.render('orders-other', {
      title: 'Приказы — прочие', orders, profiles,
      tabs: await ordersTabs(req, 'other'),
      // Приказы своих видов нужны для разбора, а он — на всю часть.
      canManage: access.can(req.user, 'absence.manage') && !req.user.scope_unit_id,
      maxSize: Math.round(upload.MAX_BYTES / (1024 * 1024)),
    });
  } catch (err) {
    next(err);
  }
});

// «Дежурства» без выбранного вида — первый вид наряда.
router.get('/orders/duty', async (req, res, next) => {
  try {
    if (!access.require(req, res, 'duty.view')) return;
    const [first] = await dutyService.listDutyTypes();
    if (!first) return res.redirect('/permits');
    res.redirect(`/orders/duty/${first.id}`);
  } catch (err) {
    next(err);
  }
});

router.get('/orders/duty/:typeId', async (req, res, next) => {
  try {
    if (!access.require(req, res, 'duty.view')) return;
    const tabs = await ordersTabs(req, `duty-${Number(req.params.typeId)}`);
    const type = tabs.dutyTypes.find((t) => t.id === Number(req.params.typeId));
    if (!type) return res.status(404).render('error', { title: 'Не найдено', message: 'Вид наряда не найден.' });
    res.render('orders-duty', {
      title: `Приказы — ${type.code}`, type, tabs,
      orders: await dutyService.listStoredOrders(type.id),
    });
  } catch (err) {
    next(err);
  }
});

router.get('/permits', async (req, res, next) => {
  try {
    if (!access.require(req, res, 'personnel.view')) return;

    const [catalog, directions] = await Promise.all([
      service.permitCatalog(), service.listDirections(),
    ]);

    res.render('permits', {
      title: 'Приказы — допуски',
      tabs: await ordersTabs(req, 'permits'),
      catalog,
      directions,
      canManage: access.can(req.user, 'permit.manage'),
      maxSize: Math.round(upload.MAX_BYTES / (1024 * 1024)),
    });
  } catch (err) {
    next(err);
  }
});

// Порядок направлений — перетаскиванием в каталоге: соседи одного уровня
// (root — верхние направления).
router.post('/permits/directions/within/:parent/order', sortable.orderHandler(access, 'permit.manage',
  (req, ids) => service.reorderDirections(req.params.parent === 'root' ? null : req.params.parent, ids)));

router.post('/permits/directions', async (req, res, next) => {
  try {
    if (!access.require(req, res, 'permit.manage')) return;
    await service.createDirection({
      parentId: req.body.parentId || null,
      name: req.body.name,
    });
    res.redirect('/permits');
  } catch (err) {
    if (!err.userMessage) return next(err);
    res.status(err.status || 400).render('error', { title: 'Ошибка', message: err.message });
  }
});

router.post('/permits/directions/:id', async (req, res, next) => {
  try {
    if (!access.require(req, res, 'permit.manage')) return;
    await service.updateDirection(req.params.id, {
      name: req.body.name,
      isActive: req.body.isActive === 'on',
    });
    res.redirect('/permits');
  } catch (err) {
    if (!err.userMessage) return next(err);
    res.status(err.status || 400).render('error', { title: 'Ошибка', message: err.message });
  }
});

router.post('/permits/directions/:id/delete', async (req, res, next) => {
  try {
    if (!access.require(req, res, 'permit.manage')) return;
    await service.removeDirection(req.params.id);
    res.redirect('/permits');
  } catch (err) {
    if (!err.userMessage) return next(err);
    res.status(err.status || 400).render('error', { title: 'Ошибка', message: err.message });
  }
});

// Приказ заводится вместе с файлом, поэтому форма многочастная и разбирается
// отдельно: обычный разбор тела с файлами не работает.
router.post('/permits/orders', async (req, res, next) => {
  try {
    if (!access.can(req.user, 'permit.manage') && !access.can(req.user, 'absence.manage')) {
      return access.require(req, res, 'permit.manage');
    }

    const { fields, files } = await upload.parseForm(req);
    access.checkToken(req, fields._csrf);
    const kind = ['absence', 'other'].includes(fields.kind) ? fields.kind : 'permit';
    if (!access.require(req, res, orderRight({ kind }))) return;
    if (kind === 'other' && req.user.scope_unit_id) {
      v.fail('Приказы своих видов заводит пользователь без ограничения подразделения — их разбор идет на всю часть.', 403);
    }

    const id = await service.createOrder({
      kind,
      profileId: fields.profileId,
      directionId: fields.directionId,
      number: fields.number,
      issuedOn: fields.issuedOn,
      title: fields.title,
      note: fields.note,
    }, files.file && files.file.data.length > 0 ? files.file : null, req.user.id);

    res.redirect(`/permits/orders/${id}`);
  } catch (err) {
    if (!err.userMessage) return next(err);
    res.status(err.status || 400).render('error', { title: 'Ошибка', message: err.message });
  }
});

router.get('/permits/orders/:id', async (req, res, next) => {
  try {
    if (!access.require(req, res, 'personnel.view')) return;

    const order = await service.getOrder(req.params.id);
    if (!order) {
      return res.status(404).render('error', { title: 'Не найдено', message: 'Приказ не найден.' });
    }

    const scope = await org.scopeIds(req.user);
    const [permits, directions, permitTypes, employees, absences, reservations] = await Promise.all([
      service.orderPermits(order.id),
      service.listDirections(),
      service.listPermitTypes(),
      service.listEmployees(),
      service.orderAbsences(order.id),
      service.orderReservations(order.id),
    ]);

    // Командир подразделения видит по приказу только своих людей и свое
    // оружие — как и допуски.
    const mine = (unitId) => !scope || scope.includes(unitId);
    res.render('permit-order', {
      title: `Приказ № ${order.number}`,
      order,
      absences: absences.filter((a) => mine(a.unit_id)),
      reservations: reservations.filter((r) => mine(r.unit_id) || mine(r.weapon_unit_id)),
      tabs: await ordersTabs(req, ORDER_TAB[order.kind] || 'permits'),
      permits: scope ? permits.filter(p => scope.includes(p.unit_id)) : permits,
      directions,
      permitTypes,
      employees: scope ? employees.filter(e => scope.includes(e.unit_id)) : employees,
      canManage: access.can(req.user, orderRight(order)),
      maxSize: Math.round(upload.MAX_BYTES / (1024 * 1024)),
    });
  } catch (err) {
    next(err);
  }
});

router.post('/permits/orders/:id', async (req, res, next) => {
  try {
    if (req.user.scope_unit_id) v.fail('Полный документ и его изменение доступны только пользователю без ограничения подразделения.', 403);
    const kindOf = await service.getOrder(req.params.id);
    if (!access.require(req, res, orderRight(kindOf))) return;
    await service.updateOrder(req.params.id, {
      directionId: req.body.directionId,
      number: req.body.number,
      issuedOn: req.body.issuedOn,
      title: req.body.title,
      note: req.body.note,
    });
    res.redirect(`/permits/orders/${v.id(req.params.id)}`);
  } catch (err) {
    if (!err.userMessage) return next(err);
    res.status(err.status || 400).render('error', { title: 'Ошибка', message: err.message });
  }
});

router.post('/permits/orders/:id/file', async (req, res, next) => {
  try {
    if (req.user.scope_unit_id) v.fail('Полный документ и его изменение доступны только пользователю без ограничения подразделения.', 403);
    const kindOf = await service.getOrder(req.params.id);
    if (!access.require(req, res, orderRight(kindOf))) return;

    const { fields, files } = await upload.parseForm(req);
    access.checkToken(req, fields._csrf);

    await service.replaceOrderFile(req.params.id, files.file, req.user.id);
    res.redirect(`/permits/orders/${v.id(req.params.id)}`);
  } catch (err) {
    if (!err.userMessage) return next(err);
    res.status(err.status || 400).render('error', { title: 'Ошибка', message: err.message });
  }
});

router.post('/permits/orders/:id/delete', async (req, res, next) => {
  try {
    if (req.user.scope_unit_id) v.fail('Полный документ и его изменение доступны только пользователю без ограничения подразделения.', 403);
    const kindOf = await service.getOrder(req.params.id);
    if (!access.require(req, res, orderRight(kindOf))) return;
    await service.removeOrder(req.params.id);
    res.redirect(ORDER_LIST[kindOf && kindOf.kind] || '/permits');
  } catch (err) {
    if (!err.userMessage) return next(err);
    res.status(err.status || 400).render('error', { title: 'Ошибка', message: err.message });
  }
});

/**
 * Сам приказ — ПДФ-ом.
 *
 * Показывается в браузере, а не скачивается: приказ смотрят, а не собирают.
 * Если PDF построить не удалось, отдается объяснение вместо пустой страницы,
 * и рядом — ссылка на оригинал.
 */
router.get('/permits/orders/:id/pdf', async (req, res, next) => {
  try {
    if (req.user.scope_unit_id) v.fail('Полный документ и его изменение доступны только пользователю без ограничения подразделения.', 403);
    if (!access.require(req, res, 'personnel.view')) return;

    const order = await service.getOrder(req.params.id);
    if (!order) {
      return res.status(404).render('error', { title: 'Не найдено', message: 'Приказ не найден.' });
    }

    const full = documents.resolve(order.pdf_path);
    if (!full) {
      return res.status(404).render('error', {
        title: 'Приказ не открывается',
        message: order.pdf_error
          || (order.file_path ? 'PDF для этого приказа не построен.' : 'К приказу не приложен файл.'),
      });
    }

    res.type('application/pdf');
    res.setHeader('Content-Disposition',
      `inline; filename="order-${order.number.replace(/[^\w.-]/g, '_')}.pdf"`);
    res.sendFile(full, err => { if (err) next(err); });
  } catch (err) {
    next(err);
  }
});

/** Оригинал, как прислали: нужен, когда PDF не построился. */
router.get('/permits/orders/:id/file', async (req, res, next) => {
  try {
    if (req.user.scope_unit_id) v.fail('Полный документ и его изменение доступны только пользователю без ограничения подразделения.', 403);
    if (!access.require(req, res, 'personnel.view')) return;

    const order = await service.getOrder(req.params.id);
    const full = order ? documents.resolve(order.file_path) : null;
    if (!full) {
      return res.status(404).render('error', { title: 'Не найдено', message: 'Файл не приложен.' });
    }

    res.type(order.file_mime || 'application/octet-stream');
    res.download(full, documents.safeName(order.file_name || 'order'), err => { if (err) next(err); });
  } catch (err) {
    next(err);
  }
});

// Выдача и снятие допуска. Допуск всегда опирается на приказ: без основания
// он означает «допущен неизвестно кем».
router.post('/permits/grant', async (req, res, next) => {
  try {
    if (!access.require(req, res, 'permit.manage')) return;

    const [employee] = await service.getByIds([v.id(req.body.employeeId)]);
    if (!employee) v.fail('Человек не найден.', 404);
    await org.assertInScope(req.user, employee.unit_id);
    await service.grantPermit({
      employeeId: req.body.employeeId,
      permitTypeId: req.body.permitTypeId,
      orderId: req.body.orderId,
      expiresAt: req.body.expiresAt || null,
      note: req.body.note,
    });

    res.redirect('/permits');
  } catch (err) {
    if (!err.userMessage) return next(err);
    res.status(err.status || 400).render('error', { title: 'Ошибка', message: err.message });
  }
});

router.post('/permits/:id/status', async (req, res, next) => {
  try {
    if (!access.require(req, res, 'permit.manage')) return;
    const permit = await service.getPermit(v.id(req.params.id));
    if (!permit) v.fail('Допуск не найден.', 404);
    await org.assertInScope(req.user, permit.unit_id);
    await service.setPermitStatus(req.params.id, String(req.body.status || ''));
    res.redirect('/permits');
  } catch (err) {
    if (!err.userMessage) return next(err);
    res.status(err.status || 400).render('error', { title: 'Ошибка', message: err.message });
  }
});

// ----------------------------------------------------------------------------
// Оружие по подразделениям — как штат: дерево подразделений с оружием,
// перемещение за «⠿», склад (свободное) внизу, «настроить» в строке.
// ----------------------------------------------------------------------------

const backToWeapons = (unitId) => (unitId ? `/weapons?open=${unitId}#unit-${unitId}` : '/weapons#stock');
const failWeapons = (res, err, next) => {
  if (!err.userMessage) return next(err);
  res.status(err.status || 400).render('error', { title: 'Ошибка', message: err.message });
};

router.get('/weapons', async (req, res, next) => {
  try {
    if (!access.require(req, res, 'weapon.view')) return;
    const { tree, units, stock } = await service.weaponTree(req.user);
    const parentOf = new Map(units.map((u) => [u.id, u.parent_id]));
    const opened = new Set();
    for (let id = Number(req.query.open) || null; id; id = parentOf.get(id)) opened.add(id);
    res.render('weapons', {
      title: 'Оружие', tree, units, stock, opened,
      canAssign: access.can(req.user, 'weapon.assign') || access.can(req.user, 'weapon.transfer'),
      canManage: access.can(req.user, 'weapon.transfer'),
    });
  } catch (e) { next(e); }
});

// Снять занятость оружия (приказ отменен или изменен): служба вооружения
// или тот, кто ведет отсутствия по приказам на всю часть (как и разбор, из
// которого занятость берется). Командир подразделения — нет: оружие может
// быть чужим.
router.post('/weapons/reservations/:id/cancel', async (req, res, next) => {
  try {
    const reservation = await service.cancelReservation(req.user, req.params.id);
    const back = String(req.body.back || '');
    res.redirect(/^\/permits\/orders\/\d+$/.test(back) ? back
      : (reservation.order_id ? `/permits/orders/${reservation.order_id}` : '/weapons'));
  } catch (e) { failWeapons(res, e, next); }
});

router.post('/weapons', async (req, res, next) => {
  try {
    if (!access.require(req, res, 'weapon.transfer')) return;
    await service.addWeapon(req.user, req.body);
    res.redirect(backToWeapons(Number(req.body.unitId) || null));
  } catch (e) { failWeapons(res, e, next); }
});

// Выдать человеку перетаскиванием (оружие на плашку «без оружия» или
// плашку — на оружие): переезд в его подразделение и закрепление.
router.post('/weapons/:id/give', async (req, res, next) => {
  try {
    if (!access.require(req, res, 'weapon.view')) return;
    await db.transaction(() => service.giveWeapon(req.user, req.params.id, req.body.employeeId));
    const [person] = await service.getByIds([Number(req.body.employeeId)]);
    res.redirect(backToWeapons(person && person.unit_id));
  } catch (e) { failWeapons(res, e, next); }
});

router.post('/weapons/:id/move', async (req, res, next) => {
  try {
    if (!access.require(req, res, 'weapon.view')) return;
    await service.moveWeapon(req.user, req.params.id, req.body.unitId || null);
    res.redirect(backToWeapons(Number(req.body.unitId) || null));
  } catch (e) { failWeapons(res, e, next); }
});

router.post('/units/:id/weapons/order', sortable.orderHandler(access, 'weapon.view',
  (req, ids) => service.reorderWeapons(req.user, req.params.id, ids)));

// Окно «настроить»: люди подразделения для закрепления.
router.get('/weapons/:id/people', async (req, res, next) => {
  try {
    if (!access.require(req, res, 'weapon.view')) return;
    const { weapon, people } = await service.weaponPeople(req.user, req.params.id);
    res.json({ owner: weapon.owner_id, people });
  } catch (e) {
    if (e.userMessage) return res.status(e.status || 400).json({ message: e.message });
    next(e);
  }
});

router.post('/weapons/:id', async (req, res, next) => {
  try {
    if (!access.require(req, res, 'weapon.view')) return;
    const weapon = await service.getWeaponRow(req.params.id);
    if (req.body.action === 'decommission') {
      await service.decommissionWeapon(req.user, req.params.id);
    } else {
      await db.transaction(async () => {
        if (req.body.editFields) await service.editWeapon(req.user, req.params.id, req.body);
        if (req.body.employeeId === 'stock') {
          // «на склад» в списке — как корзина: только полным доступом.
          await service.moveWeapon(req.user, req.params.id, null);
        } else if (weapon && weapon.unit_id !== null) {
          // Со склада закреплять не за кем: сначала — в подразделение.
          await service.attachWeapon(req.user, req.params.id, req.body.employeeId || null);
        }
      });
    }
    res.redirect(req.body.employeeId === 'stock' ? backToWeapons(null) : backToWeapons(weapon && weapon.unit_id));
  } catch (e) { failWeapons(res, e, next); }
});
module.exports = router;
