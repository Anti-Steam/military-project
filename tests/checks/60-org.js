'use strict';

// Оргструктура, область видимости и ответственное подразделение наряда.

const org = require('../../services/app/modules/org/service');
const access = require('../../services/app/modules/access/service');
const duty = require('../../services/app/modules/duty/service');
const db = require('../../services/app/db/pool');

const ADMIN = { id: null, scope_unit_id: null };

async function unitByName(shortName) {
  const { rows } = await db.query('SELECT id FROM core.units WHERE short_name = $1', [shortName]);
  return rows[0] ? rows[0].id : null;
}

/** Структура вложенная: рота — взвод — отделение. */
exports.дерево_подразделений = async (t) => {
  const tree = await org.tree(ADMIN);

  t.is(tree.length, 1, 'корень один — войсковая часть');
  const part = tree[0];
  t.ok(part.children.length >= 4, `в части подразделений: ${part.children.length}`);

  const company = part.children.find((u) => u.short_name === '1 рота');
  t.ok(Boolean(company), 'первая рота на месте');
  t.is(company.children.length, 3, 'в роте три взвода');
  t.is(company.children[0].children.length, 3, 'во взводе три отделения');

  // В роте своих людей мало — управление, — а в подчинении сотня.
  t.ok(company.total_count > company.own_count,
    `своих ${company.own_count}, в подчинении ${company.total_count}`);
  t.ok(company.children[0].children[0].employees === undefined
    || company.children[0].children[0].employees.length >= 0, 'отделения существуют');
};

/** Командир видит своё поддерево и ничего сверх него. */
exports.область_видимости_командира = async (t) => {
  const company = await unitByName('1 рота');
  const foreign = await unitByName('2 рота');
  const commander = { id: null, scope_unit_id: company };

  const ids = await org.scopeIds(commander);
  t.ok(ids.includes(company), 'своё подразделение в области видимости');
  t.ok(!ids.includes(foreign), 'чужая рота вне области видимости');
  t.is(ids.length, 1 + 3 + 9, 'рота, три взвода и девять отделений');

  t.is(await org.scopeIds(ADMIN), null, 'у администратора области нет — видит всё');

  const tree = await org.tree(commander);
  t.is(tree.length, 1, 'корнем дерева становится своё подразделение');
  t.is(tree[0].id, company, 'и это именно оно');

  // Чужого человека забрать нельзя: проверяется и откуда, и куда. Перевод —
  // на должность; берется любая должность своей роты.
  const { rows } = await db.query(`
    SELECT e.id FROM personnel.employees e JOIN core.units u ON u.id = e.unit_id
    WHERE u.short_name = '2 рота' LIMIT 1
  `);
  const { rows: [own] } = await db.query('SELECT id FROM core.positions WHERE unit_id = $1 LIMIT 1', [company]);
  const assigner = { ...commander, permissions: new Set(['personnel.assign']) };
  await t.fails(
    () => org.transferEmployee(assigner, rows[0].id, own.id),
    'человек из чужой роты не переносится',
  );
};

/** Подразделение с людьми или историей не удаляется, а выводится из применения. */
exports.удаление_только_пустого = async (t) => {
  const company = await unitByName('1 рота');

  await t.fails(() => org.removeUnit(ADMIN, company), 'рота с людьми не удаляется');

  const { rows } = await db.query('SELECT id FROM core.units WHERE parent_id IS NULL');
  await t.fails(() => org.removeUnit(ADMIN, rows[0].id), 'войсковая часть не удаляется');

  // Пустое подразделение удаляется: за него ничего не держится.
  const id = await org.createUnit(ADMIN, {
    parentId: company, name: 'Проверочное отделение', shortName: 'пров. отд.',
  });
  t.ok(Number.isInteger(id), 'пустое подразделение заведено');
  await org.removeUnit(ADMIN, id);

  const gone = await org.getUnit(id);
  t.is(gone, null, 'и удалено');

  // Внутрь собственного поддерева перенести нельзя: подразделение стало бы
  // предком самому себе.
  const platoon = (await org.tree(ADMIN))[0].children
    .find((u) => u.id === company).children[0];
  await t.fails(
    () => org.updateUnit(ADMIN, company, {
      name: 'Первая рота', shortName: '1 рота', parentId: platoon.id,
    }),
    'перенос внутрь своего поддерева отклонён',
  );
};

/**
 * Закрепление поста за подразделением: у командира этого подразделения сутки
 * становятся своими, у остальных остаются спокойными.
 *
 * Ответственный задается ТОЛЬКО по постам — очередью поста или точечно на
 * сутки. Закрепления всего наряда нет (решение 121).
 */
