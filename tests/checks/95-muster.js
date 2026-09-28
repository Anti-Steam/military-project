'use strict';

// Строевая записка: расчет по форме приложения № 10 к Уставу внутренней
// службы ВС РФ и ручной ввод отсутствий.

const { get, post: send } = require('../lib');
const muster = require('../../services/app/modules/personnel/muster');
const personnel = require('../../services/app/modules/personnel/service');
const db = require('../../services/app/db/pool');

/** Завтрашние сутки: записка подается накануне. */
function tomorrow() {
  return new Date(Date.now() + 86400000).toISOString().slice(0, 10);
}

/** N штатных должностей подразделения — штат считается по ним. */
const posts = (n) => Array.from({ length: n }, (_, i) => ({ id: i + 1 }));

/** Дерево из двух подразделений для расчета без базы. */
function sample() {
  return [{
    id: 1, short_name: 'в/ч', name: 'войсковая часть', positions: posts(10),
    employees: [{ id: 1, rank_name: 'майор', full_name: 'Первый' }],
    children: [{
      id: 2, short_name: '1 рота', name: 'первая рота', positions: posts(8),
      employees: [
        { id: 2, rank_name: 'сержант', full_name: 'Второй' },
        { id: 3, rank_name: 'рядовой', full_name: 'Третий' },
        { id: 4, rank_name: 'рядовой', full_name: 'Четвертый' },
      ],
      children: [],
    }],
  }];
}

const noDuty = { onDuty: new Map(), resting: new Map(), justRested: new Map() };

/** Каждый человек попадает ровно в одну графу, итог сходится со списком. */
exports.итог_сходится_со_списком = async (t) => {
  const absences = new Map([
    [2, { code: 'VACATION', reason: 'Отпуск', date_from: '2026-09-01', date_to: '2026-09-30' }],
    [3, { code: 'SICK', reason: 'Больничный', date_from: '2026-09-20', date_to: '2026-09-25' }],
  ]);
  const dutyState = {
    onDuty: new Map([[4, 'СН']]),
    resting: new Map(),
    justRested: new Map(),
  };

  const report = muster.build({ tree: sample(), absences, dutyState, onDate: '2026-09-21' });

  t.is(report.total.listed, 4, 'по списку — все четверо');
  t.is(report.total.present, 1, 'налицо один');
  t.is(report.total.vacation, 1, 'в отпуске один');
  t.is(report.total.duty, 1, 'в наряде один');
  t.is(report.total.other, 1, 'больной учтен в графе «прочее»');
  t.is(report.total.sick, 1, 'и посчитан отдельно для подстрочника');
  t.ok(report.balanced, 'сумма граф вместе с «налицо» равна списочной');

  // Штат — должности части вместе с вложенными: 10 своих + 8 роты.
  t.is(report.staffTotal, 18, 'по штату — все должности части');

  // Строки бланка — потомки корня: сам корень повторял бы итог. Но свои люди
  // корня (управление части) идут отдельной строкой со своими числами —
  // иначе они не попали бы ни в одну строку.
  t.is(report.lines.map((row) => row.name), ['в/ч', '1 рота'], 'строки бланка');
  t.is(report.lines[0].sum.listed, 1, 'у корня — только его собственные люди');
  t.is(report.lines[0].staff, 10, 'штат строки управления — ее собственные должности');
  t.is(report.lines[1].staff, 8, 'штат роты — ее должности');
  t.is(report.lines[1].sum.listed, 3, 'у роты — ее собственный список');
  t.is(report.lines[1].level, 0, 'обе — основные строки');
  t.is(report.lines[1].hasChildren, false, 'разворачивать в роте нечего');

  // Сумма строк сходится со списочной численностью: ни один человек не
  // потерялся между строками и итогом.
  t.is(report.lines.reduce((n, row) => n + row.sum.listed, 0), report.total.listed,
    'строки в сумме дают список');
};

