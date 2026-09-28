'use strict';

// Оргструктура и область видимости.
//
// Подразделения вложены: часть — рота — взвод — отделение. Из вложенности
// следует и порядок доступа: за пользователем закрепляется ОДНО
// подразделение, а ведет он его вместе со всем поддеревом. Командир взвода
// отвечает за свои отделения, командир роты — за взводы вместе с их
// отделениями, и отдельного перечисления для этого не требуется.
//
// Пользователь без закрепленного подразделения (администратор, заместитель,
// начальник службы) видит всю часть.

const queries = require('./queries');
const v = require('../../lib/validation');

/**
 * Подразделения, доступные пользователю.
 *
 * @returns {?number[]} null — доступна вся часть
 */
async function scopeIds(user) {
  if (!user || !user.scope_unit_id) return null;
  return queries.subtreeIds(user.scope_unit_id);
}

/** Входит ли подразделение в область видимости пользователя. */
async function inScope(user, unitId) {
  const ids = await scopeIds(user);
  return ids === null || ids.includes(Number(unitId));
}

async function assertInScope(user, unitId, what = 'подразделение') {
  if (!await inScope(user, unitId)) {
    v.fail(`Это ${what} не входит в закрепленное за вами подразделение.`, 403);
  }
}

/**
 * Дерево подразделений.
 *
 * Строится из плоского перечня: рекурсивный запрос уже вернул нужные строки,
 * и второй проход по БД ради вложенности не нужен. Пользователю показывается
 * его поддерево, а корнем дерева становится закрепленное подразделение.
 */
async function tree(user) {
  const ids = await scopeIds(user);
  const units = await queries.listUnits(ids);

  const byId = new Map(units.map((u) => [u.id, { ...u, children: [] }]));
  const roots = [];

  for (const unit of byId.values()) {
    const parent = unit.parent_id ? byId.get(unit.parent_id) : null;
    if (parent) parent.children.push(unit);
    else roots.push(unit);
  }

  return roots;
}

/** Плоский перечень доступных подразделений — для выпадающих списков. */
async function listUnits(user) {
  return queries.listUnits(await scopeIds(user));
}

async function getUnit(id) {
  return queries.getUnit(v.id(id));
}

async function path(id) {
  return queries.path(v.id(id));
}

const NAME_LIMIT = 120;

function checkNames(name, shortName) {
  if (!String(name || '').trim()) v.fail('Укажите наименование подразделения.');
  if (!String(shortName || '').trim()) v.fail('Укажите краткое наименование.');
  if (String(name).length > NAME_LIMIT || String(shortName).length > NAME_LIMIT) {
    v.fail(`Наименование длиннее ${NAME_LIMIT} знаков.`);
  }
}

/**
 * Новое подразделение внутри существующего.
 *
 * Родитель обязателен: подразделение вне структуры не принадлежит никому, и
 * область видимости для него не определена. Корень заведен начальным
 * наполнением и остается единственным.
 */
async function createUnit(user, { parentId, name, shortName, sortOrder }) {
  const parent = v.id(parentId);
  await assertInScope(user, parent, 'вышестоящее подразделение');
  checkNames(name, shortName);

  if (!await queries.getUnit(parent)) v.fail('Вышестоящее подразделение не найдено.', 404);

  const unitId = await queries.createUnit({
    parentId: parent,
    name: String(name).trim(),
    shortName: String(shortName).trim(),
    sortOrder: sortOrder === undefined || sortOrder === '' ? null : Number(sortOrder) || 0,
  });

  // У каждого подразделения сразу есть командирская должность: командир
  // следует из штата. Наименование общее — кадровик переименует щелчком.
  const command = await queries.createPosition(unitId, 'Командир подразделения');
  await queries.setCommanderPosition(command);
  return unitId;
}

/**
 * Правка подразделения, включая перенос в другое вышестоящее.
 *
 * Перенос в собственное поддерево запрещен: подразделение стало бы предком
 * самому себе, и обход дерева никогда бы не кончился.
 */
