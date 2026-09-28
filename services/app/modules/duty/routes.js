'use strict';

const express = require('express');
const service = require('./service');
const access = require('../access/service');
const cal = require('./calendar');
const v=require('../../lib/validation');
const personnel=require('../personnel/service');
const org=require('../org/service');
const db=require('../../db/pool');
const sortable = require('../../lib/sortable');

const router = express.Router();
router.use((req,res,next)=>{
 try {
   for(const source of [req.query,req.body || {}]) for(const [key,value] of Object.entries(source)) {
     if(['date','startDate','dateFrom','dateTo'].includes(key) && value) v.date(value);
     if(['dutyTypeId','unitId','postId','employeeId'].includes(key) && value) v.id(value);
   }
   const match=/^\/duties\/(\d+)\/(edit|replace|withdraw)$/.exec(req.path);
   if(match) return service.getDuty(v.id(match[1])).then(d=>{
     if(!d) v.fail('Наряд не найден.',404);
     if(cal.dayKey(d.starts_at)<=cal.dayKey(new Date()) || d.status==='cancelled') {
       if(req.method==='GET') return res.redirect(`/duties/${d.id}`);
       v.fail('Текущие, прошедшие и отменённые наряды изменять нельзя.');
     }
     next();
   }).catch(next);
   next();
 } catch(e) {next(e);}
});

/**
 * Назначения приходят из формы полями вида post_<id> со значением
 * «идентификатор сотрудника». Пустое значение — пост не замещен.
 */
function parseAssignments(body) {
  const assignments = [];

  for (const [key, value] of Object.entries(body)) {
    const match = /^post_(\d+)$/.exec(key);
    if (!match || !value) continue;

    const employeeId = Number(value);
    if (Number.isInteger(employeeId)) {
      assignments.push({ postId: Number(match[1]), employeeId });
    }
  }

  return assignments;
}

const isDate = v.isDate;

/**
 * Кто заступает на пост — из общей формы поста. Строк подразделений и людей
 * столько, сколько их заполнили; пустые строки пропускаются.
 */
function staffingForm(body) {
  const list = (value) => (Array.isArray(value) ? value : [value]).filter((x) => x !== undefined);
  return {
    unitIds: list(body.unitIds),
    rotationSince: body.rotationSince,
    employeeIds: list(body.employeeIds),
  };
}


/** Сегодняшняя дата в формате YYYY-MM-DD по местному времени. */
function today() {
  const now = new Date();
  const offset = now.getTimezoneOffset() * 60 * 1000;
  return new Date(now.getTime() - offset).toISOString().slice(0, 10);
}

/** Год и месяц из строки YYYY-MM; при неверном значении — текущий месяц. */
function parseMonth(value) {
  const match = /^(\d{4})-(\d{2})$/.exec(String(value || ''));
  if (match) {
    const year = Number(match[1]);
    const month = Number(match[2]);
    if (year>=1900 && year<=9998 && month >= 1 && month <= 12) return { year, month };
  }
  const now = new Date();
  return { year: now.getFullYear(), month: now.getMonth() + 1 };
}

