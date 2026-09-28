'use strict';

// Правила отбора кандидатов, относящиеся к нарядам.
//
// Функции здесь намеренно чистые: принимают данные, возвращают результат,
// в БД не обращаются. Это правила из раздела 8 ТЗ в исполняемом виде.

const MS_IN_HOUR = 60 * 60 * 1000;
const MS_IN_DAY = 24 * MS_IN_HOUR;

/** День недели по ISO: 1 — понедельник … 7 — воскресенье. */
function isoWeekday(date) {
  const day = date.getDay();
  return day === 0 ? 7 : day;
}

/**
 * Период заступления и сдачи.
 *
 * Суточный наряд: от времени заступления плюс длительность.
 * Многодневная смена (ОО): длительность определяется расписанием — например,
 * пятница→вторник. Если подходящего варианта расписания нет, возвращается
 * признак noSchedule, чтобы интерфейс мог предупредить пользователя.
 *
 * @param {object} dutyType   запись duty.duty_types
 * @param {Array}  schedules  записи duty.duty_type_schedules
 * @param {string} startDate  дата заступления, YYYY-MM-DD
 */
function computePeriod(dutyType, schedules, startDate) {
  require('../../lib/validation').date(startDate);
  const time = dutyType.start_time || '00:00:00';
  const startsAt = new Date(`${startDate}T${time}`);

  if (Number.isNaN(startsAt.getTime())) {
    throw new Error(`Некорректная дата заступления: ${startDate}`);
  }

  if (dutyType.kind !== 'multiday') {
    const hours = dutyType.duration_hours || 24;
    return { startsAt, endsAt: new Date(startsAt.getTime() + hours * MS_IN_HOUR), noSchedule: false };
  }

  const weekday = isoWeekday(startsAt);
  const schedule = schedules.find((s) => s.start_weekday === weekday);

  if (!schedule) {
    // Заступление в день, не предусмотренный расписанием. Наряд создать
    // можно, но продолжительность приходится принимать по умолчанию.
    return { startsAt, endsAt: new Date(startsAt.getTime() + 3 * MS_IN_DAY), noSchedule: true };
  }

  // Число суток до дня сдачи; переход через неделю дает 7, а не 0.
  const days = ((schedule.end_weekday - schedule.start_weekday + 7) % 7) || 7;
  return { startsAt, endsAt: new Date(startsAt.getTime() + days * MS_IN_DAY), noSchedule: false };
}

/**
 * Исключение уже занятых: сотрудник не может одновременно находиться
 * в двух нарядах, пересекающихся по времени.
 */
function excludeBusy(candidates, busyEmployeeIds) {
  const busy = new Set(busyEmployeeIds);
  return candidates.filter((c) => !busy.has(c.id));
}

/**
 * Проверка состава на непротиворечивость.
 *
 * Один человек не может занимать два поста в одном наряде: посты несутся
 * одновременно. Ошибку требуется выявить до записи в БД, чтобы сообщение
 * было понятным, а не пришло из ограничения СУБД.
 *
 * @param {Array<{postId:number, employeeId:number}>} assignments
 * @returns {string[]} перечень нарушений; пустой массив — состав корректен
 */
function validateAssignments(assignments, postsById) {
  const problems = [];
  const seen = new Map();

  for (const item of assignments) {
    if (seen.has(item.employeeId)) {
      const first = postsById.get(seen.get(item.employeeId));
      const second = postsById.get(item.postId);
      problems.push(
        `Один и тот же человек назначен на посты «${first?.name}» и «${second?.name}».`,
      );
    } else {
      seen.set(item.employeeId, item.postId);
    }
  }

  return problems;
}

module.exports = {
  isoWeekday,
  computePeriod,
  excludeBusy,
  validateAssignments,
};
