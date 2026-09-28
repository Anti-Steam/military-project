'use strict';

// Очередь заступления — чистый расчет, без БД.
//
// Отвечает на вопрос «чья очередь и кто сюда годится лучше». Все исходные
// данные передаются снаружи, поэтому формулу можно проверить целиком, не
// поднимая базу, и она одна на подбор, на сортировку списков и на показ.
//
//     очередь = готовность − нагрузка × коэффициент
//             + вес звания на посту + личная поправка к посту
//
// ГОТОВНОСТЬ растет каждые сутки простоя до потолка и падает до нуля в день
// заступления. Она же служит порогом: человек не предлагается только в сутки
// сдачи, а со следующих уже предлагается. Потолок обязателен: без него вернувшийся из отпуска месяцами
// вытеснял бы всех остальных, хотя разница между «не был сорок суток» и «не
// был сто» для распределения нарядов никакой.
//
// Жесткие правила — допуск, отсутствие, отсыпной, занятость, оружие — сюда не
// входят. Это ЗАПРЕТЫ, а не предпочтения: кандидат, который их не проходит,
// не попадает в расчет вовсе, и никакой вес не может его вернуть.

const DEFAULTS = {
  'queue.ready_max_days': 30,
  'queue.workload_factor': 0.3,
  'queue.min_days_off': 1,
  'queue.unassigned_bonus': 0,
};

/** Настройки из БД, дополненные значениями по умолчанию. */
function settingsFrom(rows) {
  const out = { ...DEFAULTS };
  for (const row of rows || []) {
    if (row.key in out) out[row.key] = Number(row.value);
  }
  return out;
}

/**
 * Готовность: сутки простоя до потолка.
 *
 * Тот, кто не заступал ни разу, считается полностью готовым — иначе новичок
 * никогда не попал бы в наряд, а именно его очередь и есть первая.
 */
function readiness(lastDate, onDate, settings) {
  const max = settings['queue.ready_max_days'];
  if (!lastDate) return max + settings['queue.unassigned_bonus'];

  const days = Math.round(
    (Date.parse(`${onDate}T12:00:00`) - Date.parse(`${lastDate}T12:00:00`)) / 86400000,
  );

  if (days <= 0) return 0;
  return Math.min(max, days);
}

/**
 * Очередь одного человека на один пост.
 *
 * @param {object} person   {lastDate, workload}
 * @param {object} weights  {rank, personal} — вес звания и личная поправка
 * @returns {{value:number, readiness:number, workload:number, fit:number}}
 */
function queueValue(person, weights, onDate, settings) {
  const ready = readiness(person.lastDate, onDate, settings);
  const load = (person.workload || 0) * settings['queue.workload_factor'];
  const fit = (weights.rank || 0) + (weights.personal || 0);

  return {
    value: Math.round((ready - load + fit) * 100) / 100,
    readiness: ready,
    workload: Math.round(load * 100) / 100,
    fit,
  };
}

/**
 * Проходит ли кандидат порог предложения.
 *
 * Порог задан в СУТКАХ ПРОСТОЯ и сравнивается с готовностью, а не с итоговой
 * очередью. Иначе накопленная нагрузка отодвигала бы возврат в списки: при
 * пороге по очереди человек возвращался на третьи сутки, хотя правило —
 * нельзя только в сутки сдачи.
 *
 * Нагрузка и соответствие посту влияют на ПОРЯДОК, но никого не отсекают:
 * смешивать «кого предпочесть» с «кого нельзя» значит получать необъяснимые
 * исчезновения людей из списка.
 */
function passes(queue, settings) {
  return queue.readiness >= settings['queue.min_days_off'];
}

/**
 * Порядок кандидатов: первым тот, чья очередь выше.
 *
 * При равной очереди предпочтение тому, кто дольше не заступал, а при полном
 * равенстве — меньшему номеру: порядок должен быть устойчивым, иначе список
 * перетасовывается при каждом обновлении страницы.
 */
function compare(a, b) {
  if (b.queue.value !== a.queue.value) return b.queue.value - a.queue.value;
  if (b.queue.readiness !== a.queue.readiness) return b.queue.readiness - a.queue.readiness;
  return a.id - b.id;
}

module.exports = { DEFAULTS, settingsFrom, readiness, queueValue, passes, compare };