function shiftMonth(year, month, delta) {
  const date = new Date(year, month - 1 + delta, 1);
  return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, '0')}`;
}

// ----------------------------------------------------------------------------
// График нарядов
// ----------------------------------------------------------------------------

// Вкладка на каждый вид наряда: составы у них разные, и смешивать их в одной
// сетке значит заставлять читателя разбираться, чей день перед ним.
router.get('/duties', async (req, res, next) => {
  try {
    if (!access.require(req, res, 'duty.view')) return;
    const [dutyTypes, units] = await Promise.all([
      service.listDutyTypes(),
      service.listUnits(),
    ]);

    if (dutyTypes.length === 0) {
      return res.render('error', {
        title: 'Наряды', message: 'Не заведен ни один вид наряда.',
      });
    }

    const requested = Number(req.query.type);
    const dutyType = dutyTypes.find((t) => t.id === requested) || dutyTypes[0];
    const { year, month } = parseMonth(req.query.month);
    const unitId = null;

    // Область видимости решает, какие сутки считать своими: командир видит
    // красным только те, за которые закреплено его подразделение.
    const scopeIds = await org.scopeIds(req.user);
    const schedule = await service.getMonthSchedule(dutyType.id, year, month, unitId, scopeIds);

    // Открытие месяца НИЧЕГО не назначает: подбор запускается только кнопкой
    // «Назначить автоматически» (решение 122). Иначе простой просмотр графика
    // менял данные, и пролистать месяцы вперед значило заполнить их составом.
    let filled = null;

    // Итог подбора по кнопке приходит в адресе: после сохранения график
    // открывается заново (иначе обновление страницы повторило бы подбор).
    if (req.query.filled !== undefined) {
      filled = {
        filled: Number(req.query.filled) || 0,
        blocks: Number(req.query.blocks) || 0,
        left: Number(req.query.left) || 0,
        manual: true,
      };
    }

    res.render('duty-calendar', {
      title: `График нарядов — ${dutyType.code}`,
      canAutofill: access.can(req.user, 'duty.create'),
      dutyTypes,
      units,
      unitId,
      current: dutyType,
      monthKey: `${year}-${String(month).padStart(2, '0')}`,
      prevMonth: shiftMonth(year, month, -1),
      nextMonth: shiftMonth(year, month, 1),
      thisMonth: shiftMonth(new Date().getFullYear(), new Date().getMonth() + 1, 0),
      scoped: Boolean(req.user.scope_unit_id),
      filled,
      ...schedule,
    });
  } catch (err) {
    next(err);
  }
});

// Подбор по кнопке. Делает то же, что подбор при открытии месяца, но по
// требованию: после снятия людей с наряда, ввода отсутствий или когда за одно
// открытие обработаны не все приказы. Назначенных и утвержденные приказы он не
// трогает — только добирает незамещенные места впереди.
// «Назначить автоматически» на странице назначения — только ее сутки.
router.post('/duties/plan/autofill', async (req, res, next) => {
  try {
    if (!access.require(req, res, 'duty.create')) return;
    const dutyTypeId = v.id(req.body.type);
    const date = String(req.body.date || '');
    const filled = await service.autoFillPlan(dutyTypeId, date, req.user.id);
    res.redirect(`/duties/plan?type=${dutyTypeId}&date=${date}&filled=${filled}`);
  } catch (err) {
    if (!err.userMessage) return next(err);
    res.status(err.status || 400).render('error', { title: 'Ошибка', message: err.message });
  }
});

router.post('/duties/autofill', async (req, res, next) => {
  try {
    if (!access.require(req, res, 'duty.create')) return;

    const dutyTypeId = v.id(req.body.type);
    const { year, month } = parseMonth(req.body.month);

    const result = await service.autoFill(dutyTypeId, year, month, req.user.id);
    const monthKey = `${year}-${String(month).padStart(2, '0')}`;

    res.redirect(`/duties?type=${dutyTypeId}&month=${monthKey}`
      + `&filled=${result.filled}&blocks=${result.blocks}&left=${result.left}`);
  } catch (err) {
    if (!err.userMessage) return next(err);
    res.status(err.status || 400).render('error', { title: 'Ошибка', message: err.message });
  }
});

// Отдельного перечня нарядов списком нет: наряды смотрят и правят в графике,
// где видно и положенные сутки, и состояние каждых. Плоский список повторял
// те же записи, ничего к ним не добавляя.

// Состав по постам. Запрашивается формой при выборе вида наряда и даты.
router.get('/duties/candidates', async (req, res, next) => {
  try {
    if (!access.require(req, res, 'duty.create')) return;
    const dutyTypeId = Number(req.query.dutyTypeId);
    const date = String(req.query.date || '');

    if (!Number.isInteger(dutyTypeId) || !isDate(date)) {
      return res.status(400).send('<p class="warn">Не указан вид наряда или дата.</p>');
    }

    const result = await service.findCandidatesByPost(dutyTypeId, date);
    res.render('partials/candidates', result);
  } catch (err) {
    next(err);
  }
});

// Отдельной страницы создания наряда нет: наряд заводится из графика, где
// сразу видны положенные сутки, приказной блок и уже назначенный состав.
// Форма «на пустом месте» требовала вводить то, что график знает сам, и
// позволяла создать наряд в сутки, когда он не положен.

// ----------------------------------------------------------------------------
// Приказной блок: назначение и утверждение сразу на все сутки одного приказа
// ----------------------------------------------------------------------------

/**
 * Назначение на приказной блок.
 *
 * Открывается по щелчку на любых сутках графика и показывает ВЕСЬ блок, на
 * который выпускается один приказ: суббота, воскресенье и понедельник — три
 * раздела одной страницы. Страница прокручивается к выбранным суткам.
 */
router.get('/duties/plan', async (req, res, next) => {
  try {
    if (!access.require(req, res, 'duty.create')) return;
    const dutyTypeId = Number(req.query.type);
    const date = String(req.query.date || '');
    const unitId = null;

    if (!Number.isInteger(dutyTypeId) || !isDate(date)) {
      return res.status(400).render('error', {
        title: 'Ошибка', message: 'Не указан вид наряда или дата.',
      });
    }

    const units = await service.listUnits();
    const plan = await service.getBlockPlan(
      dutyTypeId, date, unitId || (units.find((u) => u.parent_id === null) || units[0]).id,
    );

    if (!plan) {
      return res.status(404).render('error', {
        title: 'Не найдено', message: 'На эту дату наряд этого вида не положен.',
      });
    }

    // Подразделения нужны точечному закреплению поста на сутки — в строке
    // каждого поста. Закрепления всего наряда нет (решение 121).
    const scopeUnits = await org.listUnits(req.user);

    res.render('duty-plan', {
      title: `Назначение наряда — ${plan.dutyType.code}`,
      responsibleUnits: scopeUnits,
      canAssignResponsibility: access.can(req.user, 'duty.responsibility'),
      units,
      unitId: unitId || (units.find((u) => u.parent_id === null) || units[0]).id,
      focusDate: date,
      // Итог «Назначить автоматически»: сколько мест занято.
      autoFilled: req.query.filled !== undefined ? Number(req.query.filled) || 0 : null,
      ...plan,
    });
  } catch (err) {
    next(err);
  }
});

/**
 * Поля формы приходят в виде post_<дата>_<пост>. Дата в имени нужна потому,
 * что на странице несколько суток, и один и тот же пост встречается в каждых.
 */
function parseBlockAssignments(body, prefix = 'post') {
  const byDate = new Map();
  const pattern = new RegExp(`^${prefix}_(\\d{4}-\\d{2}-\\d{2})_(\\d+)$`);

  for (const [key, value] of Object.entries(body)) {
    const match = pattern.exec(key);
    if (!match) continue;

    const employeeId = value ? Number(value) : null;
    if (employeeId !== null && !Number.isInteger(employeeId)) continue;

    if (!byDate.has(match[1])) byDate.set(match[1], new Map());
    byDate.get(match[1]).set(Number(match[2]), employeeId);
  }

  return byDate;
}

router.post('/duties/plan', async (req, res, next) => {
  try {
    if (!access.require(req, res, 'duty.create')) return;

    const dutyTypeId = Number(req.body.dutyTypeId);
    const unitId = Number(req.body.unitId);
    const date = String(req.body.date || '');

    if (!Number.isInteger(dutyTypeId) || !Number.isInteger(unitId) || !isDate(date)) {
      return res.status(400).render('error', {
        title: 'Ошибка', message: 'Не указан вид наряда, подразделение или дата.',
      });
    }

    const { problems } = await service.saveBlock({
      dutyTypeId,
      unitId,
      date,
      byDate: parseBlockAssignments(req.body),
      // Оружие человеку без своего — полями weapon_<сутки>_<пост>.
      weapons: parseBlockAssignments(req.body, 'weapon'),
      userId: req.user && req.user.id,
    });

    if (problems.length > 0) {
      return res.status(400).render('error', {
        title: 'Состав наряда некорректен', message: problems.join(' '),
      });
    }

    // Состав сохранен — возврат в график, в тот же месяц и на ту же вкладку
    // вида наряда, откуда пришли. Оставаться на странице назначения незачем:
    // работа с этими сутками закончена, а результат виден в графике.
    res.redirect(`/duties?type=${dutyTypeId}&month=${date.slice(0, 7)}`);
  } catch (err) {
    next(err);
  }
});

/**
 * Точечное закрепление ПОСТА за подразделением на конкретные сутки.
 *
 * Сильнее очереди: им начальник службы правит отдельный день, не ломая сам
 * порядок заступления.
 */
router.post('/duties/post-responsibility', async (req, res, next) => {
  try {
    if (!access.require(req, res, 'duty.responsibility')) return;

    const postId = Number(req.body.postId);
    const onDate = String(req.body.onDate || '');
    const dutyTypeId = Number(req.body.dutyTypeId);
    const date = String(req.body.date || '');

    if (!Number.isInteger(postId) || !isDate(onDate)) {
      return res.status(400).render('error', {
        title: 'Ошибка', message: 'Не указан пост или сутки.',
      });
    }

    await service.setPostResponsibility(postId, onDate,
      req.body.unitId || null, String(req.body.note || '').trim() || null,
      req.user && req.user.id);

    res.redirect(`/duties/plan?type=${dutyTypeId}&date=${isDate(date) ? date : onDate}`);
  } catch (err) {
    if (!err.userMessage) return next(err);
    res.status(err.status || 400).render('error', { title: 'Ошибка', message: err.message });
  }
});

// Снятие поста с применения и возврат — прямо из перечня «Наряды».
router.post('/posts/:id/active', async (req, res, next) => {
  try {
    if (!access.require(req, res, 'post.manage')) return;
    const post = await service.setPostActive(req.params.id, req.body.active === 'on');
    res.redirect(`/duty-types?open=${post.duty_type_id}#type-${post.duty_type_id}`);
  } catch (err) {
    if (!err.userMessage) return next(err);
    res.status(err.status || 400).render('error', { title: 'Ошибка', message: err.message });
  }
});