async function updateUnit(user, id, { name, shortName, sortOrder, parentId, isActive }) {
  const unitId = v.id(id);
  const unit = await queries.getUnit(unitId);
  if (!unit) v.fail('Подразделение не найдено.', 404);

  await assertInScope(user, unitId);
  checkNames(name, shortName);

  let parent = unit.parent_id;
  if (parentId !== undefined && parentId !== null && String(parentId) !== '') {
    parent = v.id(parentId);
    await assertInScope(user, parent, 'вышестоящее подразделение');

    if (parent === unitId) v.fail('Подразделение не может быть вложено само в себя.');
    const own = await queries.subtreeIds(unitId);
    if (own.includes(parent)) v.fail('Нельзя перенести подразделение внутрь его собственного.');
  }

  // Корень остается корнем: часть никуда не вкладывается.
  if (unit.parent_id === null) parent = null;

  await queries.updateUnit(unitId, {
    name: String(name).trim(),
    shortName: String(shortName).trim(),
    sortOrder: sortOrder === undefined || sortOrder === '' ? null : Number(sortOrder) || 0,
    parentId: parent,
    isActive: isActive !== false,
  });
}

/**
 * Порядок вложенных подразделений — перетаскиванием в дереве. Переставляются
 * только соседи одного вышестоящего; перенос в другое — полем «Входит в».
 * В этом порядке подразделения идут везде: в дереве, строевой записке,
 * выпадающих списках.
 */
async function reorderChildren(user, parentId, rawIds) {
  const parent = v.id(parentId);
  await assertInScope(user, parent);
  await queries.setChildOrder(parent, v.order(rawIds, await queries.childIds(parent)));
}


/**
 * Удаление подразделения.
 *
 * Удалить можно только то, за что ничего не держится. Подразделение с людьми
 * или с историей нарядов ВЫВОДИТСЯ ИЗ ПРИМЕНЕНИЯ признаком: прошлые наряды
 * обязаны сохранять ссылку на подразделение, по которому люди фактически
 * несли службу, и удаление разорвало бы историю.
 */
async function removeUnit(user, id) {
  const unitId = v.id(id);
  const unit = await queries.getUnit(unitId);
  if (!unit) v.fail('Подразделение не найдено.', 404);
  if (unit.parent_id === null) v.fail('Войсковую часть удалить нельзя.');

  await assertInScope(user, unitId);

  const held = await queries.usage(unitId);
  const reasons = [];
  if (held.children) reasons.push(`вложенных подразделений ${held.children}`);
  if (held.employees) reasons.push(`сотрудников ${held.employees}`);
  if (held.duties) reasons.push(`нарядов ${held.duties}`);
  if (held.posts) reasons.push(`постов ${held.posts}`);
  if (held.responsibilities) reasons.push(`закреплений за нарядами ${held.responsibilities}`);
  if (held.users) reasons.push(`учетных записей ${held.users}`);

  if (reasons.length > 0) {
    v.fail(`Удалить нельзя: ${reasons.join(', ')}. `
      + 'Выведите подразделение из применения — история нарядов обязана сохранять ссылку на него.');
  }

  await queries.deleteUnit(unitId);
}

// ----------------------------------------------------------------------------
// Штат и перевод
//
// Должности ведет только кадровик и администратор (staff.manage). Переводит
// людей право «Распределение личного состава» — но только в пределах своего
// подразделения: и откуда, и куда должны входить в область видимости.
// Кадровик и администратор закреплены за всей частью — им доступно всё.
// ----------------------------------------------------------------------------

const can = (user, action) => Boolean(user && user.permissions && user.permissions.has(action));

function mustManageStaff(user) {
  if (!can(user, 'staff.manage')) v.fail('Должности ведет только кадровик.', 403);
}

function checkTitle(title) {
  const text = String(title || '').trim();
  if (!text) v.fail('Укажите наименование должности.');
  if (text.length > NAME_LIMIT) v.fail(`Наименование длиннее ${NAME_LIMIT} знаков.`);
  return text;
}

/**
 * «Командир …» — командирская, если у подразделения командирской еще нет:
 * так ее и заводят, и забытая галочка не должна оставлять подразделение
 * со старым командиром (а приказ — со старой подписью).
 */
const COMMANDER_TITLE = /^командир/i;
async function flagIfCommanderTitle(positionId, unitId, title) {
  if (COMMANDER_TITLE.test(title) && !await queries.hasCommanderPosition(unitId)) {
    await queries.setCommanderPosition(positionId);
  }
}

async function addPosition(user, unitId, title) {
  mustManageStaff(user);
  const unit = v.id(unitId);
  await assertInScope(user, unit);
  if (!await queries.getUnit(unit)) v.fail('Подразделение не найдено.', 404);
  const text = checkTitle(title);
  const id = await queries.createPosition(unit, text);
  await flagIfCommanderTitle(id, unit, text);
  return id;
}