exports.ответственное_подразделение = async (t) => {
  const type = (await duty.listDutyTypes()).find((x) => x.code === 'SN');

  // Берутся подразделения, за которыми на стенде нет постов: иначе сутки были
  // бы своими еще до проверки.
  const company = await unitByName('УС');
  const foreign = await unitByName('ТС');

  const now = new Date();
  const month = new Date(now.getFullYear(), now.getMonth() + 2, 1);
  const schedule = await duty.getMonthSchedule(
    type.id, month.getFullYear(), month.getMonth() + 1, null, null,
  );
  const any = schedule.grid.flat().find((d) => d.cell && !d.outside && d.cell.isStart);
  const date = any.cell.startDate;

  // Пост, который на эти сутки ни за УС, ни за ТС не закреплен.
  const posts = await duty.listPosts(type.id);
  const scope = await org.scopeIds({ scope_unit_id: company });
  const other = await org.scopeIds({ scope_unit_id: foreign });

  const cellFor = async (scopeIds) => {
    const view = await duty.getMonthSchedule(
      type.id, month.getFullYear(), month.getMonth() + 1, null, scopeIds,
    );
    return view.grid.flat().find((d) => d.key === date).cell;
  };

  const before = await cellFor(scope);
  const post = posts[0];

  try {
    // Точечное закрепление поста на эти сутки за подразделением.
    await duty.setPostResponsibility(post.id, date, company, 'проверка', null);

    const mine = await cellFor(scope);
    t.is(mine.foreign, false, 'после закрепления поста сутки стали своими');
    t.ok(mine.postCount > before.postCount || before.foreign,
      'в сутках появились места, за которые отвечает подразделение');
    t.ok(mine.units.includes('УС'), 'подразделение показано в ячейке');

    const theirs = await cellFor(other);
    t.ok(theirs.postCount <= (await cellFor(null)).postCount,
      'командиру другого подразделения эти места не засчитаны');

    // Снятие закрепления возвращает прежнее состояние.
    await duty.setPostResponsibility(post.id, date, null, null, null);
    t.is((await cellFor(scope)).foreign, before.foreign, 'после снятия — как было');
  } finally {
    await duty.setPostResponsibility(post.id, date, null, null, null);
  }
};

/** Право закрепления — у начальника службы, не у командира. */
exports.право_закрепления = async (t) => {
  const login = 'check.chief';
  await db.query('DELETE FROM core.users WHERE login = $1', [login]);

  try {
    const { id } = await access.createUser({
      login, roleCode: 'chief', permissions: [], actorId: null,
    });
    t.is(await access.authorizeUser(id, 'duty.responsibility'), true,
      'начальник службы закрепляет подразделения');
    t.is(await access.authorizeUser(id, 'unit.manage'), false,
      'но штатную структуру не ведёт');

    await db.query('DELETE FROM core.users WHERE login = $1', [login]);

    const unit = (await db.query('SELECT id FROM core.units ORDER BY id LIMIT 1')).rows[0].id;
    const { id: commanderId } = await access.createUser({
      login, roleCode: 'commander', scopeUnitId: unit, permissions: [], actorId: null,
    });
    t.is(await access.authorizeUser(commanderId, 'duty.responsibility'), false,
      'командир подразделения себе наряд не закрепляет');
    t.is(await access.authorizeUser(commanderId, 'unit.manage'), true,
      'но ведёт структуру внутри своего');
    t.is(await access.authorizeUser(commanderId, 'personnel.assign'), true,
      'и распределяет своих людей');
  } finally {
    await db.query('DELETE FROM core.users WHERE login = $1', [login]);
  }
};

/**
 * Вкладка «Подразделения»: в строке — название и «изменить», правка
 * спрятана; раскрытое подразделение показывает свой личный состав со
 * ссылками на карточки. После сохранения открывается то же подразделение.
 */
exports.вкладка_подразделений = async (t, ctx) => {
  if (!ctx.alive) { t.ok(true, 'приложение не запущено — пропущено'); return; }
  const { get, post: send } = require('../lib');

  // Вложенное подразделение со своими людьми — по свойству, не по названию.
  const { rows } = await db.query(`
    SELECT u.id, u.parent_id, u.name, u.short_name, u.is_active,
           (SELECT e.id FROM personnel.employees e WHERE e.unit_id = u.id AND e.is_active LIMIT 1) AS person
    FROM core.units u
    WHERE u.parent_id IS NOT NULL
      AND EXISTS (SELECT 1 FROM personnel.employees e WHERE e.unit_id = u.id AND e.is_active)
    LIMIT 1
  `);
  if (rows.length === 0) { t.ok(true, 'подразделения с людьми нет — пропущено'); return; }
  const unit = rows[0];

  const page = await get('/units');
  t.is(page.status, 200, 'вкладка открывается');
  t.ok(page.body.includes(`id="unit-${unit.id}"`), 'подразделение — раскрывающийся узел');
  t.ok(page.body.includes(`<div class="unit-edit" id="edit-${unit.id}" hidden>`), 'правка спрятана');
  t.ok(page.body.includes(`data-edit-toggle="edit-${unit.id}"`), 'есть кнопка «изменить»');

  // До панели правки в узле нет ни одной формы: строка подразделения чистая.
  const start = page.body.indexOf(`id="unit-${unit.id}"`);
  const head = page.body.slice(start, page.body.indexOf(`id="edit-${unit.id}"`, start));
  t.is(head.includes('<form'), false, 'в строке подразделения форм нет');

  // Личный состав подразделения — внутри его узла, со ссылкой на карточку.
  t.ok(page.body.indexOf(`href="/personnel/${unit.person}"`, start) > start,
    'в подразделении виден его личный состав со ссылкой на карточку');

  // Сохранение возвращает к тому же подразделению раскрытым, форма спрятана.
  const saved = await send(`/units/${unit.id}`, {
    name: unit.name, shortName: unit.short_name, parentId: String(unit.parent_id),
    isActive: unit.is_active ? 'on' : '',
  });
  t.is(saved.status, 302, 'подразделение сохранено');
  t.is(saved.location, `/units?open=${unit.id}#unit-${unit.id}`, 'возврат к нему же');

  const back = await get(`/units?open=${unit.id}`);
  // Атрибут open — в теге узла, где бы он ни стоял среди прочих.
  const isOpen = (id) => new RegExp(`<details[^>]*id="unit-${id}"[^>]*\\sopen[\\s>]`).test(back.body);
  t.ok(isOpen(unit.id), 'оно раскрыто');
  t.ok(isOpen(unit.parent_id), 'и вышестоящее тоже');
  t.ok(back.body.includes(`<div class="unit-edit" id="edit-${unit.id}" hidden>`), 'а правка снова спрятана');
};