// Удаление поста. Возвращает к перечню постов: удаленного поста больше нет,
// и показывать его страницу незачем.
router.post('/posts/:id/delete', async (req, res, next) => {
  try {
    if (!access.require(req, res, 'post.manage')) return;

    const removed = await service.removePost(req.params.id);
    res.redirect(`/duty-types?open=${removed.duty_type_id}#type-${removed.duty_type_id}`);
  } catch (err) {
    if (!err.userMessage) return next(err);
    res.status(err.status || 400).render('error', { title: 'Ошибка', message: err.message });
  }
});


/**
 * Утверждение приказа — отдельное окно.
 *
 * Назначение и утверждение разведены намеренно. Это разные действия разных
 * людей: состав подбирает тот, кто ведет наряды, а подписывает начальник
 * службы. Когда обе кнопки стоят рядом, «сохранить» превращается в лишний
 * шаг перед «утвердить», и подпись ставится не глядя.
 *
 * Здесь состав показан готовым списком — по фамилиям, а не выпадающими
 * списками, — и правится только точечно, кнопкой «заменить».
 */
router.get('/duties/approve', async (req, res, next) => {
  try {
    if (!access.require(req, res, 'duty.approve')) return;
    const dutyTypeId = Number(req.query.type);
    const date = String(req.query.date || '');

    if (!Number.isInteger(dutyTypeId) || !isDate(date)) {
      return res.status(400).render('error', {
        title: 'Ошибка', message: 'Не указан вид наряда или дата.',
      });
    }

    const units = await service.listUnits();
    const unitId = Number(req.query.unit)
      || (units.find((u) => u.parent_id === null) || units[0]).id;

    const plan = await service.getBlockPlan(dutyTypeId, date, unitId);

    if (!plan) {
      return res.status(404).render('error', {
        title: 'Не найдено', message: 'На эту дату наряд этого вида не положен.',
      });
    }

    res.render('duty-approve', {
      title: `Утверждение приказа — ${plan.dutyType.code}`,
      units,
      unitId,
      focusDate: date,
      ...plan,
    });
  } catch (err) {
    next(err);
  }
});

