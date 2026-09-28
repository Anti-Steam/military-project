'use strict';

// Списки с ручным порядком устроены одинаково: ручка «⠿», перетаскивание
// среди соседей, мгновенное сохранение полным перечнем. Проверяется общая
// часть (lib/validation.order, lib/sortable, public/js/sortable.js) и каждый
// список, где она подключена: виды нарядов, посты, подразделения,
// направления допусков.

const v = require('../../services/app/lib/validation');
const duty = require('../../services/app/modules/duty/service');
const db = require('../../services/app/db/pool');

/** Прежний порядок строк таблицы — чтобы вернуть его в finally. */
async function snapshot(table, where = 'true', params = []) {
  const { rows } = await db.query(`SELECT id, sort_order FROM ${table} WHERE ${where}`, params);
  return rows;
}

async function restore(table, rows) {
  for (const row of rows) {
    await db.query(`UPDATE ${table} SET sort_order = $2 WHERE id = $1`, [row.id, row.sort_order]);
  }
}

const failsWith = (fn) => { try { fn(); return null; } catch (err) { return err.message; } };

/** Одна проверка порядка на все списки. */
exports.проверка_перечня_общая = async (t) => {
  t.is(v.order(['3', '1', '2'], [1, 2, 3]).join(','), '3,1,2', 'полный перечень принят');
  t.is(v.order('5', [5]).join(','), '5', 'список из одного элемента');
  t.ok(/устарел/.test(failsWith(() => v.order(['1', '2'], [1, 2, 3]))), 'неполный отклонен');
  t.ok(/устарел/.test(failsWith(() => v.order(['1', '2', '9'], [1, 2, 3]))), 'чужой отклонен');
  t.ok(/повторяется/.test(failsWith(() => v.order(['1', '1', '2'], [1, 2, 3]))), 'повтор отклонен');
  t.ok(Boolean(failsWith(() => v.order(['x'], [1]))), 'не число отклонено');
};

/** Все списки с ручным порядком собраны из одних частей. */
exports.одинаковые_части_списков = async (t, ctx) => {
  if (!ctx.alive) { t.ok(true, 'приложение не запущено — пропущено'); return; }
  const { get } = require('../lib');

  const script = await get('/js/sortable.js');
  t.is(script.status, 200, 'общий сценарий перетаскивания отдается');
  t.is((await get('/js/post-order.js')).status, 404, 'отдельного сценария постов больше нет');

  for (const [path, list] of [
    ['/duty-types', 'data-sortable="/duty-types/order"'],
    ['/units', 'data-sortable="/units/'],
    ['/permits', 'data-sortable="/permits/directions/within/root/order"'],
  ]) {
    const page = await get(path);
    t.is(page.status, 200, `${path} открывается`);
    t.ok(page.body.includes(list), `${path}: список перетаскивается`);
    t.ok(page.body.includes('class="drag-handle"'), `${path}: та же ручка`);
    t.ok(page.body.includes('sortable-hint'), `${path}: та же подсказка`);
    t.ok(page.body.includes('/js/sortable.js'), `${path}: тот же сценарий`);
    t.is(/name="sortOrder"/.test(page.body), false, `${path}: порядок числом не вводится`);
  }

  const somePost = (await duty.listAllPosts())[0];
  const form = await get(`/posts/${somePost.id}/edit`);
  t.is(/name="sortOrder"/.test(form.body), false, 'в форме поста нет поля порядка');
};

/** Виды нарядов: порядок хранится в базе и им же идут списки видов. */
exports.порядок_видов_нарядов = async (t, ctx) => {
  if (!ctx.alive) { t.ok(true, 'приложение не запущено — пропущено'); return; }
  const { post: send } = require('../lib');

  const before = await duty.listDutyTypes();
  if (before.length < 2) { t.ok(true, 'видов меньше двух — пропущено'); return; }
  const saved = await snapshot('duty.duty_types');

  try {
    const wanted = [...before].reverse().map((x) => x.id);
    const moved = await send('/duty-types/order', { ids: wanted.map(String) });
    t.is(moved.status, 200, 'порядок видов сохранен');
    t.is((await duty.listDutyTypes()).map((x) => x.id).join(','), wanted.join(','),
      'виды идут в новом порядке');

    const partial = await send('/duty-types/order', { ids: wanted.slice(1).map(String) });
    t.is(partial.status, 400, 'неполный перечень не принимается');
    t.is((await duty.listDutyTypes()).map((x) => x.id).join(','), wanted.join(','),
      'отказ порядок не тронул');
  } finally {
    await restore('duty.duty_types', saved);
  }
};

/** Пост, перенесенный в другой вид, встает в конец нового вида. */
exports.перенос_поста_в_конец_вида = async (t, ctx) => {
  if (!ctx.alive) { t.ok(true, 'приложение не запущено — пропущено'); return; }
  const { post: send } = require('../lib');

  const types = await duty.listDutyTypes();
  const [from, to] = [types.find((x) => x.code === 'SN'), types.find((x) => x.code === 'OD')];
  const name = `Пост порядка ${Date.now()}`;

  try {
    await send('/posts', { dutyTypeId: String(from.id), name });
    const fresh = (await duty.listAllPosts()).find((p) => p.name === name);
    t.ok(Boolean(fresh), 'пост заведен');
    if (!fresh) return;

    let list = await duty.listPosts(from.id);
    t.is(list[list.length - 1].id, fresh.id, 'новый пост — в конце своего вида');

    await send(`/posts/${fresh.id}`, { dutyTypeId: String(to.id), name, isActive: 'on' });
    list = await duty.listPosts(to.id);
    t.is(list[list.length - 1].id, fresh.id, 'перенесенный — в конце нового вида');
  } finally {
    await db.query('DELETE FROM duty.duty_posts WHERE name = $1', [name]);
  }
};

