'use strict';

// Строевая записка — расчет без обращений к базе.
//
// Форма взята из приложения № 10 к Уставу внутренней службы ВС РФ
// («Развернутая строевая записка»). Лицевая сторона — таблица по
// подразделениям с графами: по штату, по списку, налицо, наряд,
// командировка, отпуск, увольнение, прочее. Оборотная сторона — поименный
// перечень отсутствующих с причиной и временем отсутствия.
//
// Считается здесь, а не запросом: причина у человека ОДНА, и выбирается она
// по старшинству оснований, а не складывается. Правило старшинства — раздел
// 9.2 ТЗ:
//
//     приказ об убытии  >  наряд  >  отсыпной
//
// Уехавшего в командировку в наряд не ставят, и если такая запись все же
// есть, показать нужно расхождение, а не спрятать его. Отсыпной же есть
// следствие наряда и уступает ему.

// Графы лицевой стороны в порядке бланка. Категории справочника отсутствий
// разложены по ним: своей графы у больничного в форме нет, и он вместе с
// привлечением по отдельному приказу попадает в «прочее».
const COLUMNS = [
  { key: 'duty', name: 'Наряд' },
  { key: 'trip', name: 'Командировка' },
  { key: 'vacation', name: 'Отпуск' },
  { key: 'leave', name: 'Увольнение' },
  { key: 'other', name: 'Прочее' },
];

const BY_ABSENCE_CODE = {
  VACATION: 'vacation',
  TRIP: 'trip',
  DAY_OFF: 'leave',
  SICK: 'other',
  OTHER: 'other',
};

/** Пустой набор граф. */
function zeroes() {
  const out = { listed: 0, present: 0, sick: 0, resting: 0 };
  for (const column of COLUMNS) out[column.key] = 0;
  return out;
}

function add(target, source) {
  for (const key of Object.keys(target)) target[key] += source[key];
  return target;
}

/**
 * Состояние одного человека на дату.
 *
 * @returns {{column:?string, reason:string, from:?string, to:?string}}
 *          column — графа записки; null — налицо
 */
function stateOf(employee, absence, onDuty, resting) {
  if (absence) {
    return {
      column: BY_ABSENCE_CODE[absence.code] || 'other',
      code: absence.code,
      reason: absence.reason,
      from: absence.date_from,
      to: absence.date_to,
      conflict: Boolean(onDuty),
    };
  }

  // Графа «Наряд» — только заступившие: отсыпной службы уже не несет, и в
  // наряде его нет. Своей графы отдыху бланк не дает, поэтому он идет в
  // «Прочее» вместе с больными. Число отдыхающих считается отдельно и
  // выводится подстрочником: оно самое подвижное из всех.
  if (onDuty) return { column: 'duty', reason: `В наряде: ${onDuty}`, onDuty };
  if (resting) return { column: 'other', reason: `Отсыпной после наряда: ${resting}`, rest: true };

  return { column: null, reason: 'налицо' };
}

/**
 * Записка по дереву подразделений.
 *
 * @param {object[]} tree      дерево подразделений с employees в каждом узле
 * @param {Map}      absences  employee_id → запись об отсутствии на дату
 * @param {object}   dutyState {onDuty, resting, justRested} — карты из МС-2
 * @returns {{rows:object[], total:object, absent:object[], columns:object[]}}
 */