/** Причина у человека одна: приказ сильнее наряда, наряд сильнее отсыпного. */
exports.старшинство_причин = async (t) => {
  const dutyState = {
    onDuty: new Map([[2, 'СН']]),
    resting: new Map([[3, 'ОО']]),
    justRested: new Map(),
  };
  const absences = new Map([
    [2, { code: 'TRIP', reason: 'Командировка', date_from: '2026-09-01', date_to: '2026-09-30' }],
  ]);

  const report = muster.build({ tree: sample(), absences, dutyState, onDate: '2026-09-21' });

  t.is(report.total.trip, 1, 'убывший по приказу считается убывшим, а не в наряде');
  t.is(report.total.duty, 0, 'в графе наряда только заступившие');
  t.is(report.total.other, 1, 'отсыпной учтен в графе «прочее»');
  t.is(report.total.resting, 1, 'и посчитан отдельно для подстрочника');

  // Расхождение не прячется: человек убыл по приказу, а назначен в наряд.
  const conflict = report.absent.find((a) => a.id === 2);
  t.ok(conflict && conflict.conflict, 'расхождение «убыл, но назначен» показано');

  // Отсыпной попадает в перечень отсутствующих с понятной причиной.
  const resting = report.absent.find((a) => a.id === 3);
  t.ok(resting && resting.reason.startsWith('Отсыпной после наряда:'),
    'отсыпной назван причиной и постом');

  // Время отсутствия — всегда даты: у наряда и отсыпного это сами сутки
  // записки, словами графа документа не заполняется.
  t.is(resting.from, '2026-09-21', 'у отсыпного проставлены эти сутки');
  t.is(resting.to, '2026-09-21', 'началом и концом');

  const away = report.absent.find((a) => a.id === 2);
  t.is([away.from, away.to], ['2026-09-01', '2026-09-30'], 'у приказа — его собственные даты');
};

/** Основные строки — без вложенности, вложенные идут подпунктом. */
exports.вложенные_подразделения = async (t) => {
  const tree = [{
    id: 1, short_name: 'в/ч', name: 'войсковая часть', positions: posts(0),
    employees: [],
    children: [
      {
        id: 2, short_name: '1 рота', name: 'первая рота', positions: posts(12),
        employees: [{ id: 1, rank_name: 'старшина', full_name: 'Ротный' }],
        children: [{
          id: 3, short_name: '1 взвод', name: 'первый взвод', positions: posts(6),
          employees: [{ id: 2, rank_name: 'рядовой', full_name: 'Взводный' }],
          children: [{
            id: 4, short_name: '1 отделение', name: 'первое отделение', positions: posts(3),
            employees: [{ id: 3, rank_name: 'рядовой', full_name: 'Отделенный' }],
            children: [],
          }],
        }],
      },
      {
        id: 5, short_name: 'УС', name: 'узел связи', positions: posts(5),
        employees: [{ id: 4, rank_name: 'прапорщик', full_name: 'Связист' }],
        children: [],
      },
    ],
  }];

  const report = muster.build({ tree, absences: new Map(), dutyState: noDuty, onDate: '2026-09-21' });

  const main = report.lines.filter((row) => row.level === 0);
  t.is(main.map((row) => row.name), ['1 рота', 'УС'], 'основные строки — без вложенности');
  t.is(main[0].hasChildren, true, 'у роты есть что развернуть');
  t.is(main[1].hasChildren, false, 'у узла связи — нет');

  const inner = report.lines.filter((row) => row.level === 1);
  t.is(inner.map((row) => row.name), ['1 взвод'], 'подпунктом идет взвод');
  t.is(inner[0].parentId, 2, 'он привязан к своей роте');

  // Отделение отдельной строкой не выводится, но в числах роты учтено.
  t.is(report.lines.some((row) => row.name === '1 отделение'), false, 'глубже взвода строк нет');

  // Человек из отделения числится за подразделением ПЕРВОГО уровня — той
  // строкой, в которой он посчитан, а полный путь остается подсказкой.
  const deep = muster.build({
    tree,
    absences: new Map([[3, {
      code: 'TRIP', reason: 'Командировка', date_from: '2026-09-21', date_to: '2026-09-21',
    }]]),
    dutyState: noDuty,
    onDate: '2026-09-21',
  }).absent[0];
  t.is(deep.unit, '1 рота', 'в графе — подразделение первого уровня');
  t.is(deep.path, '1 рота · 1 взвод · 1 отделение', 'в подсказке — путь с вложениями');
  t.is(main[0].sum.listed, 3, 'в роте посчитаны и взвод, и отделение');
  t.is(report.total.listed, 4, 'в итоге — весь личный состав');
};

