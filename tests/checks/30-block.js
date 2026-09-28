'use strict';

// Назначение на приказной блок вместе с посменными постами.
//
// Проверка работает на будущих сутках и за собой убирает: созданные наряды
// удаляются, чтобы стенд оставался в прежнем состоянии.

const duty = require('../../services/app/modules/duty/service');
const queries = require('../../services/app/modules/duty/queries');
const db = require('../../services/app/db/pool');

/**
 * Ближайшее свободное заступление смены ОО, на которое хватает кандидатов.
 *
 * Синтетические допуски выданы на ограниченный срок, поэтому дата не
 * задается жестко: проверка сама находит пригодные сутки впереди.
 */
let cached = null;
async function blockDate() {
  if (cached) return cached;

  const type = (await duty.listDutyTypes()).find((t) => t.code === 'OO');
  const now = new Date();

  for (let ahead = 1; ahead <= 4; ahead += 1) {
    const month = new Date(now.getFullYear(), now.getMonth() + ahead, 1);
    const schedule = await duty.getMonthSchedule(type.id, month.getFullYear(), month.getMonth() + 1, null);

    for (const day of schedule.grid.flat()) {
      if (!day.cell || !day.cell.isStart || day.outside || day.cell.duty) continue;

      const plan = await duty.getBlockPlan(type.id, day.cell.startDate, null);
      const enough = slotsOf(plan).every(({ row }) => row.candidates.length > 0);
      if (!enough) continue;

      cached = { type, date: day.cell.startDate };
      return cached;
    }
  }

  throw new Error('не нашлось свободного заступления ОО с кандидатами на ближайшие месяцы');
}

/** Все места блока: постоянный состав и выходы посменных постов. */
function slotsOf(plan) {
  const slots = [];
  for (const day of plan.days) {
    for (const row of day.rows) slots.push({ formDate: day.startDate, row });
    for (const sd of day.shiftDays || []) {
      for (const row of sd.rows) slots.push({ formDate: sd.date, row });
    }
  }
  return slots;
}

async function cleanup(type, date) {
  const { periods } = await duty.getBlockDates(type.id, date);
  const duties = await queries.findDutiesOnDates(type.id, periods.map((p) => p.startDate));
  if (duties.length > 0) {
    await db.query('DELETE FROM duty.duties WHERE id = ANY($1::int[])', [duties.map((d) => d.id)]);
  }
}

/** Блок назначается целиком: постоянный состав и выходы каждых суток. */
exports.назначение_блока_с_посменными_постами = async (t) => {
  const { type, date } = await blockDate();
  await cleanup(type, date);

  try {
    const plan = await duty.getBlockPlan(type.id, date, null);
    const slots = slotsOf(plan);

    t.ok(slots.length > plan.days[0].rows.length,
      'в блоке есть места сверх постоянного состава');
    t.is(plan.assignedTotal, 0, 'блок пуст до назначения');
    t.is(plan.requiredTotal, slots.length, 'число мест совпадает с числом строк');

    // Каждому месту — свой человек: так исключены и пересечения, и отдых.
    const used = new Set();
    const byDate = new Map();
    let unfilled = 0;

    for (const { formDate, row } of slots) {
      const pick = row.candidates.find((c) => !used.has(c.id));
      if (!pick) { unfilled += 1; continue; }
      used.add(pick.id);
      if (!byDate.has(formDate)) byDate.set(formDate, new Map());
      byDate.get(formDate).set(row.post.id, pick.id);
    }

    t.is(unfilled, 0, 'на каждое место нашелся кандидат');

    await duty.saveBlock({ dutyTypeId: type.id, date, byDate, userId: null });

    const after = await duty.getBlockPlan(type.id, date, null);
    t.is(after.assignedTotal, after.requiredTotal, 'замещены все места блока');
    t.is(after.unfilledTotal, 0, 'незакрытых мест не осталось');
    t.is(after.brokenTotal, 0, 'нарушений в составе нет');

    // Сохранены именно выходы: у посменных назначений проставлены сутки.
    const duties = await queries.findDutiesOnDates(type.id, [date]);
    const assignments = await queries.getAssignments(duties[0].id);
    t.ok(assignments.some((a) => a.on_date), 'есть назначения на конкретные сутки');
    t.ok(assignments.some((a) => !a.on_date), 'есть назначения на всю смену');

    // В графике заполнились все сутки смены, а не только день заступления.
    const [year, month] = date.split('-').map(Number);
    const schedule = await duty.getMonthSchedule(type.id, year, month, null);
    const covered = schedule.grid.flat()
      .filter((d) => d.cell && d.cell.duty && d.cell.duty.id === duties[0].id);

    t.ok(covered.length >= 3, 'смена занимает несколько суток графика');
    for (const day of covered) {
      // Чужие места этих суток могут быть замещены соседним приказом, поэтому
      // сравнение не на равенство: своих должно быть замещено не меньше, чем
      // числится за этой сменой.
      const foreignPlaces = day.cell.others.reduce((sum, o) => sum + o.required, 0);
      t.ok(day.cell.assigned >= day.cell.postCount - foreignPlaces,
        `сутки ${day.key}: свои места замещены (${day.cell.assigned} из ${day.cell.postCount - foreignPlaces})`);
    }
  } finally {
    await cleanup(type, date);
  }
};

