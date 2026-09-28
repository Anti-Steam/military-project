'use strict';
const cal = require('../../services/app/modules/duty/calendar');
const queue = require('../../services/app/modules/duty/queue');
const muster = require('../../services/app/modules/personnel/muster');

exports.queueBoundaries = async t => {
  const settings = queue.settingsFrom([]);
  t.is(queue.readiness(null, '2030-01-01', settings), 30, 'Новичок готов');
  t.is(queue.readiness('2029-01-01', '2030-01-01', settings), 30, 'Простой ограничен потолком');
  t.is(queue.readiness('2030-01-01', '2030-01-01', settings), 0, 'В день сдачи готовность нулевая');
  t.is(queue.readiness('2030-01-02', '2030-01-01', settings), 0, 'Будущая дата не даёт отрицательную готовность');
  const loaded = queue.queueValue({ lastDate: '2029-12-31', workload: 100 }, { rank: 0, personal: -10 }, '2030-01-01', settings);
  t.is(loaded.value, -39, 'Нагрузка и личный вес учтены');
  t.is(queue.passes(loaded, settings), true, 'Нагрузка меняет очередь, а не допуск к предложению');
};
exports.queueStableOrder = async t => {
  const people = [
    { id: 3, queue: { value: 5, readiness: 2 } },
    { id: 2, queue: { value: 5, readiness: 3 } },
    { id: 1, queue: { value: 5, readiness: 3 } },
    { id: 4, queue: { value: 6, readiness: 1 } },
  ];
  t.is(people.sort(queue.compare).map(p => p.id), [4, 1, 2, 3], 'Очередь, простой, затем ID');
  const changed = queue.settingsFrom([{ key: 'queue.ready_max_days', value: '12' }]);
  t.is(changed['queue.ready_max_days'], 12, 'Настройка прочитана');
  t.is(queue.settingsFrom([])['queue.ready_max_days'], 30, 'Настройки по умолчанию не изменены');
};
exports.scheduleExceptions = async t => {
  const type = { kind: 'daily', start_time: '10:00:00', duration_hours: 24 };
  // 7 января 2030 — понедельник; 5 января — суббота.
  const exceptions = new Map([['2030-01-07', 'holiday'], ['2030-01-05', 'workday']]);
  const dates = rule => cal.expectedDuties({ ...type, holiday_rule: rule }, [], '2030-01-05', '2030-01-07', exceptions).map(p => p.startDate);
  t.is(dates('never'), ['2030-01-05'], 'Рабочая суббота заменяет обычное правило выходных');
  t.is(dates('only'), ['2030-01-06', '2030-01-07'], 'Праздничный понедельник учитывается');
  t.is(cal.expectedDuties(type, [{ start_weekday: 1 }], '2030-01-01', '2030-01-14').map(p => p.startDate),
    ['2030-01-07', '2030-01-14'], 'Наряд только по выбранным дням недели');
};
exports.shiftOverlap = async t => {
  const slot = (employeeId, start, end, extra = {}) => ({ employeeId, postId: 1,
    startsAt: new Date(`2030-01-01T${start}:00`), endsAt: new Date(`2030-01-01T${end}:00`), sleepDays: 0, ...extra });
  t.is(cal.findSlotConflicts([slot(1, '08:00', '12:00'), slot(1, '12:00', '16:00')]).length, 0, 'Соседние смены не пересекаются');
  const overlaps = cal.findSlotConflicts([slot(1, '08:00', '12:00'), slot(1, '11:59', '16:00', { allowRepeat: true })]);
  t.is(overlaps.length, 1, 'Даже минутное пересечение запрещено');
  t.is(overlaps[0].reason, 'overlap', 'Разрешение повторного наряда не снимает пересечение');
  t.is(cal.findSlotConflicts([slot(1, '08:00', '12:00'), slot(2, '08:00', '12:00'), slot(null, '08:00', '12:00')]).length, 0, 'Разные люди и незаполненные места не конфликтуют');
};
exports.musterPriority = async t => {
  const absence = { code: 'VACATION', reason: 'Отпуск', date_from: '2030-01-01', date_to: '2030-01-10' };
  const result = muster.stateOf({}, absence, 'Пост', 'Пост');
  t.is(result.column, 'vacation', 'Приказ об отсутствии имеет приоритет');
  t.is(result.conflict, true, 'Противоречие с нарядом видно');
  t.is(muster.stateOf({}, null, 'Пост', 'Пост').column, 'duty', 'Наряд приоритетнее отдыха');
  t.is(muster.stateOf({}, null, null, 'Пост').rest, true, 'Отсыпной отмечен отдельно');
};
exports.musterTotals = async t => {
  const result = muster.build({ onDate: '2030-01-01',
    tree: [{ id: 1, short_name: 'Часть', staff_count: 10, employees: [{ id: 1 }], children: [
      { id: 2, short_name: 'Рота', employees: [{ id: 2 }, { id: 3 }, { id: 4 }], children: [] },
    ] }], absences: new Map([[2, { code: 'SICK', reason: 'Болен' }]]),
    dutyState: { onDuty: new Map([[3, 'Пост']]), resting: new Map([[4, 'Пост']]) },
  });
  t.is(result.total.listed, 4, 'Люди корня и потомков посчитаны один раз');
  t.is(result.total.present, 1, 'Один человек налицо');
  t.is(result.total.duty, 1, 'Один в наряде');
  t.is(result.total.other, 2, 'Больной и отдыхающий в прочих');
  t.is(result.total.sick, 1, 'Больной учитывается отдельно');
  t.is(result.total.resting, 1, 'Отдыхающий учитывается отдельно');
  t.is(result.absent.map(p => p.id), [2, 3, 4], 'Поимённый список согласован с итогами');
};