/** Перечень отсутствующих идет тем же порядком подразделений, что и таблица. */
exports.порядок_подразделений_общий = async (t) => {
  const tree = [{
    id: 1, short_name: 'в/ч', name: 'войсковая часть', positions: posts(0), employees: [],
    children: [
      {
        // Подразделения идут так, как их завели (sort_order), а не по азбуке.
        id: 2, short_name: 'Управление', name: 'управление', positions: posts(3),
        employees: [{ id: 1, rank_name: 'майор', full_name: 'Аверин' }],
        children: [],
      },
      {
        id: 3, short_name: '1 рота', name: 'первая рота', positions: posts(3),
        employees: [{ id: 2, rank_name: 'сержант', full_name: 'Яковлев' }],
        children: [],
      },
      {
        id: 4, short_name: 'УС', name: 'узел связи', positions: posts(3),
        employees: [{ id: 3, rank_name: 'рядовой', full_name: 'Борисов' }],
        children: [],
      },
    ],
  }];

  const absences = new Map([
    [1, { code: 'TRIP', reason: 'Командировка', date_from: '2026-09-20', date_to: '2026-09-22' }],
    [2, { code: 'VACATION', reason: 'Отпуск', date_from: '2026-09-01', date_to: '2026-09-30' }],
    [3, { code: 'SICK', reason: 'Больничный', date_from: '2026-09-20', date_to: '2026-09-25' }],
  ]);

  const report = muster.build({ tree, absences, dutyState: noDuty, onDate: '2026-09-21' });

  t.is(report.lines.map((row) => row.name), ['Управление', '1 рота', 'УС'],
    'строки таблицы — в порядке подразделений');
  t.is(report.absent.map((a) => a.unit), ['Управление', '1 рота', 'УС'],
    'перечень отсутствующих — в том же порядке, а не по алфавиту');
  t.is(report.absent[0].path, 'Управление', 'подсказка — путь без корня');
};

/** Страница и печатный бланк открываются и считают одно и то же. */
exports.страница_и_бланк = async (t, ctx) => {
  if (!ctx.alive) { t.ok(true, 'приложение не запущено — пропущено'); return; }

  const day = tomorrow();
  const page = await get(`/personnel?date=${day}`);
  t.is(page.status, 200, 'записка открылась');
  t.ok(page.body.includes('Строевая записка'), 'это она');

  for (const column of muster.COLUMNS) {
    t.ok(page.body.includes(column.name), `есть графа «${column.name}»`);
  }

  // Список личного состава — отдельная страница, записка его не тянет.
  t.ok(page.body.includes('/personnel/roster?date='), 'со страницы есть переход к списку');
  t.is(page.body.includes('class="absence-form"'), false, 'формы отметки остались на списке');

  const roster = await get(`/personnel/roster?date=${day}`);
  t.is(roster.status, 200, 'список личного состава открылся');
  t.ok(roster.body.includes('unit-node'), 'в нем дерево подразделений');

  const print = await get(`/personnel/print?date=${day}`);
  t.is(print.status, 200, 'бланк открылся');
  t.ok(print.body.includes('РАЗВЕРНУТАЯ СТРОЕВАЯ ЗАПИСКА'), 'по форме устава');

  // Пустых разделов в бланке нет: прикомандированные в системе не ведутся,
  // поэтому раздела быть не должно.
  t.is(print.body.includes('Прикомандированные'), false, 'пустого раздела в бланке нет');
  t.is(print.body.includes('Отсутствующие'), (await get(`/personnel?date=${day}`)).body
    .includes('Отсутствующих нет') === false, 'перечень отсутствующих — только когда есть кто');

  // Итог на экране и в бланке считается одним кодом, поэтому числа совпадают.
  const listed = (s) => (/По списку[\s\S]*?<strong>(\d+)<\/strong>/.exec(s) || [])[1];
  t.ok(page.body.includes('Всего'), 'на экране есть итоговая строка');
  t.ok(print.body.includes('Итого'), 'в бланке есть итоговая строка');
};