/** Подразделения: переставляются соседи одного вышестоящего. */
exports.порядок_подразделений = async (t, ctx) => {
  if (!ctx.alive) { t.ok(true, 'приложение не запущено — пропущено'); return; }
  const { get, post: send } = require('../lib');

  // Вышестоящее с несколькими вложенными — по свойству, а не по названию.
  const { rows: parents } = await db.query(`
    SELECT parent_id AS id FROM core.units WHERE parent_id IS NOT NULL
    GROUP BY parent_id HAVING count(*) > 1 ORDER BY count(*) DESC LIMIT 1
  `);
  if (parents.length === 0) { t.ok(true, 'подходящего подразделения нет — пропущено'); return; }
  const parent = parents[0].id;

  const children = async () => (await db.query(
    'SELECT id FROM core.units WHERE parent_id = $1 ORDER BY sort_order, short_name', [parent],
  )).rows.map((r) => r.id);

  const saved = await snapshot('core.units', 'parent_id = $1', [parent]);
  const name = `Подразделение порядка ${Date.now()}`;

  try {
    const page = await get('/units');
    t.ok(page.body.includes(`data-sortable="/units/${parent}/order"`), 'вложенные — свой список');

    const wanted = (await children()).reverse();
    const moved = await send(`/units/${parent}/order`, { ids: wanted.map(String) });
    t.is(moved.status, 200, 'порядок сохранен');
    t.is((await children()).join(','), wanted.join(','), 'соседи идут в новом порядке');

    // Подразделение другого вышестоящего в этот список не входит.
    const { rows: stranger } = await db.query(
      'SELECT id FROM core.units WHERE parent_id IS DISTINCT FROM $1 LIMIT 1', [parent],
    );
    const refused = await send(`/units/${parent}/order`,
      { ids: [...wanted.slice(1), stranger[0].id].map(String) });
    t.is(refused.status, 400, 'чужое подразделение не переставляется');

    // Новое подразделение — в конец соседей.
    await send('/units', { parentId: String(parent), name, shortName: 'ПТ-порядок' });
    const after = await children();
    const { rows } = await db.query('SELECT id FROM core.units WHERE name = $1', [name]);
    t.is(after[after.length - 1], rows[0] && rows[0].id, 'новое подразделение — последним');
  } finally {
    await db.query('DELETE FROM core.units WHERE name = $1', [name]);
    await restore('core.units', saved);
  }
};

/** Направления допусков: порядок всего перечня. */
exports.порядок_направлений = async (t, ctx) => {
  if (!ctx.alive) { t.ok(true, 'приложение не запущено — пропущено'); return; }
  const { post: send } = require('../lib');

  const names = [`Направление А ${Date.now()}`, `Направление Б ${Date.now()}`];
  // Переставляются соседи одного уровня — здесь верхние направления.
  const order = async () => (await db.query(
    'SELECT id, name FROM personnel.permit_directions WHERE parent_id IS NULL ORDER BY sort_order, name',
  )).rows;
  const saved = await snapshot('personnel.permit_directions');

  try {
    for (const name of names) await send('/permits/directions', { name });
    const list = await order();
    t.is(list.slice(-2).map((d) => d.name).join('|'), names.join('|'), 'новые — в конце, по порядку');

    const wanted = [...list].reverse().map((d) => d.id);
    const moved = await send('/permits/directions/within/root/order', { ids: wanted.map(String) });
    t.is(moved.status, 200, 'порядок сохранен');
    t.is((await order()).map((d) => d.id).join(','), wanted.join(','), 'направления в новом порядке');

    const doubled = await send('/permits/directions/within/root/order',
      { ids: [...wanted.slice(1), wanted[1]].map(String) });
    t.is(doubled.status, 400, 'повтор не принимается');
  } finally {
    await db.query('DELETE FROM personnel.permit_directions WHERE name = ANY($1)', [names]);
    await restore('personnel.permit_directions', saved);
  }
};

/** Вкладки видов нарядов в графике — перетаскиванием, порядок хранится в базе. */
exports.порядок_вкладок_графика = async (t, ctx) => {
  if (!ctx.alive) { t.ok(true, 'приложение не запущено — пропущено'); return; }
  const { get, post: send } = require('../lib');

  const before = await duty.listDutyTypes();
  if (before.length < 2) { t.ok(true, 'видов меньше двух — пропущено'); return; }
  const saved = await snapshot('duty.duty_types');
  try {
    const page = await get('/duties');
    t.ok(/<nav class="tabs duty-type-tabs" data-sortable="\/duty-types\/order" data-sort-whole/.test(page.body),
      'вкладки видов в графике перетаскиваются — за само название');
    t.ok(before.every((x) => page.body.includes(`data-sort-id="${x.id}" draggable="true"`)), 'каждая вкладка — элемент списка');
    const nav = page.body.slice(page.body.indexOf('duty-type-tabs'), page.body.indexOf('</nav>', page.body.indexOf('duty-type-tabs')));
    t.is(nav.includes('drag-handle'), false, 'без значка «⠿»');

    const wanted = [...before].reverse().map((x) => x.id);
    const moved = await send('/duty-types/order', { ids: wanted.map(String) });
    t.is(moved.status, 200, 'новый порядок сохранен');

    const again = await get('/duties');
    const shown = [...again.body.matchAll(/<a [^>]*data-sort-id="(\d+)"[^>]*class="tab/g)].map((m) => Number(m[1]));
    t.is(shown.join(','), wanted.join(','), 'после перезагрузки вкладки — в новом порядке');
  } finally {
    await restore('duty.duty_types', saved);
  }
};