/** Утверждение и печать охватывают выходы наравне с постоянным составом. */
exports.утверждение_и_печать_приказа = async (t) => {
  const { type, date } = await blockDate();
  await cleanup(type, date);

  try {
    const plan = await duty.getBlockPlan(type.id, date, null);
    const slots = slotsOf(plan);

    // Приказ без оружия не утверждается; проверка — об утверждении и печати,
    // поэтому на посты с оружием берутся люди со своим оружием нужного вида.
    const armed = (kind) => new Set(plan.armedOwners[kind] || []);
    const used = new Set();
    const byDate = new Map();
    for (const { formDate, row } of slots) {
      const pick = row.candidates.find((c) => !used.has(c.id)
        && (!row.weapon || armed(row.weapon.kind).has(c.id)));
      if (!pick) continue;
      used.add(pick.id);
      if (!byDate.has(formDate)) byDate.set(formDate, new Map());
      byDate.get(formDate).set(row.post.id, pick.id);
    }
    await duty.saveBlock({ dutyTypeId: type.id, date, byDate, userId: null });

    // Неполный состав не утверждается: снимем одного и проверим отказ.
    const duties = await queries.findDutiesOnDates(type.id, [date]);
    const shift = (await queries.getAssignments(duties[0].id)).find((a) => a.on_date);
    await db.query('DELETE FROM duty.duty_assignments WHERE duty_id=$1 AND post_id=$2 AND on_date=$3',
      [duties[0].id, shift.post_id, shift.on_date]);

    await t.fails(
      () => duty.approveBlock(type.id, date, null, null),
      'приказ с незамещенным выходом не утверждается',
    );

    // Вернем человека и утвердим.
    await queries.replaceAssignment(duties[0].id, shift.post_id, shift.employee_id,
      'проверка', null, shift.on_date);

    const { approved } = await duty.approveBlock(type.id, date, null, null);
    t.ok(approved > 0, 'приказ утвержден');

    const order = await duty.getPrintableOrder(duties[0].id);
    t.ok(Boolean(order), 'приказ доступен к печати');

    const roster = order.sections.flatMap((s) => s.roster);
    t.ok(roster.some((r) => r.onDate), 'в приказе есть пункты на конкретные сутки');
    t.ok(roster.some((r) => !r.onDate), 'в приказе есть постоянный состав смены');
    t.is(roster.length, slots.length, 'в приказ вошли все места блока');
  } finally {
    await cleanup(type, date);
  }
};