// Утверждение — над приказом целиком: подписывается документ, а не отдельные
// сутки внутри него. Неполный состав не утверждается (раздел 8.9.5).
router.post('/duties/plan/approve', async (req, res, next) => {
  try {
    if (!access.require(req, res, 'duty.approve')) return;

    const dutyTypeId = Number(req.body.dutyTypeId);
    const unitId = Number(req.body.unitId) || null;
    const date = String(req.body.date || '');

    if (!Number.isInteger(dutyTypeId) || !isDate(date)) {
      return res.status(400).render('error', { title: 'Ошибка', message: 'Не указан приказ.' });
    }

    const { problems } = await service.approveBlock(
      dutyTypeId, date, unitId, req.user && req.user.id,
    );

    if (problems.length > 0) {
      return res.status(400).render('error', {
        title: 'Приказ не утвержден',
        message: `Утвердить можно только полностью замещенный состав. ${problems.join(' ')}`,
      });
    }

    res.redirect(`/duties/approve?type=${dutyTypeId}&date=${date}${unitId ? `&unit=${unitId}` : ''}`);
  } catch (err) {
    next(err);
  }
});

/**
 * Правка состава существующего наряда.
 *
 * Отдельное окно нужно потому, что пост, освободившийся после снятия
 * человека, замещать иначе нечем: карточка наряда показывает только уже
 * назначенных, а форма создания к существующему наряду не относится.
 */
router.get('/duties/:id/edit', async (req, res, next) => {
  try {
    if (!access.require(req, res, 'duty.create')) return;
    const result = await service.getDutyForEdit(Number(req.params.id));

    if (!result) {
      return res.status(404).render('error', { title: 'Не найдено', message: 'Наряд не найден.' });
    }

    res.render('duty-edit', { title: `Состав наряда № ${result.duty.id}`, ...result });
  } catch (err) {
    next(err);
  }
});

router.post('/duties/:id/edit', async (req, res, next) => {
  try {
    if (!access.require(req, res, 'duty.create')) return;

    const dutyId = Number(req.params.id);

    // Пустое значение означает «пост не замещен»: пост, оставленный пустым
    // осознанно, должен отличаться от поста, которого в форме не было.
    // Выход посменного поста приходит полем shift_<пост>_<сутки>.
    const slots = [];
    for (const [key, value] of Object.entries(req.body)) {
      const match = /^post_(\d+)$/.exec(key)
        || /^shift_(\d+)_(\d{4}-\d{2}-\d{2})$/.exec(key);
      if (!match) continue;

      const employeeId = value ? Number(value) : null;
      if (employeeId !== null && !Number.isInteger(employeeId)) continue;

      slots.push({ postId: Number(match[1]), onDate: match[2] || null, employeeId });
    }

    const { problems } = await service.updateAssignments(
      dutyId, slots, req.user && req.user.id,
    );

    if (problems.length > 0) {
      return res.status(400).render('error', {
        title: 'Состав наряда некорректен', message: problems.join(' '),
      });
    }

    res.redirect(`/duties/${dutyId}`);
  } catch (err) {
    next(err);
  }
});

/**
 * Замена человека на посту при утверждении приказа.
 *
 * Причина обязательна: замена — это отступление от подбора, и без пояснения
 * через месяц нельзя понять, почему в приказе оказался не тот, кого выбрала
 * система. Утверждение при замене снимается со всего блока автоматически —
 * подписанный состав и фактический должны совпадать.
 */
router.post('/duties/:id/replace', async (req, res, next) => {
  try {
    if (!access.require(req, res, 'duty.create')) return;

    const dutyId = Number(req.params.id);
    const postId = Number(req.body.postId);
    const employeeId = Number(req.body.employeeId);
    const note = String(req.body.note || '').trim();
    const back = String(req.body.back || `/duties/${dutyId}`);

    if (!Number.isInteger(dutyId) || !Number.isInteger(postId)) {
      return res.status(400).render('error', { title: 'Ошибка', message: 'Не указан пост.' });
    }

    // Пустой пост отсюда не оставляют: примечание хранится при назначении и
    // вместе с ним пропало бы. Снятие человека совсем — отдельное действие,
    // со ссылкой на приказ-основание.
    if (!Number.isInteger(employeeId)) {
      return res.status(400).render('error', {
        title: 'Ошибка',
        message: 'Не выбран тот, кто заступает вместо снятого. '
          + 'Чтобы снять человека и никем не заменять, воспользуйтесь снятием с наряда '
          + 'на карточке наряда — оно требует приказ-основание.',
      });
    }

    if (!note) {
      return res.status(400).render('error', {
        title: 'Ошибка',
        message: 'Не указана причина замены. Отступление от подбора вносится только с пояснением.',
      });
    }

    const onDate = String(req.body.onDate || '') || null;
    if (onDate && !isDate(onDate)) {
      return res.status(400).render('error', { title: 'Ошибка', message: 'Неверные сутки выхода.' });
    }

    const { problems } = await service.replaceMember({
      dutyId, postId, employeeId, note, onDate,
      userId: req.user && req.user.id, override:req.body.override === 'on',
    });

    if (problems.length > 0) {
      return res.status(400).render('error', {
        title: 'Замена не выполнена', message: problems.join(' '),
      });
    }

    // Возврат на ту же страницу: замена делается подряд по нескольким постам.
    res.redirect(/^\/duties(?:[/?]|$)/.test(back) && !back.includes('\\') ? back : `/duties/${dutyId}`);
  } catch (err) {
    next(err);
  }
});

/**
 * Снятие человека с наряда: привлечен к работам, которых в системе нет.
 *
 * Даты по умолчанию — сутки заступления наряда. Приказ-основание обязателен:
 * без него запись невозможно ни проверить, ни оспорить.
 */
