'use strict';

// Оружие на наряд: наличие своего оружия назначению не мешает; человеку без
// него при назначении выбирают оружие другого, свободного в эти и следующие
// сутки, и приказ называет, за кем какое закрепить.

const duty = require('../../services/app/modules/duty/service');
const personnel = require('../../services/app/modules/personnel/service');
const declension = require('../../services/app/lib/declension');
const db = require('../../services/app/db/pool');

const failure = async (fn) => {
  try { await fn(); return null; } catch (err) { return err.message; }
};

/** Строки приказа: звание и фамилия в творительном падеже. */
exports.склонение_для_приказа = async (t) => {
  const cases = [
    [['лейтенант', 'Иванов', 'Иван', 'Иванович'], 'лейтенантом Ивановым И.И.'],
    [['старший сержант', 'Петрова', 'Анна', 'Сергеевна'], 'старшим сержантом Петровой А.С.'],
    [['рядовой', 'Шевченко', 'Олег', 'Павлович'], 'рядовым Шевченко О.П.'],
    [['младший лейтенант', 'Толстой', 'Лев', 'Николаевич'], 'младшим лейтенантом Толстым Л.Н.'],
    [['старшина', 'Гоголь', 'Николай', 'Васильевич'], 'старшиной Гоголем Н.В.'],
    [['прапорщик', 'Черных', 'Илья', 'Петрович'], 'прапорщиком Черных И.П.'],
    [['ефрейтор', 'Зайцев', 'Пётр', 'Ильич'], 'ефрейтором Зайцевым П.И.'],
    [['капитан', 'Шмидт', 'Отто', null], 'капитаном Шмидтом О.'],
    [['майор', 'Высоцкий', 'Владимир', 'Семёнович'], 'майором Высоцким В.С.'],
    [['сержант', 'Ковальская', 'Мария', 'Петровна'], 'сержантом Ковальской М.П.'],
    [['подполковник', 'Римский-Корсаков', 'Николай', 'Андреевич'], 'подполковником Римским-Корсаковым Н.А.'],
    [[null, 'Смирнова', 'Ольга', null], 'Смирновой О.'],
  ];
  for (const [[rankName, lastName, firstName, middleName], expected] of cases) {
    t.is(declension.instrumental({ rankName, lastName, firstName, middleName }), expected, expected);
  }
};

/**
 * Весь путь на тестовом виде наряда, в транзакции с откатом: назначение без
 * оружия, выбор чужого, отказы по правилам, утверждение и строка приказа.
 */