function build({ tree, absences, dutyState, onDate }) {
  const absent = [];
  const total = zeroes();
  let staffTotal = 0;
  let staffKnown = false;

  /**
   * Обход узла: свои люди плюс все вложенные подразделения.
   *
   * @param {?string} top  подразделение ПЕРВОГО уровня — та самая строка, в
   *                       которой человек посчитан. Корень сюда не входит:
   *                       записка и так подается по нему.
   */
  function walk(unit, depth, path, top) {
    const own = zeroes();
    // Путь строится без корня: «1 рота · 1 взвод · 1 отделение».
    const here = depth === 0 ? '' : `${path}${path ? ' · ' : ''}${unit.short_name}`;
    const topName = top || (depth === 0 ? unit.short_name : unit.short_name);

    for (const employee of unit.employees || []) {
      const state = stateOf(
        employee,
        absences.get(employee.id) || null,
        dutyState.onDuty.get(employee.id) || null,
        dutyState.resting.get(employee.id) || null,
      );

      own.listed += 1;
      if (!state.column) own.present += 1;
      else own[state.column] += 1;
      if (state.code === 'SICK') own.sick += 1;
      if (state.rest) own.resting += 1;

      if (state.column) {
        absent.push({
          id: employee.id,
          rank: employee.rank_name || '',
          name: employee.full_name,
          // В графе бланка — подразделение ПЕРВОГО уровня, та самая строка
          // таблицы, в которой человек посчитан: перечень и таблица должны
          // сходиться и на глаз. Полный путь с вложениями остается рядом —
          // подсказкой при наведении.
          unit: topName,
          path: here || unit.short_name,
          reason: state.reason,
          // Время отсутствия — всегда даты. У наряда и отсыпного своей записи
          // нет, они относятся к этим суткам, и сутки эти и проставляются:
          // словами («эти сутки») графа документа не заполняется.
          from: state.from || onDate,
          to: state.to || onDate,
          conflict: Boolean(state.conflict),
        });
      }
    }

    const children = (unit.children || []).map(
      (child) => walk(child, depth + 1, here, depth === 0 ? child.short_name : topName),
    );
    const sum = zeroes();
    add(sum, own);
    for (const child of children) add(sum, child.sum);

    // По штату — ДОЛЖНОСТИ подразделения вместе с вложенными (штат ведется
    // во вкладке «Подразделения»), по списку — люди. Вакантные должности —
    // разница между ними.
    const ownStaff = Array.isArray(unit.positions) ? unit.positions.length : 0;
    if (Array.isArray(unit.positions)) staffKnown = true;
    const staff = ownStaff + children.reduce((n, child) => n + child.staff, 0);

    return {
      id: unit.id,
      name: unit.short_name,
      fullName: unit.name,
      depth,
      staff,
      ownStaff,
      own,
      sum,
      children,
    };
  }

  const rows = tree.map((unit) => walk(unit, 0, '', null));
  for (const row of rows) {
    add(total, row.sum);
    if (row.staff !== null) staffTotal += row.staff;
  }

  // Перечень отсутствующих НЕ СОРТИРУЕТСЯ отдельно: он собран тем же обходом
  // дерева, что и таблица, а значит идет ровно в порядке подразделений — как
  // их завели — и внутри подразделения по старшинству. Своя сортировка
  // развела бы два перечня одного документа.

  // Строки бланка — ПОТОМКИ корня: сам корень повторял бы итоговую строку.
  // Глубже взвода не разворачиваем: отделения уже учтены в вышестоящем, а
  // записка перечисляет подразделения, не отделения. Поименно они видны в
  // списке личного состава.
  const lines = [];
  const walk2 = (list, level, parentId) => list.forEach((row) => {
    // Родитель нужен строке, чтобы на экране она пряталась под своим
    // подразделением: основные числа читаются без вложенности, а разворот
    // остается для тех, кому нужен разбор.
    lines.push({ ...row, level, parentId, hasChildren: row.children.length > 0 });
    if (level < 1) walk2(row.children, level + 1, row.id);
  });
  rows.forEach((row) => {
    // Люди, числящиеся в самом подразделении записки (управление части), идут
    // отдельной строкой со СВОИМИ числами: иначе их не было бы ни в одной
    // строке, хотя в итоге они есть, и таблица не сходилась бы на глаз.
    // Штат у такой строки — собственные должности подразделения записки.
    if (row.own.listed > 0 || row.ownStaff > 0) {
      lines.push({
        ...row, level: 0, parentId: null, hasChildren: false, sum: row.own, staff: row.ownStaff,
      });
    }
    walk2(row.children, 0, null);
  });
  if (lines.length === 0) {
    rows.forEach((row) => lines.push({ ...row, level: 0, parentId: null, hasChildren: false }));
  }

  return {
    onDate,
    columns: COLUMNS,
    rows,
    lines,
    total,
    staffTotal: staffKnown ? staffTotal : null,
    absent,
    // Итог сходится по построению: каждый человек попадает ровно в одну
    // графу. Расхождение означало бы ошибку в расчете, и показать его лучше,
    // чем промолчать.
    balanced: total.listed === COLUMNS.reduce((n, c) => n + total[c.key], total.present),
  };
}

module.exports = { build, stateOf, COLUMNS, BY_ABSENCE_CODE };