router.post('/duties/:id/withdraw', async (req, res, next) => {
  try {
    if (!access.require(req, res, 'duty.withdraw')) return;

    const dutyId = Number(req.params.id);
    const employeeId = Number(req.body.employeeId);
    const dateFrom = String(req.body.dateFrom || '');
    const dateTo = String(req.body.dateTo || '');
    const documentRef = String(req.body.documentRef || '').trim();

    if (!Number.isInteger(employeeId) || !isDate(dateFrom) || !isDate(dateTo)) {
      return res.status(400).render('error', {
        title: 'Ошибка', message: 'Не указан сотрудник или период.',
      });
    }

    if (dateTo < dateFrom) {
      return res.status(400).render('error', {
        title: 'Ошибка', message: 'Дата окончания раньше даты начала.',
      });
    }

    if (!documentRef) {
      return res.status(400).render('error', {
        title: 'Ошибка',
        message: 'Не указан приказ-основание. Снятие с наряда вносится только со ссылкой на документ.',
      });
    }

    await service.withdrawEmployee({
      employeeId,
      dateFrom,
      dateTo,
      documentRef,
      note: String(req.body.note || '').trim(),
      userId: req.user && req.user.id,
    });

    res.redirect(`/duties/${dutyId}`);
  } catch (err) {
    next(err);
  }
});

router.get('/duties/:id', async (req, res, next) => {
  try {
    if (!access.require(req, res, 'duty.view')) return;

    // Не число — значит такого наряда нет: адрес вида /duties/<что-то> должен
    // отвечать «не найдено», а не «данные некорректны».
    const id = Number(req.params.id);
    const result = Number.isInteger(id) ? await service.getDutyWithMembers(id) : null;

    if (!result) {
      return res.status(404).render('error', { title: 'Не найдено', message: 'Наряд не найден.' });
    }

    res.render('duty-view', {
      title: `Наряд № ${result.duty.id}`,
      duty: result.duty,
      roster: result.roster,
      employees:await personnel.listEmployees(),
      posts:await service.listPosts(result.duty.duty_type_id),
      brokenCount:result.brokenCount || 0,
      // Незамещенные посты в составе не значатся, поэтому их число берется
      // из справочника: иначе пробел в наряде на карточке не виден.
      postCount: result.postCount,
      // Сутки заступления — значение по умолчанию для периода снятия
      dutyDay: cal.dayKey(result.duty.starts_at),
    });
  } catch (err) {
    next(err);
  }
});

// ----------------------------------------------------------------------------
// Справочник постов
// ----------------------------------------------------------------------------

// Отдельной вкладки постов нет: они открываются внутри своего вида наряда.
router.get('/posts', (req, res) => res.redirect('/duty-types'));

/**
 * Справочники формы поста. Люди — из всей части: очередь правится в той же
 * форме, и перечень заранее по ней не сужается; что человек не из
 * заступающего подразделения, проверяет сохранение.
 */
async function postFormData(req, post) {
  const [dutyTypes, units, permitTypes, employees, queue, boundIds] = await Promise.all([
    service.listDutyTypes(),
    org.listUnits(req.user),
    service.listPermitTypes(),
    personnel.listEmployees(),
    post ? service.postQueue(post.id) : [],
    post ? service.postEmployees(post.id) : [],
  ]);
  return {
    dutyTypes,
    units,
    permitTypes,
    employees,
    queueIds: queue.map((row) => row.unit_id),
    boundIds,
  };
}

// Порядок видов нарядов и постов — перетаскиванием во вкладке «Наряды».
// Маршрут видов стоит раньше '/duty-types/:id', иначе «order» принялся бы за номер.
router.post('/duty-types/order', sortable.orderHandler(access, 'dutytype.manage',
  (req, ids) => service.reorderDutyTypes(ids)));
router.post('/duty-types/:id/posts/order', sortable.orderHandler(access, 'post.manage',
  (req, ids) => service.reorderPosts(req.params.id, ids)));

router.get('/posts/new', async (req, res, next) => {
  try {
    if (!access.require(req, res, 'post.manage')) return;
    res.render('post-edit', {
      title: 'Новый пост',
      post: null,
      // Пост заводится кнопкой «+» у своего вида наряда — вид уже выбран.
      presetTypeId: Number(req.query.type) || null,
      ...await postFormData(req, null),
    });
  } catch (err) {
    next(err);
  }
});

router.post('/posts', async (req, res, next) => {
  try {
    if (!access.require(req, res, 'post.manage')) return;

    const name = String(req.body.name || '').trim();
    if (!name) {
      return res.status(400).render('error', { title: 'Ошибка', message: 'Не указано наименование поста.' });
    }

    const createdType = Number(req.body.dutyTypeId);
    await db.transaction(async () => {
      const postId = await service.createPost({
        dutyTypeId: Number(req.body.dutyTypeId),
        unitId: req.body.unitId ? Number(req.body.unitId) : null,
        shortName: String(req.body.shortName || '').trim(),
        name,
        requiredPermitTypeId:req.body.requiredPermitTypeId ? v.id(req.body.requiredPermitTypeId):null,
        requiredWeaponKind:req.body.requiredWeaponKind || null,
        allowConsecutive: req.body.allowConsecutive === 'yes' ? true
          : (req.body.allowConsecutive === 'no' ? false : null),
      });
      await service.savePostStaffing(postId, staffingForm(req.body), req.user.id);
    });

    res.redirect(`/duty-types?open=${createdType}#type-${createdType}`);
  } catch (err) {
    next(err);
  }
});