exports.оружие_при_назначении = async (t) => {
  const rollback = new Error('rollback weapons check');
  try {
    await db.transaction(async () => {
      const one = async (sql, params = []) => (await db.query(sql, params)).rows[0];
      const root = (await one('SELECT id FROM core.units WHERE parent_id IS NULL LIMIT 1')).id;
      const admin = (await one("SELECT id FROM core.users WHERE role_code = 'admin' LIMIT 1")).id;
      const rank = (await one("SELECT id FROM core.ranks WHERE name = 'рядовой'")).id;

      const type = (await one(`INSERT INTO duty.duty_types
          (code, name, kind, start_time, duration_hours, recovery_sleep_days, recovery_off_days,
           rest_excludes_weekends, base_weight)
        VALUES ('TEST_WPN', 'Проверка оружия', 'daily', '18:00', 24, 1, 0, false, 1) RETURNING id`)).id;
      const post = (await one(`INSERT INTO duty.duty_posts (duty_type_id, name, required_weapon_kind)
        VALUES ($1, 'Пост с пистолетом', 'pistol') RETURNING id`, [type])).id;

      const person = async (last, first, middle) => (await one(`INSERT INTO personnel.employees
          (last_name, first_name, middle_name, rank_id, unit_id)
        VALUES ($1, $2, $3, $4, $5) RETURNING id`, [last, first, middle, rank, root])).id;
      const unarmed = await person('Петрова', 'Анна', 'Сергеевна');
      const owner = await person('Оружейнов', 'Борис', 'Игоревич');
      const busyOwner = await person('Занятов', 'Виктор', 'Олегович');
      const other = await person('Другой', 'Глеб', 'Петрович');

      const pistol = async (serial, ownerId) => (await one(`INSERT INTO personnel.weapons
          (name, serial_number, manufactured_on, kind, owner_id)
        VALUES ('ПМ', $1, '1999-05-01', 'pistol', $2) RETURNING id`, [serial, ownerId])).id;
      const freePistol = await pistol('АА000001', owner);
      const busyPistol = await pistol('АА000002', busyOwner);

      // Середина недели: приказ на будни — на одни сутки, без выходных.
      const D = '2031-03-12';
      const D1 = '2031-03-13';
      const save = (date, employeeId, weaponId) => duty.saveBlock({
        dutyTypeId: type, date, userId: admin,
        byDate: new Map([[date, new Map([[post, employeeId]])]]),
        weapons: new Map([[date, new Map([[post, weaponId]])]]),
      });

      // Своего оружия нет — человек все равно в кандидатах.
      const selection = await duty.findCandidatesByPost(type, D, null);
      t.ok(selection.posts[0].candidates.some((c) => c.id === unarmed),
        'человек без оружия предлагается в наряд');

      // Страница назначения: у поста с оружием есть выбор, в перечне — оба пистолета.
      const dayOf = (plan) => plan.days.find((d) => d.startDate === D);
      let plan = await duty.getBlockPlan(type, D, root);
      const row = dayOf(plan).rows[0];
      t.ok(Boolean(row.weapon), 'у поста с оружием есть выбор оружия');
      const options = plan.weaponOptions[row.weapon.group] || [];
      t.ok(options.some((o) => o.id === freePistol) && options.some((o) => o.id === busyPistol),
        'в выборе — оружие не занятых людей');
      t.ok(/ПМ № АА000001 \(1999 г\.\) — .*Оружейнов/.test(options.find((o) => o.id === freePistol).label),
        'в списке видны номер, год и владелец');

      // Без оружия назначить можно, утвердить — нет.
      await save(D, unarmed, null);
      t.ok(/не выбрано оружие/.test(await failure(() => duty.approveBlock(type, D, null, admin)) || ''),
        'без выбранного оружия приказ не утверждается');

      // Владелец в наряде на следующие сутки — его оружие не выдается.
      await save(D1, busyOwner, null);
      t.ok(/владелец/.test(await failure(() => save(D, unarmed, busyPistol)) || ''),
        'оружие владельца, который сам несет его в следующие сутки, не выдается');
      plan = await duty.getBlockPlan(type, D, root);
      t.is((plan.weaponOptions[dayOf(plan).rows[0].weapon.group] || [])
        .some((o) => o.id === busyPistol), false, 'и в выбор оно не попадает');

      // Свободное оружие выдается и закрепляется само.
      await save(D, unarmed, freePistol);
      const { rows: [assigned] } = await db.query(`SELECT da.weapon_id FROM duty.duty_assignments da
        JOIN duty.duties d ON d.id = da.duty_id WHERE d.duty_type_id = $1 AND d.start_date = $2`, [type, D]);
      t.is(assigned.weapon_id, freePistol, 'выбранное оружие записано в назначение');

      const listed = (await personnel.listWeapons()).find((w) => w.id === freePistol);
      t.ok((listed.loans || []).some((l) => /Петрова/.test(l.employee)),
        'в учете оружия оно отмечено перезакрепленным на наряд');

      // То же оружие соседу на пересекающиеся сутки не выдается.
      t.ok(/уже выдано/.test(await failure(() => save('2031-03-11', other, freePistol)) || ''),
        'одно оружие двоим на пересекающиеся сутки не выдается');

      // Утверждение и строка приказа.
      await duty.approveBlock(type, D, null, admin);
      const { rows: [approved] } = await db.query(
        'SELECT id FROM duty.duties WHERE duty_type_id = $1 AND start_date = $2', [type, D]);
      const order = await duty.getPrintableOrder(approved.id);
      t.is(order.sections[0].roster[0].weapon.orderLine,
        'За рядовым Петровой А.С. на время несения дежурства закрепить пистолет № АА000001 1999 г.',
        'приказ называет, за кем какое оружие закрепить');

      // У кого есть свое, выбор снимается сам.
      await save(D1, busyOwner, freePistol);
      const { rows: [own] } = await db.query(`SELECT da.weapon_id FROM duty.duty_assignments da
        JOIN duty.duties d ON d.id = da.duty_id WHERE d.duty_type_id = $1 AND d.start_date = $2`, [type, D1]);
      t.is(own.weapon_id, null, 'человеку со своим оружием чужое не закрепляется');

      throw rollback;
    });
  } catch (err) {
    if (err !== rollback) throw err;
  }
};

/** Ручной передачи больше нет; выбор оружия — на странице назначения. */
exports.страницы_оружия = async (t, ctx) => {
  if (!ctx.alive) { t.ok(true, 'приложение не запущено — пропущено'); return; }
  const { get } = require('../lib');

  const weapons = await get('/weapons');
  t.is(weapons.status, 200, 'учет оружия открывается');
  t.is(weapons.body.includes('/weapons/transfer'), false, 'ручной передачи на наряд нет');
  t.ok(weapons.body.includes('при назначении в наряд'), 'сказано, где оружие закрепляется');

  // Вид наряда с постом, где выдается оружие, — по свойству.
  const { rows } = await db.query(`SELECT DISTINCT duty_type_id FROM duty.duty_posts
    WHERE is_active AND required_weapon_kind IS NOT NULL LIMIT 1`);
  if (rows.length === 0) { t.ok(true, 'постов с оружием нет — пропущено'); return; }

  const now = new Date();
  const month = new Date(now.getFullYear(), now.getMonth() + 2, 1);
  const date = `${month.getFullYear()}-${String(month.getMonth() + 1).padStart(2, '0')}-15`;
  const page = await get(`/duties/plan?type=${rows[0].duty_type_id}&date=${date}`);
  if (page.status === 404) { t.ok(true, 'на эту дату наряд не положен — пропущено'); return; }
  t.is(page.status, 200, 'страница назначения открывается');
  t.ok(page.body.includes('class="weapon-pick"'), 'у постов с оружием есть выбор оружия');
  t.ok(/name="weapon_\d{4}-\d{2}-\d{2}_\d+"/.test(page.body), 'поле оружия уходит с формой');
};