async function renamePosition(user, positionId, title) {
  mustManageStaff(user);
  const position = await queries.getPosition(v.id(positionId));
  if (!position) v.fail('Должность не найдена.', 404);
  await assertInScope(user, position.unit_id);
  await queries.renamePosition(position.id, checkTitle(title));
}

/**
 * Настройка должности из ее строки: наименование и отметка командирской.
 * isCommander: true — сделать командирской, false — снять отметку,
 * undefined — не трогать.
 */
async function updatePosition(user, positionId, { title, isCommander }) {
  mustManageStaff(user);
  const position = await queries.getPosition(v.id(positionId));
  if (!position) v.fail('Должность не найдена.', 404);
  await assertInScope(user, position.unit_id);
  const text = checkTitle(title);
  if (text !== position.title) await queries.renamePosition(position.id, text);
  if (isCommander === true && !position.is_commander) await queries.setCommanderPosition(position.id);
  if (isCommander === false && position.is_commander) await queries.clearCommanderPosition(position.id);
  if (isCommander === undefined && text !== position.title) {
    await flagIfCommanderTitle(position.id, position.unit_id, text);
  }
}

/** Отметить должность командирской: ее занимающий становится командиром. */
async function setCommanderPosition(user, positionId) {
  mustManageStaff(user);
  const position = await queries.getPosition(v.id(positionId));
  if (!position) v.fail('Должность не найдена.', 404);
  await assertInScope(user, position.unit_id);
  await queries.setCommanderPosition(position.id);
}

/**
 * Должность «в корзину»: удаляется; занимавший ее уходит за штат (остается
 * в подразделении без должности). Командирская — вместе с командирством.
 */
async function removePosition(user, positionId) {
  mustManageStaff(user);
  const position = await queries.getPosition(v.id(positionId));
  if (!position) v.fail('Должность не найдена.', 404);
  await assertInScope(user, position.unit_id);
  await queries.deletePosition(position.id);
  return position;
}

/** Человек «в корзину» — за штат: должность освобождается. Ведет кадровик. */
async function releaseEmployee(user, employeeId) {
  mustManageStaff(user);
  const employee = v.id(employeeId);
  const row = await queries.employeeRow(employee);
  if (!row) v.fail('Сотрудник не найден.', 404);
  if (row.unit_id === null) return false;  // уже за штатом
  await assertInScope(user, row.unit_id, 'подразделение сотрудника');
  const position = await queries.positionOf(employee);
  if (!position) return false;
  await queries.releaseEmployee(employee);
  return position;
}

/** Перенос должности в другое подразделение — вместе с тем, кто ее занимает. */
async function movePosition(user, positionId, unitId) {
  mustManageStaff(user);
  const position = await queries.getPosition(v.id(positionId));
  if (!position) v.fail('Должность не найдена.', 404);
  const target = v.id(unitId);
  await assertInScope(user, position.unit_id);
  await assertInScope(user, target, 'подразделение назначения');
  if (!await queries.getUnit(target)) v.fail('Подразделение не найдено.', 404);
  if (position.unit_id === target) return false;
  await queries.movePosition(position.id, target);
  return true;
}

/** Порядок должностей подразделения — перетаскиванием за «⠿». */
async function reorderPositions(user, unitId, rawIds) {
  mustManageStaff(user);
  const unit = v.id(unitId);
  await assertInScope(user, unit);
  const own = (await queries.listPositions([unit])).map((p) => p.id);
  await queries.setPositionOrder(unit, v.order(rawIds, own));
}

/**
 * За штатом — люди вне всех подразделений. Видит их тот, чья зона — вся
 * часть (кадровик, администратор): у командира за штатом людей нет.
 */
async function unplaced(user) {
  return (await scopeIds(user)) === null ? queries.unplacedEmployees() : [];
}

/**
 * Перевод человека на вакантную должность — в том же подразделении или в
 * другом. Командир — только внутри своего подразделения; кадровик — любого.
 */