router.get('/posts/:id/edit', async (req, res, next) => {
  try {
    if (!access.require(req, res, 'post.manage')) return;
    const post = await service.getPost(Number(req.params.id));
    if (!post) {
      return res.status(404).render('error', { title: 'Не найдено', message: 'Пост не найден.' });
    }

    res.render('post-edit', {
      title: `Пост: ${post.name}`,
      post,
      usage: await service.postUsage(post.id),
      ...await postFormData(req, post),
    });
  } catch (err) {
    next(err);
  }
});

router.post('/posts/:id', async (req, res, next) => {
  try {
    if (!access.require(req, res, 'post.manage')) return;

    const name = String(req.body.name || '').trim();
    if (!name) {
      return res.status(400).render('error', { title: 'Ошибка', message: 'Не указано наименование поста.' });
    }

    const updatedId = Number(req.params.id);
    await db.transaction(async () => {
      await service.updatePost(Number(req.params.id), {
        dutyTypeId: req.body.dutyTypeId ? v.id(req.body.dutyTypeId) : null,
        shortName: String(req.body.shortName || '').trim(),
        name,
        requiredPermitTypeId:req.body.requiredPermitTypeId ? v.id(req.body.requiredPermitTypeId):null,
        requiredWeaponKind:req.body.requiredWeaponKind || null,
        allowConsecutive: req.body.allowConsecutive === 'yes' ? true
          : (req.body.allowConsecutive === 'no' ? false : null),
        isActive: req.body.isActive === 'on',
      });
      await service.savePostStaffing(updatedId, staffingForm(req.body), req.user.id);
    });

    const saved = await service.getPost(updatedId);
    res.redirect(`/duty-types?open=${saved.duty_type_id}#type-${saved.duty_type_id}`);
  } catch (err) {
    next(err);
  }
});

// ----------------------------------------------------------------------------
// Справочник видов нарядов
//
// Вид наряда задает правила всего графика: часы, длительность, отдых, вес и
// обязательные допуски. Правится целиком — включая три вида, заведенных
// начальным наполнением.
// ----------------------------------------------------------------------------

/** Настройки вида наряда из формы. */
function dutyTypeForm(body) {
  const weekdays = Array.isArray(body.startWeekday) ? body.startWeekday : [body.startWeekday];
  const ends = Array.isArray(body.endWeekday) ? body.endWeekday : [body.endWeekday];
  const permits = Array.isArray(body.permitTypeIds) ? body.permitTypeIds
    : [body.permitTypeIds].filter(Boolean);

  return {
    code: body.code,
    name: body.name,
    kind: body.kind,
    startTime: body.startTime,
    durationHours: body.durationHours,
    sleepDays: body.sleepDays,
    offDays: body.offDays,
    excludeWeekends: body.excludeWeekends === 'on',
    baseWeight: body.baseWeight,
    allowConsecutive: body.allowConsecutive === 'on',
    holidayRule: body.holidayRule,
    isActive: body.isActive === 'on',
    permitTypeIds: permits.filter(Boolean),
    // У смены строка расписания — пара «заступает — сдает»; у ежедневного
    // наряда это просто отмеченные дни недели, и день сдачи не приходит.
    schedules: body.kind === 'multiday'
      ? weekdays.map((startWeekday, i) => ({ startWeekday, endWeekday: ends[i] }))
        .filter((x) => x.startWeekday && x.endWeekday)
      : weekdays.filter(Boolean).map((startWeekday) => ({ startWeekday })),
  };
}

// Вкладка «Наряды»: виды нарядов, и у каждого — раскрывающийся перечень его
// постов. Посты отдельной вкладкой не живут: пост существует только внутри
// вида наряда, и искать его в общем списке всех постов — лишний шаг.
router.get('/duty-types', async (req, res, next) => {
  try {
    const canTypes = access.can(req.user, 'dutytype.manage');
    const canPosts = access.can(req.user, 'post.manage');
    if (!canTypes && !canPosts) {
      return res.status(403).render('error', { title: 'Нет доступа', message: 'Недостаточно прав.' });
    }

    const [types, posts, postUnits, counts] = await Promise.all([
      service.listAllDutyTypes(), service.listAllPosts(),
      service.listPostUnits(null), service.postAssignmentCounts(),
    ]);

    const queue = new Map();
    for (const row of postUnits) {
      if (!queue.has(row.post_id)) queue.set(row.post_id, []);
      queue.get(row.post_id).push(row);
    }
    const used = new Map(counts.map((c) => [c.post_id, c.n]));

    // Отключенные посты — внизу своего вида: работают с действующими, а
    // снятые нужны лишь изредка, чтобы вернуть.
    const byType = new Map(types.map((t) => [t.id, []]));
    for (const post of posts) {
      if (!byType.has(post.duty_type_id)) continue;
      byType.get(post.duty_type_id).push({
        ...post,
        queue: queue.get(post.id) || [],
        assignments: used.get(post.id) || 0,
      });
    }
    for (const list of byType.values()) {
      list.sort((a, b) => (b.is_active - a.is_active) || (a.sort_order - b.sort_order)
        || a.name.localeCompare(b.name, 'ru'));
    }

    res.render('duty-type-list', {
      title: 'Наряды',
      types: types.map((t) => ({ ...t, postList: byType.get(t.id) || [] })),
      canTypes,
      canPosts,
      open: Number(req.query.open) || null,
    });
  } catch (err) {
    next(err);
  }
});