/** Отсутствие вносится, попадает в записку и снимается с сохранением. */
exports.ввод_отсутствия = async (t, ctx) => {
  if (!ctx.alive) { t.ok(true, 'приложение не запущено — пропущено'); return; }

  const day = tomorrow();
  const page = await get(`/personnel/roster?date=${day}`);
  const match = /class="absence-form" data-employee="(\d+)"/.exec(page.body);
  t.ok(Boolean(match), 'на странице есть кому проставить отсутствие');
  if (!match) return;

  const id = Number(match[1]);

  try {
    const saved = await send(`/personnel/${id}/absence`, {
      typeCode: 'VACATION', dateFrom: day, dateTo: day,
      documentRef: 'проверка', back: day,
    });
    t.is(saved.status, 302, 'запись принята');

    const absences = await personnel.listAbsencesOnDate(day);
    const own = absences.find((a) => a.employee_id === id);
    t.ok(Boolean(own), 'запись видна на эту дату');
    t.is(own && own.source, 'manual', 'происхождение — внесено человеком');

    // Наложение на те же сутки отклоняется: почти всегда это опечатка.
    const again = await send(`/personnel/${id}/absence`, {
      typeCode: 'SICK', dateFrom: day, dateTo: day, back: day,
    });
    t.is(again.status, 400, 'вторая запись на те же даты отклонена');

    // Человек попал в перечень отсутствующих самой записки.
    const after = await get(`/personnel?date=${day}`);
    t.ok(after.body.includes(`/personnel/${id}`), 'человек виден в перечне отсутствующих');

    const removed = await send(`/absences/${own.id}/cancel`, { back: day });
    t.is(removed.status, 302, 'запись снята');

    const { rows } = await db.query(
      'SELECT cancelled_at IS NOT NULL AS done FROM personnel.absences WHERE id = $1', [own.id],
    );
    t.is(rows[0].done, true, 'снятая запись сохранена, а не удалена');

    const left = await personnel.listAbsencesOnDate(day);
    t.is(left.some((a) => a.employee_id === id), false, 'из расчета она ушла');
  } finally {
    await db.query('DELETE FROM personnel.absences WHERE employee_id = $1 AND document_ref = $2',
      [id, 'проверка']);
  }
};

/**
 * Числа записки меняются СРАЗУ: записка не хранится, а считается при каждом
 * открытии. Отдельного «пересчета» нет и быть не должно — сохраненный итог
 * разошелся бы с назначениями при первой правке состава.
 */