async function transferEmployee(user, employeeId, positionId) {
  if (!can(user, 'personnel.assign') && !can(user, 'staff.manage')) {
    v.fail('Нет права переводить личный состав.', 403);
  }
  const employee = v.id(employeeId);
  const position = await queries.getPosition(v.id(positionId));
  if (!position) v.fail('Должность не найдена.', 404);

  const row = await queries.employeeRow(employee);
  if (!row) v.fail('Сотрудник не найден.', 404);

  // За штатом (без подразделения) берут на должность только с зоной всей
  // части — кадровик или администратор.
  if (row.unit_id === null) {
    if ((await scopeIds(user)) !== null) v.fail('Человек за штатом: на должность его назначает кадровик.', 403);
  } else {
    await assertInScope(user, row.unit_id, 'подразделение сотрудника');
  }
  await assertInScope(user, position.unit_id, 'подразделение назначения');

  if (position.employee_id === employee) return false;
  if (position.employee_id) v.fail('Должность занята: выберите вакантную.');

  await queries.occupyPosition(employee, position.id);
  return true;
}

/** Вакантные должности в пределах области видимости — для выбора при переводе. */
async function vacantPositions(user) {
  const units = await queries.listUnits(await scopeIds(user));
  const byId = new Map(units.map((u) => [u.id, u]));
  return (await queries.listPositions(units.map((u) => u.id)))
    .filter((p) => !p.employee_id)
    .map((p) => ({ id: p.id, unit_id: p.unit_id, title: p.title,
      unit: (byId.get(p.unit_id) || {}).path_name || (byId.get(p.unit_id) || {}).short_name }));
}

async function positionOf(employeeId) {
  return queries.positionOf(v.id(employeeId));
}

// ----------------------------------------------------------------------------
// ВРИО командира
//
// Назначает кадровик (и администратор) на период — обычно отсутствие
// командира — из людей подразделения и вложенных (у командира части — любой
// человек части). Система предлагает самого старшего: сначала в самом
// подразделении, если там никого — на ближайшем вложенном уровне и глубже.
// ----------------------------------------------------------------------------

const declension = require('../../lib/declension');
const today = () => {
  const d = new Date();
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
};
const plusDays = (key, n) => {
  const [y, m, d] = key.split('-').map(Number);
  const x = new Date(y, m - 1, d + n, 12);
  return `${x.getFullYear()}-${String(x.getMonth() + 1).padStart(2, '0')}-${String(x.getDate()).padStart(2, '0')}`;
};

/** Кандидаты во ВРИО и предложение системы — первый из них. */
async function actingPanel(user, unitId) {
  mustManageStaff(user);
  const unit = v.id(unitId);
  await assertInScope(user, unit);
  const [candidates, acting, post] = await Promise.all([
    queries.actingCandidates(unit), queries.listActing([unit]), queries.commanderPost(unit),
  ]);
  const absence = post && post.id ? await queries.nextAbsence(post.id) : null;
  return {
    candidates: candidates.map((c) => ({ id: c.id, label: `${c.short_name} — ${c.unit_short}` })),
    suggested: candidates[0] ? candidates[0].id : null,
    acting,
    commander: post && post.id ? post.short_name : null,
    // Даты по умолчанию — ближайшее отсутствие командира, иначе неделя.
    dateFrom: absence ? absence.date_from : today(),
    dateTo: absence && absence.date_to !== 'infinity' ? absence.date_to : plusDays(absence ? absence.date_from : today(), 6),
  };
}

async function assignActing(user, { unitId, employeeId, dateFrom, dateTo, reason }, userId) {
  mustManageStaff(user);
  const unit = v.id(unitId);
  await assertInScope(user, unit);
  v.date(dateFrom);
  v.date(dateTo);
  if (dateTo < dateFrom) v.fail('Окончание раньше начала.');
  const employee = v.id(employeeId);
  const candidates = await queries.actingCandidates(unit);
  if (!candidates.some((c) => c.id === employee)) {
    v.fail('ВРИО выбирается из людей этого подразделения и вложенных (кроме самого командира).');
  }
  if (await queries.actingOverlaps(unit, dateFrom, dateTo)) {
    v.fail('На эти даты ВРИО уже назначен: сначала отмените прежнего.');
  }
  return queries.createActing({ unitId: unit, employeeId: employee, dateFrom, dateTo,
    reason: String(reason || '').trim(), userId });
}

async function cancelActing(user, actingId) {
  mustManageStaff(user);
  const acting = await queries.getActing(v.id(actingId));
  if (!acting) v.fail('Назначение ВРИО не найдено.', 404);
  await assertInScope(user, acting.unit_id);
  await queries.cancelActing(acting.id);
  return acting;
}