/**
 * Владелец в наряде, где его оружие не нужно (пост без оружия или с другим
 * видом), оружию не помеха: оно лежит без дела и предлагается ПЕРВЫМ.
 * Занят владелец, только если сам несет это оружие.
 */
exports.оружие_владельца_в_наряде_без_оружия = async (t) => {
  const rollback = new Error('rollback owner on unarmed duty');
  try {
    await db.transaction(async () => {
      const one = async (sql, params = []) => (await db.query(sql, params)).rows[0];
      const root = (await one('SELECT id FROM core.units WHERE parent_id IS NULL LIMIT 1')).id;
      const admin = (await one("SELECT id FROM core.users WHERE role_code = 'admin' LIMIT 1")).id;

      const type = async (code) => (await one(`INSERT INTO duty.duty_types
          (code, name, kind, start_time, duration_hours, recovery_sleep_days, recovery_off_days,
           rest_excludes_weekends, base_weight)
        VALUES ($1, $1, 'daily', '18:00', 24, 1, 0, false, 1) RETURNING id`, [code])).id;
      const post = async (typeId, kind) => (await one(`INSERT INTO duty.duty_posts
          (duty_type_id, name, required_weapon_kind) VALUES ($1, $2, $3) RETURNING id`,
      [typeId, `Пост ${kind || 'без оружия'}`, kind])).id;

      const armedType = await type('TEST_WA');
      const unarmedType = await type('TEST_WU');
      const rifleType = await type('TEST_WR');
      const armedPost = await post(armedType, 'pistol');
      const unarmedPost = await post(unarmedType, null);
      const riflePost = await post(rifleType, 'rifle');

      const person = async (last) => (await one(`INSERT INTO personnel.employees
          (last_name, first_name, middle_name, unit_id)
        VALUES ($1, 'Тест', 'Тестович', $2) RETURNING id`, [last, root])).id;
      const pistol = async (serial, ownerId) => (await one(`INSERT INTO personnel.weapons
          (name, serial_number, manufactured_on, kind, owner_id)
        VALUES ('ПМ', $1, '2001-01-01', 'pistol', $2) RETURNING id`, [serial, ownerId])).id;

      const borrower = await person('Безоружный');
      const idleOwner = await person('Свободный');
      const unarmedOwner = await person('Дневальный');
      const otherKindOwner = await person('Автоматчик');
      const carrier = await person('Носящий');
      const idlePistol = await pistol('ББ000001', idleOwner);
      const unarmedPistol = await pistol('ББ000002', unarmedOwner);
      const otherKindPistol = await pistol('ББ000003', otherKindOwner);
      const carriedPistol = await pistol('ББ000004', carrier);

      const D = '2031-04-16';
      const save = (typeId, postId, date, employeeId, weaponId = null) => duty.saveBlock({
        dutyTypeId: typeId, date, userId: admin,
        byDate: new Map([[date, new Map([[postId, employeeId]])]]),
        weapons: new Map([[date, new Map([[postId, weaponId]])]]),
      });

      // Владельцы в нарядах те же сутки: без оружия, с автоматом, со своим пистолетом.
      await save(unarmedType, unarmedPost, D, unarmedOwner);
      await save(rifleType, riflePost, D, otherKindOwner);
      await save(armedType, armedPost, '2031-04-17', carrier);

      const plan = await duty.getBlockPlan(armedType, D, root);
      const row = plan.days.find((d) => d.startDate === D).rows[0];
      const options = plan.weaponOptions[row.weapon.group] || [];
      const ids = options.map((o) => o.id);

      t.ok(ids.includes(unarmedPistol), 'владелец в наряде без оружия — его оружие в выборе');
      t.ok(ids.includes(otherKindPistol), 'владелец на посту с другим видом — тоже');
      t.ok(ids.includes(idlePistol), 'оружие незанятого владельца — в выборе');
      t.is(ids.includes(carriedPistol), false, 'владелец, сам несущий это оружие, — нет');

      const firstIdle = ids.indexOf(idlePistol);
      t.ok(ids.indexOf(unarmedPistol) < firstIdle && ids.indexOf(otherKindPistol) < firstIdle,
        'оружие владельцев в наряде без него идет первым');
      t.ok(/выдать в первую очередь/.test(options.find((o) => o.id === unarmedPistol).label),
        'и помечено в списке');

      // Выдача такого оружия проходит.
      await save(armedType, armedPost, D, borrower, unarmedPistol);
      const { rows: [saved] } = await db.query(`SELECT da.weapon_id FROM duty.duty_assignments da
        JOIN duty.duties d ON d.id = da.duty_id WHERE d.duty_type_id = $1 AND d.start_date = $2`,
      [armedType, D]);
      t.is(saved.weapon_id, unarmedPistol, 'оружие владельца в наряде без оружия выдано');

      throw rollback;
    });
  } catch (err) {
    if (err !== rollback) throw err;
  }
};