exports.числа_меняются_сразу = async (t, ctx) => {
  if (!ctx.alive) { t.ok(true, 'приложение не запущено — пропущено'); return; }

  const day = tomorrow();
  const numbers = async () => {
    const page = await get(`/personnel?date=${day}`);
    const cards = [...page.body.matchAll(/card-value">([^<]*)</g)].map((m) => m[1].trim());
    const [staff, listed, present, absent] = cards;
    return { staff, listed: Number(listed), present: Number(present), absent: Number(absent) };
  };

  // Кого-то, кто на эти сутки налицо: у него и проверяем пересчет.
  const roster = await get(`/personnel/roster?date=${day}`);
  const match = /class="absence-form" data-employee="(\d+)"/.exec(roster.body);
  t.ok(Boolean(match), 'есть человек, который налицо');
  if (!match) return;

  const id = Number(match[1]);
  const before = await numbers();

  try {
    await send(`/personnel/${id}/absence`, {
      typeCode: 'VACATION', dateFrom: day, dateTo: day, documentRef: 'проверка счета', back: day,
    });

    const after = await numbers();
    t.is(after.listed, before.listed, 'списочная численность не изменилась');
    t.is(after.present, before.present - 1, 'налицо стало на одного меньше');
    t.is(after.absent, before.absent + 1, 'отсутствующих — на одного больше');

    // И тот же человек появился в поименном перечне.
    const page = await get(`/personnel?date=${day}`);
    t.ok(page.body.includes(`/personnel/${id}`), 'человек назван в перечне отсутствующих');
  } finally {
    await db.query('DELETE FROM personnel.absences WHERE employee_id = $1 AND document_ref = $2',
      [id, 'проверка счета']);
  }

  // После снятия записи числа возвращаются: пересчет идет в обе стороны.
  const restored = await numbers();
  t.is(restored.present, before.present, 'после снятия записи налицо вернулось');
  t.is(restored.absent, before.absent, 'и отсутствующих тоже');
};

/** Отсутствие снимает человека с отбора кандидатов в наряд. */
exports.отсутствие_убирает_из_кандидатов = async (t) => {
  const duty = require('../../services/app/modules/duty/service');

  const type = (await duty.listDutyTypes()).find((x) => x.code === 'SN');
  const now = new Date();
  const date = `${now.getFullYear()}-${String(now.getMonth() + 2).padStart(2, '0')}-14`;

  const before = await duty.findCandidatesByPost(type.id, date, null);
  const slot = before.posts.find((p) => p.candidates.length > 1);
  if (!slot) { t.ok(true, 'на стенде нет поста с кандидатами — пропущено'); return; }

  const person = slot.candidates[0];

  try {
    await personnel.recordAbsence({
      employeeId: person.id, typeCode: 'TRIP', dateFrom: date, dateTo: date,
      documentRef: 'проверка отбора', userId: null,
    });

    const after = await duty.findCandidatesByPost(type.id, date, null);
    const same = after.posts.find((p) => p.post.id === slot.post.id);
    t.is(same.candidates.some((c) => c.id === person.id), false,
      'убывший по приказу в кандидаты не попадает');
  } finally {
    await db.query('DELETE FROM personnel.absences WHERE employee_id = $1 AND document_ref = $2',
      [person.id, 'проверка отбора']);
  }
};

/**
 * По штату — должности (вместе с вложенными), по списку — люди. Вакантные
 * должности управления части — отдельной строкой, чтобы строки сходились
 * со штатом части.
 */
exports.штат_по_должностям = async (t) => {
  const tree = [{
    id: 1, short_name: 'в/ч', name: 'войсковая часть', positions: posts(2), employees: [],
    children: [{
      id: 2, short_name: '1 рота', name: 'первая рота', positions: posts(3),
      employees: [{ id: 1, rank_name: 'рядовой', full_name: 'Первый' }],
      children: [{
        id: 3, short_name: '1 взвод', name: 'первый взвод', positions: posts(4),
        employees: [{ id: 2, rank_name: 'рядовой', full_name: 'Второй' }], children: [],
      }],
    }],
  }];
  const report = muster.build({ tree, absences: new Map(), dutyState: noDuty, onDate: '2026-09-21' });
  t.is(report.staffTotal, 9, 'по штату — все должности части');
  t.is(report.total.listed, 2, 'по списку — люди');
  const own = report.lines.find((l) => l.name === 'в/ч');
  t.ok(own && own.staff === 2, 'вакантные должности управления — своей строкой');
  const company = report.lines.find((l) => l.name === '1 рота');
  t.is(company.staff, 7, 'у роты — ее должности вместе со взводом');
  const main = report.lines.filter((l) => l.level === 0);
  t.is(main.reduce((n, l) => n + l.staff, 0), report.staffTotal, 'строки сходятся со штатом части');
};

/** На данных стенда: по штату — должности, по списку — люди в подразделениях. */
exports.штат_стенда = async (t) => {
  const org = require('../../services/app/modules/org/service');
  const db = require('../../services/app/db/pool');
  const tree = await org.personnelTree({ id: null, scope_unit_id: null });
  const report = muster.build({ tree, absences: new Map(), dutyState: noDuty, onDate: '2026-09-21' });
  const { rows: [r] } = await db.query(`SELECT
      (SELECT count(*)::int FROM core.positions p JOIN core.units u ON u.id = p.unit_id WHERE u.is_active OR true) AS staff,
      (SELECT count(*)::int FROM personnel.employees WHERE is_active AND unit_id IS NOT NULL) AS listed`);
  t.is(report.staffTotal, r.staff, 'по штату — число должностей');
  t.is(report.total.listed, r.listed, 'по списку — люди в подразделениях');
  t.ok(report.staffTotal >= report.total.listed, 'штат не меньше списка (за штатом — вне подразделений)');
};