router.get('/duty-types/new', async (req, res, next) => {
  try {
    if (!access.require(req, res, 'dutytype.manage')) return;
    res.render('duty-type-edit', {
      title: 'Новый вид наряда',
      type: null,
      schedules: [],
      permits: [],
      usage: { posts: 0, duties: 0 },
      allPermitTypes: await personnel.listPermitTypes(),
    });
  } catch (err) {
    next(err);
  }
});

// ----------------------------------------------------------------------------
// Шаблон приказа вида наряда
//
// Контролируемый: меняется только правом ведения видов нарядов, каждое
// изменение — новая версия с основанием и автором; прежнюю можно вернуть.
// ----------------------------------------------------------------------------

router.get('/duty-types/:id/order', async (req, res, next) => {
  try {
    if (!access.require(req, res, 'dutytype.manage')) return;
    const data = await service.getOrderTemplate(req.params.id);
    if (!data) {
      return res.status(404).render('error', { title: 'Не найдено', message: 'Вид наряда не найден.' });
    }
    res.render('duty-order-template', {
      title: `Приказ: ${data.type.code}`, ...data, options: service.orderTemplateOptions,
      posts: await service.listPosts(data.type.id),
    });
  } catch (err) {
    next(err);
  }
});

router.post('/duty-types/:id/order', async (req, res, next) => {
  try {
    if (!access.require(req, res, 'dutytype.manage')) return;
    await service.saveOrderTemplate(req.params.id, req.body, req.user.id, {
      reset: req.body.action === 'reset',
      restore: req.body.restore ? Number(req.body.restore) : null,
    });
    res.redirect(`/duty-types/${Number(req.params.id)}/order`);
  } catch (err) {
    if (!err.userMessage) return next(err);
    res.status(err.status || 400).render('error', { title: 'Шаблон не сохранен', message: err.message });
  }
});

// Предпросмотр: приказ по текущему шаблону на условном составе; days —
// сколько суток в приказе (выходные, праздники).
router.get('/duty-types/:id/order/preview', async (req, res, next) => {
  try {
    if (!access.require(req, res, 'dutytype.manage')) return;
    const order = await service.sampleOrder(req.params.id, req.query.days);
    if (!order) {
      return res.status(404).render('error', { title: 'Не найдено', message: 'Вид наряда не найден.' });
    }
    res.render('print/order', {
      title: `Образец приказа ${order.dutyType.code}`, ...order, doc: service.orderLayout(order),
      back: `/duty-types/${Number(req.params.id)}/order`,
    });
  } catch (err) {
    next(err);
  }
});

router.get('/duty-types/:id/edit', async (req, res, next) => {
  try {
    if (!access.require(req, res, 'dutytype.manage')) return;

    const card = await service.getDutyTypeCard(req.params.id);
    if (!card) {
      return res.status(404).render('error', { title: 'Не найдено', message: 'Вид наряда не найден.' });
    }

    res.render('duty-type-edit', { title: `Вид наряда: ${card.type.code}`, ...card });
  } catch (err) {
    next(err);
  }
});

router.post('/duty-types', async (req, res, next) => {
  try {
    if (!access.require(req, res, 'dutytype.manage')) return;
    await service.createDutyType(dutyTypeForm(req.body));
    res.redirect('/duty-types');
  } catch (err) {
    if (!err.userMessage) return next(err);
    res.status(err.status || 400).render('error', { title: 'Ошибка', message: err.message });
  }
});

router.post('/duty-types/:id', async (req, res, next) => {
  try {
    if (!access.require(req, res, 'dutytype.manage')) return;
    await service.updateDutyType(req.params.id, dutyTypeForm(req.body));
    res.redirect('/duty-types');
  } catch (err) {
    if (!err.userMessage) return next(err);
    res.status(err.status || 400).render('error', { title: 'Ошибка', message: err.message });
  }
});

router.post('/duty-types/:id/delete', async (req, res, next) => {
  try {
    if (!access.require(req, res, 'dutytype.manage')) return;
    await service.removeDutyType(req.params.id, { withData: req.body.withData === 'on' });
    res.redirect('/duty-types');
  } catch (err) {
    if (!err.userMessage) return next(err);
    res.status(err.status || 400).render('error', { title: 'Ошибка', message: err.message });
  }
});

// ----------------------------------------------------------------------------
// Настройка подбора
// ----------------------------------------------------------------------------

router.get('/settings', async (req, res, next) => {
  try {
    if (!access.require(req, res, 'queue.manage')) return;

    const [settings, posts, ranks, weights, personal, employees] = await Promise.all([
      service.listSettings(), service.listAllPosts(),
      personnel.listRanks(), service.listPostRankWeights(null),
      service.listEmployeePostWeights(null), personnel.listEmployees(),
    ]);

    const byPost = new Map();
    for (const w of weights) {
      if (!byPost.has(w.post_id)) byPost.set(w.post_id, {});
      byPost.get(w.post_id)[w.rank_id] = w.weight;
    }

    // Фамилии подставляются здесь: личные поправки лежат в схеме «Личный
    // состав», но соединения с ней в модуле «Наряды» нет, и имена берутся из
    // его публичного интерфейса.
    const nameById = new Map(employees.map((e) => [e.id, e]));
    const personalByPost = new Map();
    for (const w of personal) {
      const who = nameById.get(w.employee_id);
      if (!personalByPost.has(w.post_id)) personalByPost.set(w.post_id, []);
      personalByPost.get(w.post_id).push({
        employeeId: w.employee_id,
        name: who ? who.short_name : `№ ${w.employee_id}`,
        unit: who ? who.unit_short : '',
        weight: w.weight,
        note: w.note,
      });
    }
    for (const list of personalByPost.values()) list.sort((a, b) => b.weight - a.weight);

    res.render('settings', {
      title: 'Настройка подбора',
      settings,
      employees,
      ranks: ranks.filter((r) => r.seniority <= 80),
      posts: posts.filter((p) => p.is_active).map((p) => ({
        ...p,
        weights: byPost.get(p.id) || {},
        personal: personalByPost.get(p.id) || [],
      })),
    });
  } catch (err) {
    next(err);
  }
});