/**
 * Кто подписывает за подразделение на дату. Командир — если на месте; если
 * он отсутствует или должность вакантна — назначенный ВРИО, а без него —
 * предложенный системой (самый старший). title — должность подписанта.
 */
async function signerOn(unitId, date) {
  const post = await queries.commanderPost(unitId);
  const title = post ? post.title : 'Командир';
  const commander = post && post.id ? post : null;
  if (commander && !await queries.absentOn(commander.id, date)) {
    return { person: commander, title, acting: false };
  }
  const acting = await queries.actingOn(unitId, date) || (await queries.actingCandidates(unitId))[0] || null;
  if (acting) return { person: acting, title: declension.actingTitle(title), acting: true };
  return commander ? { person: commander, title, acting: false } : null;
}

/** Подписанты приказа на дату: командир части и под ним начальник штаба. */
async function orderSigners(date) {
  const [root, hq] = await Promise.all([queries.rootUnitRow(), queries.headquartersRow()]);
  return {
    unit: root ? root.name : '',
    commander: root ? await signerOn(root.id, date) : null,
    chief: hq ? await signerOn(hq.id, date) : null,
  };
}

/** Где человек — ВРИО командира сегодня (для прав). */
async function actingUnitToday(employeeId) {
  return employeeId ? queries.actingUnitOf(employeeId, today()) : null;
}

/**
 * Дерево личного состава: подразделения вместе с людьми в каждом.
 *
 * Показывается поддерево пользователя целиком, чтобы командир роты видел и
 * взводы, и отделения, и людей в них — а не только ближайший уровень.
 */
async function personnelTree(user) {
  const ids = await scopeIds(user);
  const units = await queries.listUnits(ids);
  const employees = await queries.employeesIn(units.map((u) => u.id));

  const byUnit = new Map();
  for (const employee of employees) {
    if (!byUnit.has(employee.unit_id)) byUnit.set(employee.unit_id, []);
    byUnit.get(employee.unit_id).push(employee);
  }

  // Штат: должности по порядку, вакантные — пустыми строками; люди без
  // должности (заведенные вне штата) — отдельно, чтобы не потерялись.
  const positions = await queries.listPositions(units.map((u) => u.id));
  const byUnitPositions = new Map();
  for (const position of positions) {
    if (!byUnitPositions.has(position.unit_id)) byUnitPositions.set(position.unit_id, []);
    byUnitPositions.get(position.unit_id).push(position);
  }
  const placed = new Set(positions.map((p) => p.employee_id).filter(Boolean));

  const byId = new Map(units.map((u) => [u.id, {
    ...u, children: [], employees: byUnit.get(u.id) || [],
    positions: byUnitPositions.get(u.id) || [],
    unplaced: (byUnit.get(u.id) || []).filter((e) => !placed.has(e.id)),
  }]));

  const roots = [];
  for (const unit of byId.values()) {
    const parent = unit.parent_id ? byId.get(unit.parent_id) : null;
    if (parent) parent.children.push(unit);
    else roots.push(unit);
  }

  return roots;
}

/** Поддерево подразделения: оно само и все вложенные. */
async function subtreeIds(unitId) {
  return queries.subtreeIds(v.id(unitId));
}

module.exports = {
  reorderChildren,
  scopeIds,
  subtreeIds,
  inScope,
  assertInScope,
  tree,
  listUnits,
  getUnit,
  path,
  createUnit,
  updateUnit,
  removeUnit,
  addPosition,
  renamePosition,
  removePosition,
  movePosition,
  releaseEmployee,
  reorderPositions,
  unplaced,
  setCommanderPosition,
  updatePosition,
  transferEmployee,
  vacantPositions,
  positionOf,
  personnelTree,
  actingPanel,
  assignActing,
  cancelActing,
  signerOn,
  orderSigners,
  actingUnitToday,
  cancelActingOf: (employeeId) => queries.cancelActingOf(v.id(employeeId)),
};

// Проверка поддерева и изменение должны видеть одну структуру: два
// одновременных переноса иначе могут создать цикл A -> B -> A.
for (const name of ['createUnit', 'updateUnit', 'removeUnit', 'addPosition',
  'renamePosition', 'removePosition', 'transferEmployee', 'setCommanderPosition',
  'movePosition', 'reorderPositions', 'updatePosition', 'releaseEmployee']) {
  const fn = module.exports[name];
  module.exports[name] = (...args) => require('../../db/pool').transaction(() => fn(...args));
}