/** ПТСО 1 и ПТСО 2 одних суток одному человеку не отдают. */
exports.птсо_подряд_отклоняется = async (t) => {
  const { type, date } = await blockDate();
  await cleanup(type, date);

  try {
    const plan = await duty.getBlockPlan(type.id, date, null);

    // Сутки, в которых есть и дневной, и ночной ПТСО.
    const day = (plan.days[0].shiftDays || [])
      .find((sd) => sd.rows.length === 2);
    t.ok(Boolean(day), 'нашлись сутки с обоими ПТСО');

    const [first, second] = day.rows;
    const person = first.candidates.find((c) => second.candidates.some((x) => x.id === c.id));
    t.ok(Boolean(person), 'есть общий кандидат на оба поста');

    const byDate = new Map([[day.date, new Map([
      [first.post.id, person.id],
      [second.post.id, person.id],
    ])]]);

    await t.fails(
      () => duty.saveBlock({ dutyTypeId: type.id, date, byDate, userId: null }),
      'дневной и ночной ПТСО подряд одному человеку',
    );

    // Форма узнает об этом ДО отправки: разряды мест объявлены несовместимыми.
    t.ok((plan.slotConflicts[first.slotClass] || []).includes(second.slotClass)
      || (plan.slotConflicts[second.slotClass] || []).includes(first.slotClass),
      'места объявлены несовместимыми для фильтрации в форме');
  } finally {
    await cleanup(type, date);
  }
};

/** Порядок постов ПТСО и ПУД в справочнике. */
exports.правила_постов_птсо_и_пуд = async (t) => {
  const posts = await queries.listPosts(
    (await duty.listDutyTypes()).find((x) => x.code === 'OO').id,
  );
  const byName = new Map(posts.map((p) => [p.short_name, p]));

  // Отсыпной до начала следующего рабочего дня: у обоих ПТСО это сутки сдачи.
  t.is(byName.get('ПТСО 1').recovery_sleep_days, 1, 'после дневного ПТСО заняты сутки сдачи');
  t.is(byName.get('ПТСО 2').recovery_sleep_days, 1, 'после ночного ПТСО — сутки отдыха');
  t.is(byName.get('ПУД 1').recovery_sleep_days, 0, 'ПУД — обычный рабочий день');

  t.is(byName.get('ПТСО 1').per_day, true, 'ПТСО меняется каждые сутки');
  t.is(byName.get('ПУД 1').per_day, false, 'ПУД заступает на всю смену');
  t.is(byName.get('ПУД 1').start_time, '08:00:00', 'часы ПУД сохранены для приказа');
  t.is(byName.get('ПУД 1').duration_hours, 10, 'ПУД несет службу десять часов');

  t.is(byName.get('ПТСО 1').required_weapon_kind, null, 'оружие на ПТСО не требуется');
  t.is(byName.get('ПУД 1').required_weapon_kind, null, 'оружие на ПУД не требуется');
};

// Сценарии назначения получают собственный состав с действующими допусками
// и оружием. Демонстрационный штат намеренно содержит недопущенных людей.
for (const name of ['назначение_блока_с_посменными_постами', 'утверждение_и_печать_приказа', 'птсо_подряд_отклоняется']) {
  const run = exports[name];
  exports[name] = async (...args) => {
    const rollback = new Error('rollback fixtures');
    try {
      await db.transaction(async () => {
        cached = null;
        const type = (await duty.listDutyTypes()).find(t => t.code === 'OO');
        const root = await queries.rootUnit();
        const permits = [...new Set([
          ...(await queries.getGeneralPermits(type.id)).map(p => p.permit_type_id),
          ...(await queries.listPosts(type.id)).map(p => p.required_permit_type_id).filter(Boolean),
        ])];
        const { rows: people } = await db.query(`
          INSERT INTO personnel.employees(last_name,first_name,unit_id)
          SELECT 'Проверочный ' || n, 'Синтетический', $1 FROM generate_series(1,50) n RETURNING id
        `, [root]);
        const ids = people.map(p => p.id);
        await db.query(`
          INSERT INTO personnel.employee_permits(employee_id,permit_type_id,issued_at,expires_at,status)
          SELECT e,p,CURRENT_DATE-1,CURRENT_DATE+730,'active'
          FROM unnest($1::int[]) e CROSS JOIN unnest($2::int[]) p
        `, [ids, permits]);
        await db.query(`
          INSERT INTO personnel.weapons(name,serial_number,manufactured_on,kind,owner_id)
          SELECT 'Учебный автомат','CHECK-BLOCK-' || e,CURRENT_DATE-1,'rifle',e FROM unnest($1::int[]) e
          UNION ALL
          SELECT 'Учебный пистолет','CHECK-BLOCK-P-' || e,CURRENT_DATE-1,'pistol',e FROM unnest($1::int[]) e
        `, [ids]);
        await run(...args);
        throw rollback;
      });
    } catch (error) { if (error !== rollback) throw error; }
  };
}