router.post('/settings', async (req, res, next) => {
  try {
    if (!access.require(req, res, 'queue.manage')) return;

    await db.transaction(async () => {
    for (const [key, value] of Object.entries(req.body)) {
      const match = /^value_(.+)$/.exec(key);
      if (!match) continue;
      await service.setSetting(match[1], value, req.user.id);
    }
    });

    res.redirect('/settings');
  } catch (err) {
    if (!err.userMessage) return next(err);
    res.status(err.status || 400).render('error', { title: 'Ошибка', message: err.message });
  }
});

router.post('/posts/:id/rank-weights', async (req, res, next) => {
  try {
    if (!access.require(req, res, 'queue.manage')) return;

    const items = [];
    for (const [key, value] of Object.entries(req.body)) {
      const match = /^rank_(\d+)$/.exec(key);
      if (!match || String(value).trim() === '') continue;
      items.push({ rankId: Number(match[1]), weight: Number(String(value).trim().replace(',', '.')) });
    }

    await service.setPostRankWeights(Number(req.params.id), items);
    res.redirect(`/settings#post-${Number(req.params.id)}`);
  } catch (err) {
    if (!err.userMessage) return next(err);
    res.status(err.status || 400).render('error', { title: 'Ошибка', message: err.message });
  }
});

// Личная поправка к посту со стороны поста: перечень исключений виден там же,
// где задано массовое правило по званиям. Та же поправка правится и в карточке
// человека — это одна и та же запись, показанная с двух сторон.
router.post('/posts/:id/personal-weight', async (req, res, next) => {
  try {
    if (!access.require(req, res, 'queue.manage')) return;

    const postId = v.id(req.params.id);
    await service.setEmployeePostWeight({
      employeeId: req.body.employeeId,
      postId,
      weight: req.body.remove ? '' : req.body.weight,
      note: req.body.note,
      userId: req.user.id,
    });

    res.redirect(`/settings#post-${postId}`);
  } catch (err) {
    if (!err.userMessage) return next(err);
    res.status(err.status || 400).render('error', { title: 'Ошибка', message: err.message });
  }
});

// ----------------------------------------------------------------------------
// Справочник празднично-выходных дней
//
// Ведется вручную: состав нерабочих дней меняется год от года, а переносы
// объявляются отдельным постановлением и предугаданы быть не могут.
// ----------------------------------------------------------------------------

router.get('/calendar', async (req, res, next) => {
  try {
    if (!access.require(req, res, 'calendar.manage')) return;
    const year = Number(req.query.year) || new Date().getFullYear();
    const ranges = await service.listCalendarRanges(`${year}-01-01`, `${year}-12-31`);

    res.render('calendar-days', {
      title: 'Празднично-выходные дни',
      year,
      ranges,
      totalDays: ranges.reduce((sum, r) => sum + r.days, 0),
    });
  } catch (err) {
    next(err);
  }
});

// Нерабочие дни объявляются периодом: каникулы и майские — это несколько
// суток одним основанием, вводить их по одной дате незачем.
router.post('/calendar', async (req, res, next) => {
  try {
    if (!access.require(req, res, 'calendar.manage')) return;

    const dateFrom = String(req.body.dateFrom || '');
    // Один день — частный случай периода: поле «по» можно не заполнять.
    const dateTo = String(req.body.dateTo || '') || dateFrom;
    const kind = String(req.body.kind || '');

    if (!isDate(dateFrom) || !isDate(dateTo) || !['holiday', 'workday'].includes(kind)) {
      return res.status(400).render('error', {
        title: 'Ошибка', message: 'Не указан период или вид дня.',
      });
    }

    if (dateTo < dateFrom) {
      return res.status(400).render('error', {
        title: 'Ошибка', message: 'Дата окончания раньше даты начала.',
      });
    }

    await service.setCalendarRange(dateFrom, dateTo, kind, String(req.body.name || '').trim(),req.user?.id);
    res.redirect(`/calendar?year=${dateFrom.slice(0, 4)}`);
  } catch (err) {
    if (err.userMessage) {
      return res.status(400).render('error', { title: 'Ошибка', message: err.message });
    }
    next(err);
  }
});

router.post('/calendar/delete', async (req, res, next) => {
  try {
    if (!access.require(req, res, 'calendar.manage')) return;

    const dateFrom = String(req.body.dateFrom || '');
    const dateTo = String(req.body.dateTo || '');

    if (!isDate(dateFrom) || !isDate(dateTo)) {
      return res.status(400).render('error', { title: 'Ошибка', message: 'Некорректный период.' });
    }

    await service.deleteCalendarRange(dateFrom, dateTo,req.user?.id);
    res.redirect(`/calendar?year=${dateFrom.slice(0, 4)}`);
  } catch (err) {
    next(err);
  }
});

module.exports = router;
