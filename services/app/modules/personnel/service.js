'use strict';

// Публичный интерфейс модуля «Личный состав».
//
// ЭТО ЕДИНСТВЕННАЯ ДВЕРЬ МОДУЛЯ. Другие модули обращаются только сюда и
// никогда напрямую в queries.js. При выделении МС-1 в отдельный сервис
// изменится реализация этого файла — вызовы функций станут HTTP-запросами,
// а вызывающий код останется прежним.

const queries = require('./queries');
const v = require('../../lib/validation');
const db = require('../../db/pool');
const cal = require('../duty/calendar');
const documents = require('../../lib/documents');

/** Отображаемое имя: «м-р Иванов И.И.» */
function shortName(employee) {
  const initials = [employee.first_name, employee.middle_name]
    .filter(Boolean)
    .map((part) => `${part[0]}.`)
    .join('');
  const rank = employee.rank_short ? `${employee.rank_short} ` : '';
  return `${rank}${employee.last_name} ${initials}`.trim();
}

/** Полное имя без звания: «Иванов Иван Иванович» */
function fullName(employee) {
  return [employee.last_name, employee.first_name, employee.middle_name]
    .filter(Boolean)
    .join(' ');
}

function decorate(employee) {
  return { ...employee, short_name: shortName(employee), full_name: fullName(employee) };
}

async function countActive(unitIds = null) {
  return queries.countActive(unitIds);
}

async function listEmployees() {
  return (await queries.listEmployees()).map(decorate);
}

async function getByIds(ids) {
  return (await queries.listByIds(ids)).map(decorate);
}

/**
 * Сотрудники, доступные к привлечению на дату и имеющие все общие допуски.
 * @param {string} onDate — дата в формате YYYY-MM-DD
 * @param {number[]} generalPermitTypeIds — виды общих допусков
 */
async function findAvailable(onDate, generalPermitTypeIds) {
  return (await queries.findAvailable({ onDate, generalPermitTypeIds })).map(decorate);
}

/**
 * Кандидаты, сгруппированные по постам.
 *
 * @param {string}   onDate
 * @param {number[]} generalPermitTypeIds
 * @param {number[]} postIds
 * @returns {Map<number, object[]>} пост → список кандидатов
 */
async function findCandidatesForPosts(onDate, generalPermitTypeIds, posts, startsAt, endsAt) {
 const rows=await queries.findCandidatesForPosts({onDate,generalPermitTypeIds,posts,startsAt,endsAt});
 const byPost=new Map(posts.map(p=>[p.id,[]]));
 for(const row of rows) {const {post_id,...employee}=row;byPost.get(post_id).push(decorate(employee));}
 return byPost;
}

async function listAbsentOn(onDate) {
  return (await queries.listAbsentOn(onDate)).map(decorate);
}

/**
 * Отметка об отсутствии.
 *
 * Используется в том числе при снятии человека с наряда: привлечение к
 * работам, которых в системе нет, оформляется отсутствием категории «прочее»
 * с указанием приказа-основания. Отдельного механизма недоступности не
 * заводится — иначе человека можно было бы исключить двумя способами,
 * и строевая записка учитывала бы только один из них.
 */
async function addAbsence(data) {
  return queries.addAbsence(data);
}

// Отсутствие вперед заводится не дальше чем на год: приказ на больший срок
// не выпускают, а опечатка в годе иначе прячет человека навсегда.
const AHEAD_LIMIT_DAYS = 366;

/**
 * Отметка об отсутствии, внесенная человеком.
 *
 * Проверки здесь, а не в форме: то же самое будет заводить разбор приказа
 * (МС-3), и правила должны быть общими. Поэтому же у записи хранится
 * ПРОИСХОЖДЕНИЕ — «внесено человеком» или «разобрано из приказа»: два
 * источника не должны молча затирать друг друга.
 */
async function recordAbsence({ employeeId, typeCode, dateFrom, dateTo, documentRef, note,
  userId, source, openEnded, orderId }) {
  v.id(employeeId);
  v.date(dateFrom);
  // Без срока окончания (командировка «до особого распоряжения»): хранится
  // как бесконечная дата — сравнения и наложения работают как обычно, и на
  // любую будущую дату человек отсутствует. Завершается — «завершить».
  if (openEnded) dateTo = 'infinity';
  else v.date(dateTo);

  // Приказ из реестра («Приказы» → «Отсутствия»): основание — его реквизиты.
  let order = null;
  if (orderId) {
    order = await queries.getOrder(v.id(orderId));
    // «Прочий» приказ (караул и т. п.) тоже основание — по его виду.
    if (!order || !['absence', 'other'].includes(order.kind)) v.fail('Выберите приказ об отсутствии из реестра.');
    if (!String(documentRef || '').trim()) {
      const [y, m, d] = order.issued_on.split('-');
      documentRef = `приказ № ${order.number} от ${d}.${m}.${y}`;
    }
  }

  const types = await queries.listAbsenceTypes();
  const type = types.find((t) => t.code === typeCode);
  if (!type) v.fail('Выберите категорию отсутствия.');

  if (dateTo < dateFrom) v.fail('Дата окончания раньше даты начала.');

  const limit = new Date(Date.now() + AHEAD_LIMIT_DAYS * 86400000).toISOString().slice(0, 10);
  if (dateFrom > limit) v.fail('Отсутствие заводится не дальше чем на год вперед.');

  // Наложение — почти всегда опечатка в датах. Отказ с указанием того, что
  // мешает, разбирается за секунду; молча принятая вторая запись дала бы
  // человека, отсутствующего по двум причинам сразу.
  const overlap = await queries.overlappingAbsences(employeeId, dateFrom, dateTo);
  if (overlap.length > 0) {
    const first = overlap[0];
    v.fail(`На эти даты уже есть запись: ${first.reason} с ${first.date_from} по ${first.date_to}.`);
  }

  return queries.addAbsence({
    employeeId, typeCode, dateFrom, dateTo, documentRef, note,
    createdBy: userId || null, source: source || 'manual', orderId: order ? order.id : null,
  });
}

/**
 * Прекратить отсутствие досрочно (любое, в том числе бессрочное): новая
 * дата окончания — не раньше начала и не позже прежнего окончания. Это не
 * «снять»: отсутствие было, просто закончилось раньше, и история остается.
 */
async function endAbsence(id, dateTo) {
  const absence = await queries.getAbsence(v.id(id));
  if (!absence) v.fail('Запись об отсутствии не найдена.', 404);
  if (absence.cancelled_at) v.fail('Запись снята.');
  v.date(dateTo);
  if (dateTo < absence.date_from) v.fail('Дата окончания раньше начала отсутствия.');
  if (absence.date_to !== 'infinity' && dateTo > absence.date_to) {
    v.fail('Досрочно — значит раньше прежнего окончания. Продлить — новой записью.');
  }
  await queries.setAbsenceEnd(absence.id, dateTo);
  return absence;
}

/** Снятие записи об отсутствии — пометкой, основание сохраняется. */
async function cancelAbsence(id, userId) {
  const absence = await queries.getAbsence(v.id(id));
  if (!absence) v.fail('Запись об отсутствии не найдена.', 404);
  if (absence.cancelled_at) v.fail('Запись уже снята.');

  await queries.cancelAbsence(absence.id, userId);
  return absence;
}

async function listAbsencesFor(employeeId, from, to) {
  return queries.listAbsencesFor(employeeId, from, to);
}

/**
 * Проверка уже назначенных: кто не пригоден к своему посту на дату
 * заступления. Условия меняются после назначения — истекает допуск, человек
 * уходит в отпуск, — а назначение остается, и наряд выглядит полным.
 */
async function findUnfitAssignments(items, generalPermitTypeIds) {
  return queries.findUnfitAssignments(items, generalPermitTypeIds);
}


/**
 * Оружие человека: закрепленное и переданное во временное пользование.
 */
async function weaponsOf(employeeId) {
  return queries.weaponsOfEmployee(v.id(employeeId));
}

/**
 * Постоянное закрепление оружия за человеком.
 *
 * Оружие закрепляется за ОДНИМ владельцем: два владельца у одного автомата —
 * это спор о том, с кого спрашивать. Закрепить уже закрепленное нельзя,
 * сначала его открепляют.
 */
async function assignWeapon(weaponId, employeeId) {
  const id = v.id(weaponId);
  const employee = v.id(employeeId);

  const weapon = await queries.getWeapon(id);
  if (!weapon) v.fail('Оружие не найдено.', 404);
  if (!weapon.is_active) v.fail('Это оружие выведено из применения.');

  if (weapon.owner_id && weapon.owner_id !== employee) {
    v.fail('Оружие уже закреплено за другим человеком. Сначала открепите его.');
  }

  const [person] = await getByIds([employee]);
  if (!person) v.fail('Человек не найден.', 404);

  await queries.setWeaponOwner(id, employee);
  return { weapon, person };
}

/**
 * Снятие закрепления.
 *
 * Оружие, переданное в наряд, не откремляется: пока оно на руках у другого,
 * снимать владельца значит терять того, с кого спрашивать при возврате.
 */
async function releaseWeapon(weaponId) {
  const id = v.id(weaponId);
  const weapon = await queries.getWeapon(id);
  if (!weapon) v.fail('Оружие не найдено.', 404);
  if (!weapon.owner_id) v.fail('Это оружие ни за кем не закреплено.');

  const loans = await queries.weaponLoans(id);
  if (loans.length > 0) {
    v.fail(`Оружие передано до ${loans[0].ends_at}. Открепить его можно после возврата.`);
  }

  await queries.setWeaponOwner(id, null);
  return weapon;
}

// ----------------------------------------------------------------------------
// Приказы на допуск (раздел 7.3)
//
// Каталог трехуровневый: НАПРАВЛЕНИЕ — ГОД — ПРИКАЗ. Направления заводит
// человек, годы система выводит из даты издания: год, заведенный руками,
// рано или поздно разойдется с датой в самом приказе.
// ----------------------------------------------------------------------------

/**
 * Дерево направлений с приказами, разложенными по годам.
 *
 * @returns {object[]} узлы: {id, name, children, years:[{year, orders}]}
 */
async function permitCatalog() {
  const [directions, orders] = await Promise.all([
    queries.listDirections(), queries.listOrders(null),
  ]);

  const byDirection = new Map();
  for (const order of orders) {
    if (!byDirection.has(order.direction_id)) byDirection.set(order.direction_id, []);
    byDirection.get(order.direction_id).push(order);
  }

  const nodes = new Map(directions.map((d) => ({
    ...d,
    children: [],
    years: [],
    total: 0,
  })).map((d) => [d.id, d]));

  for (const [directionId, list] of byDirection) {
    const node = nodes.get(directionId);
    if (!node) continue;

    const years = new Map();
    for (const order of list) {
      if (!years.has(order.year)) years.set(order.year, []);
      years.get(order.year).push(order);
    }

    node.years = [...years.entries()]
      .sort((a, b) => b[0] - a[0])
      .map(([year, items]) => ({ year, orders: items }));
  }

  const roots = [];
  for (const node of nodes.values()) {
    const parent = node.parent_id ? nodes.get(node.parent_id) : null;
    if (parent) parent.children.push(node);
    else roots.push(node);
  }

  // Число приказов во всем поддереве: свернутое направление должно говорить,
  // есть ли внутри что-нибудь.
  const count = (node) => {
    node.total = node.years.reduce((sum, y) => sum + y.orders.length, 0)
      + node.children.reduce((sum, child) => sum + count(child), 0);
    return node.total;
  };
  roots.forEach(count);

  return roots;
}

const NAME_LIMIT = 160;

async function createDirection({ parentId, name, sortOrder }) {
  const title = String(name || '').trim();
  if (!title) v.fail('Укажите наименование направления.');
  if (title.length > NAME_LIMIT) v.fail(`Наименование длиннее ${NAME_LIMIT} знаков.`);
  if (parentId) v.id(parentId);

  return queries.createDirection({ parentId: parentId || null, name: title, sortOrder });
}

/**
 * Порядок направлений — перетаскиванием в каталоге «Приказы → Допуски»:
 * переставляются соседи одного уровня (вложенные в одно направление или
 * верхние).
 */
async function reorderDirections(parentId, rawIds) {
  const parent = parentId === null ? null : v.id(parentId);
  await queries.setDirectionOrder(parent, v.order(rawIds, await queries.directionIdsWithin(parent)));
}

async function updateDirection(id, { name, sortOrder, isActive }) {
  const title = String(name || '').trim();
  if (!title) v.fail('Укажите наименование направления.');
  return queries.updateDirection(v.id(id), { name: title, sortOrder, isActive });
}

/**
 * Удаление направления.
 *
 * Направление с приказами не удаляется: приказ — документ, и терять его
 * вместе с папкой нельзя. Сначала переносятся приказы.
 */
async function removeDirection(id) {
  const directionId = v.id(id);
  const usage = await queries.directionUsage(directionId);

  if (usage.orders > 0) {
    v.fail(`В направлении ${usage.orders} приказ(ов). Перенесите их в другое направление.`);
  }
  if (usage.children > 0) {
    v.fail('Внутри есть вложенные направления. Сначала уберите их.');
  }

  return queries.deleteDirection(directionId);
}

/** Проверка сведений о приказе. */
function checkOrder(data, kind = 'permit') {
  const number = String(data.number || '').trim();
  if (!number) v.fail('Укажите номер приказа.');
  if (number.length > 40) v.fail('Номер длиннее 40 знаков.');

  v.date(data.issuedOn);
  // Направление (каталог) — только у приказа на допуск.
  if (kind === 'permit') v.id(data.directionId);

  const today = cal.dayKey(new Date());
  if (data.issuedOn > today) v.fail('Дата издания в будущем.');

  return {
    directionId: kind === 'permit' ? Number(data.directionId) : null,
    kind,
    number,
    issuedOn: data.issuedOn,
    title: String(data.title || '').trim() || null,
    note: String(data.note || '').trim() || null,
  };
}

/**
 * Заведение приказа вместе с файлом.
 *
 * Файл необязателен: приказ бывает известен раньше, чем доходит его скан, и
 * запретить завести его значит заставить ждать бумагу, чтобы отметить допуск.
 * Но приказ БЕЗ файла помечен, и это видно в перечне.
 */
async function createOrder(data, file, userId) {
  const kind = ['absence', 'other'].includes(data.kind) ? data.kind : 'permit';
  const checked = checkOrder(data, kind);
  // «Прочий» приказ — своего вида для разбора (караул и т. п.).
  if (kind === 'other') checked.profileId = v.id(data.profileId);
  const folder = { permit: 'permit-orders', absence: 'absence-orders', other: 'other-orders' }[kind];
  const stored = file ? await documents.store(file, `${folder}/${checked.issuedOn.slice(0, 4)}`) : null;

  try {
    return await queries.createOrder({ ...checked, file: stored, userId, source: data.source });
  } catch (err) {
    // Файл, оставшийся без записи, — мусор в хранилище.
    if (stored) {
      documents.remove(stored.filePath);
      if (stored.pdfPath && stored.pdfPath !== stored.filePath) documents.remove(stored.pdfPath);
    }
    throw err;
  }
}

async function updateOrder(id, data) {
  const orderId = v.id(id);
  const order = await queries.getOrder(orderId);
  if (!order) v.fail('Приказ не найден.', 404);
  const checked = checkOrder(data, order.kind);
  if (order.permits > 0 && (order.number !== checked.number
      || order.issued_on !== checked.issuedOn || order.direction_id !== checked.directionId)) {
    v.fail('Реквизиты приказа с выданными допусками изменять нельзя.');
  }
  return queries.updateOrder(orderId, checked);
}

/** Замена файла с очисткой новой версии при ошибке записи БД. */
async function replaceOrderFile(id, file, userId) {
  const orderId = v.id(id);
  const order = await queries.getOrder(orderId);
  if (!order) v.fail('Приказ не найден.', 404);
  if (!file || !file.data || file.data.length === 0) v.fail('Файл не приложен.');

  const stored = await documents.store(file, `permit-orders/${order.issued_on.slice(0, 4)}`);
  try {
    await db.transaction(async () => {
      if (!await queries.getOrder(orderId)) v.fail('Приказ не найден.', 404);
      await queries.setOrderFile(orderId, stored);
    });
  } catch (err) {
    documents.remove(stored.filePath);
    if (stored.pdfPath !== stored.filePath) documents.remove(stored.pdfPath);
    throw err;
  }

  // Прежние версии сохраняются для восстановления и согласованных резервных копий.

  return stored;
}

/**
 * Удаление приказа.
 *
 * Приказ, по которому выданы допуски, не удаляется: допуск без основания —
 * это допуск, выданный неизвестно кем. История отозванных допусков также сохраняется.
 */
async function removeOrder(id) {
  const orderId = v.id(id);
  const order = await queries.getOrder(orderId);
  if (!order) v.fail('Приказ не найден.', 404);

  if (order.permits > 0) {
    v.fail(`По приказу выдано допусков: ${order.permits}. Приказ сохраняется вместе с историей, включая отозванные допуски.`);
  }
  if (order.absences > 0) {
    v.fail(`По приказу отмечено отсутствий: ${order.absences}. Приказ сохраняется вместе с ними.`);
  }
  if (order.reservations > 0) {
    v.fail(`По приказу занято оружия: ${order.reservations}. Приказ сохраняется вместе с этим.`);
  }

  await queries.deleteOrder(orderId);
  // Файлы сохраняются для восстановления резервных копий.
  return order;
}

async function getOrder(id) {
  return queries.getOrder(v.id(id));
}

async function orderPermits(id) {
  return (await queries.orderPermits(v.id(id))).map(decorate);
}

/**
 * Выдача допуска по приказу.
 *
 * Пустой срок означает бессрочный допуск.
 */
async function grantPermit({ employeeId, permitTypeId, orderId, expiresAt, note }) {
  v.id(employeeId);
  v.id(permitTypeId);
  v.id(orderId);

  const order = await queries.getOrder(orderId);
  if (!order) v.fail('Приказ не найден.', 404);
  if (order.kind && !['permit', 'other'].includes(order.kind)) v.fail('Допуск выдается только по приказу на допуск.');

  const types = await queries.listAllPermitTypes();
  const type = types.find((t) => t.id === Number(permitTypeId));
  if (!type) v.fail('Неизвестный вид допуска.');

  // Допуск, оформляемый К ПОСТУ, приказом общего действия не выдается: у него
  // обязателен пост, и без него запись не примет сама база.
  if (type.is_post_specific) {
    v.fail(`«${type.name}» оформляется к конкретному посту, а не приказом на человека.`);
  }

  const [person] = await getByIds([employeeId]);
  if (!person) v.fail('Человек не найден.', 404);

  let until = expiresAt ? String(expiresAt) : null;
  if (until) v.date(until);
  if (until && until < order.issued_on) v.fail('Срок действия истекает раньше даты приказа.');

  const existing = await queries.listPermitsFor(employeeId, order.issued_on);
  if (existing.some((p) => p.permit_type_id === Number(permitTypeId)
      && p.order_id === Number(orderId))) {
    v.fail('Этот допуск уже выдан человеку по этому приказу.');
  }

  return queries.grantPermit({
    employeeId, permitTypeId, orderId, issuedAt: order.issued_on, expiresAt: until, note,
  });
}

/** Отзыв или приостановка допуска. */
async function setPermitStatus(id, status) {
  if (!['active', 'suspended', 'revoked'].includes(status)) v.fail('Неизвестное состояние допуска.');
  const permit = await queries.getPermit(v.id(id));
  if (!permit) v.fail('Допуск не найден.', 404);

  await queries.revokePermit(permit.id, status);
  return permit;
}

// ----------------------------------------------------------------------------
// Оружие по подразделениям — как штат
//
// Полный доступ (weapon.transfer, начальник службы вооружения и
// администратор): заведение, правка, списание, склад, любые подразделения.
// Закрепление (weapon.assign, командир): за людьми своего подразделения и
// перемещение между своими подразделениями. Зона — как у штата.
// ----------------------------------------------------------------------------

const hasRight = (user, action) => Boolean(user && user.permissions && user.permissions.has(action));
const fullWeapons = (user) => hasRight(user, 'weapon.transfer');
const org = () => require('../org/service');

function mustAssignWeapons(user) {
  if (!fullWeapons(user) && !hasRight(user, 'weapon.assign')) v.fail('Нет права распоряжаться оружием.', 403);
}
function mustManageWeapons(user) {
  if (!fullWeapons(user)) v.fail('Это делает начальник службы вооружения.', 403);
}

async function weaponOrFail(id) {
  const weapon = await queries.getWeaponRow(v.id(id));
  if (!weapon) v.fail('Оружие не найдено.', 404);
  return weapon;
}

/** Дерево подразделений зоны с оружием каждого и склад (при полном доступе). */
async function weaponTree(user) {
  const units = await org().listUnits(user);
  const ids = units.map((u) => u.id);
  const weapons = await queries.weaponsInUnits(ids);
  const byUnit = new Map();
  for (const w of weapons) {
    if (!byUnit.has(w.unit_id)) byUnit.set(w.unit_id, []);
    byUnit.get(w.unit_id).push(w);
  }
  const unarmed = new Map();
  for (const p of await queries.unarmedPeople(ids)) {
    if (!unarmed.has(p.unit_id)) unarmed.set(p.unit_id, []);
    unarmed.get(p.unit_id).push(p);
  }
  const nodes = new Map(units.map((u) => [u.id, { ...u, children: [],
    weapons: byUnit.get(u.id) || [], unarmed: unarmed.get(u.id) || [] }]));
  const roots = [];
  for (const node of nodes.values()) {
    const parent = node.parent_id ? nodes.get(node.parent_id) : null;
    if (parent) parent.children.push(node);
    else roots.push(node);
  }
  return { tree: roots, units, stock: fullWeapons(user) ? await queries.weaponsInStock() : [] };
}

async function addWeapon(user, { name, serialNumber, manufacturedOn, kind, unitId }) {
  mustManageWeapons(user);
  const data = checkWeapon({ name, serialNumber, manufacturedOn, kind });
  const unit = unitId ? v.id(unitId) : null;
  if (unit) await org().assertInScope(user, unit);
  return queries.createWeapon({ ...data, unitId: unit });
}

function checkWeapon({ name, serialNumber, manufacturedOn, kind }) {
  const title = String(name || '').trim();
  const serial = String(serialNumber || '').trim();
  if (!title || !serial) v.fail('Укажите наименование и заводской номер.');
  v.date(manufacturedOn);
  if (!['rifle', 'pistol'].includes(kind)) v.fail('Выберите вид оружия.');
  return { name: title, serialNumber: serial, manufacturedOn, kind };
}

/**
 * Перемещение: в другое подразделение или на склад (unitId пусто).
 * Закрепление за человеком снимается. Склад — только полным доступом.
 */
async function moveWeapon(user, weaponId, unitId) {
  mustAssignWeapons(user);
  const weapon = await weaponOrFail(weaponId);
  const target = unitId ? v.id(unitId) : null;
  if (weapon.unit_id === null || target === null) mustManageWeapons(user);
  if (weapon.unit_id !== null) await org().assertInScope(user, weapon.unit_id);
  if (target !== null) await org().assertInScope(user, target, 'подразделение назначения');
  if (weapon.unit_id === target) return false;
  await queries.moveWeapon(weapon.id, target);
  return true;
}

async function reorderWeapons(user, unitId, rawIds) {
  mustAssignWeapons(user);
  const unit = v.id(unitId);
  await org().assertInScope(user, unit);
  const own = (await queries.weaponsInUnits([unit])).map((w) => w.id);
  await queries.setWeaponOrder(unit, v.order(rawIds, own));
}

/**
 * Закрепить за человеком подразделения (или вложенного); пусто — снять
 * закрепление: оружие остается в подразделении за командиром.
 */
async function attachWeapon(user, weaponId, employeeId) {
  mustAssignWeapons(user);
  const weapon = await weaponOrFail(weaponId);
  if (weapon.unit_id === null) v.fail('Оружие на складе: сначала передайте его в подразделение.');
  await org().assertInScope(user, weapon.unit_id);
  const person = employeeId ? v.id(employeeId) : null;
  if (person !== null) {
    const people = await queries.peopleInSubtree(weapon.unit_id);
    if (!people.some((p) => p.id === person)) v.fail('Закрепить можно только за человеком этого подразделения.');
  }
  await queries.setWeaponOwner(weapon.id, person);
}

/**
 * Выдать оружие человеку перетаскиванием: оружие другого подразделения
 * (или со склада) сначала переезжает в подразделение человека — с теми же
 * правами, что и перемещение, — и закрепляется за ним.
 */
async function giveWeapon(user, weaponId, employeeId) {
  mustAssignWeapons(user);
  const weapon = await weaponOrFail(weaponId);
  const [person] = await getByIds([v.id(employeeId)]);
  if (!person || !person.unit_id) v.fail('Человек вне подразделений: сначала назначьте его на должность.');
  if (weapon.unit_id !== person.unit_id) await moveWeapon(user, weapon.id, person.unit_id);
  await attachWeapon(user, weapon.id, person.id);
}

async function editWeapon(user, weaponId, data) {
  mustManageWeapons(user);
  const weapon = await weaponOrFail(weaponId);
  await queries.updateWeapon(weapon.id, checkWeapon(data));
}

async function decommissionWeapon(user, weaponId) {
  mustManageWeapons(user);
  const weapon = await weaponOrFail(weaponId);
  await queries.decommissionWeapon(weapon.id);
  return weapon;
}

// ----------------------------------------------------------------------------
// Прием на службу, правка данных, исключение из списков — кадровик
// (staff.manage) и администратор.
// ----------------------------------------------------------------------------

function mustManageStaff(user) {
  if (!hasRight(user, 'staff.manage')) v.fail('Это делает кадровик.', 403);
}

async function checkPersonData(data, exceptId = null) {
  const clean = (x) => String(x || '').trim();
  const out = {
    lastName: clean(data.lastName), firstName: clean(data.firstName), middleName: clean(data.middleName),
    rankId: data.rankId ? v.id(data.rankId) : null,
    personnelNumber: clean(data.personnelNumber), phone: clean(data.phone),
  };
  if (!out.lastName || !out.firstName) v.fail('Укажите фамилию и имя.');
  if ([out.lastName, out.firstName, out.middleName].some((x) => x.length > 60)) v.fail('Слишком длинное имя.');
  if (out.personnelNumber && await queries.personnelNumberTaken(out.personnelNumber, exceptId)) {
    v.fail(`Личный номер ${out.personnelNumber} уже есть у другого человека.`);
  }
  if (out.rankId && !(await queries.listRanks()).some((r) => r.id === out.rankId)) v.fail('Неизвестное звание.');
  return out;
}

/**
 * Принять на службу: человек заводится за штатом, затем — на выбранную
 * вакантную должность (если выбрана) обычным переводом.
 */
async function hireEmployee(user, data) {
  mustManageStaff(user);
  const id = await queries.createEmployee(await checkPersonData(data));
  if (data.positionId) await org().transferEmployee(user, id, data.positionId);
  return id;
}

async function editEmployee(user, employeeId, data) {
  mustManageStaff(user);
  const id = v.id(employeeId);
  const [person] = await getByIds([id]);
  if (!person) v.fail('Человек не найден.', 404);
  if (person.unit_id) await org().assertInScope(user, person.unit_id);
  await queries.updateEmployeeData(id, await checkPersonData(data, id));
}

/**
 * Исключить из списков: должность освобождается (командирство снимается),
 * оружие открепляется, человек становится недействующим с датой и причиной.
 * Снятие с будущих нарядов делает вызывающий (модуль нарядов).
 */
async function excludeEmployee(user, employeeId, reason) {
  mustManageStaff(user);
  const id = v.id(employeeId);
  const [person] = await getByIds([id]);
  if (!person) v.fail('Человек не найден.', 404);
  if (!person.is_active) v.fail('Человек уже исключен из списков.');
  const text = String(reason || '').trim();
  if (!text) v.fail('Укажите основание исключения (приказ).');
  if (person.unit_id) await org().releaseEmployee(user, id);
  await org().cancelActingOf(id);
  await queries.setExcluded(id, text);
  // Исключенный в системе не работает: его учетные записи отключаются.
  await require('../access/service').disableForEmployee(id, user.id);
  return person;
}

async function restoreEmployee(user, employeeId) {
  mustManageStaff(user);
  const id = v.id(employeeId);
  const [person] = await getByIds([id]);
  if (!person) v.fail('Человек не найден.', 404);
  if (person.is_active) return false;
  await queries.setRestored(id);
  return true;
}

async function listExcluded(user) {
  return hasRight(user, 'staff.manage') ? queries.listExcluded() : [];
}

/**
 * Занять оружие на срок (караул, стрельбы — по приказу): на эти даты оно не
 * выдается на наряд. Пересекающаяся занятость — отказ.
 */
async function reserveWeapon({ weaponId, employeeId, dateFrom, dateTo, reason, orderId }, userId) {
  const weapon = await weaponOrFail(weaponId);
  if (!weapon.is_active) v.fail('Оружие списано.');
  v.date(dateFrom);
  v.date(dateTo);
  if (dateTo < dateFrom) v.fail('Окончание раньше начала.');
  const busy = await queries.weaponReservedOn(weapon.id, dateFrom, dateTo);
  if (busy) v.fail(`Оружие № ${weapon.serial_number} уже занято: ${busy.reason || ''} с ${busy.date_from} по ${busy.date_to}.`);
  return queries.reserveWeapon({ weaponId: weapon.id, employeeId, dateFrom, dateTo, reason, orderId, userId });
}

/**
 * Снять занятость: служба вооружения или ведущий отсутствия по приказам на
 * всю часть (как и разбор, из которого занятость берется). Командир
 * подразделения — нет: оружие может быть чужим.
 */
async function cancelReservation(user, id) {
  const byOrders = hasRight(user, 'absence.manage') && !user.scope_unit_id;
  if (!byOrders && !hasRight(user, 'weapon.transfer')) v.fail('Снять занятость оружия может служба вооружения.', 403);
  const reservation = await queries.getReservation(v.id(id));
  if (!reservation) v.fail('Запись о занятости не найдена.', 404);
  await queries.cancelReservation(reservation.id);
  return reservation;
}

/** Люди подразделения — для окна «настроить» (закрепление). */
async function weaponPeople(user, weaponId) {
  mustAssignWeapons(user);
  const weapon = await weaponOrFail(weaponId);
  if (weapon.unit_id === null) return { weapon, people: [] };
  await org().assertInScope(user, weapon.unit_id);
  return { weapon, people: await queries.peopleInSubtree(weapon.unit_id) };
}

module.exports = {
  reserveWeapon,
  cancelReservation,
  orderReservations: (id) => queries.orderReservations(v.id(id)),
  activeWeapons: queries.activeWeapons,
  listOtherOrders: queries.listOtherOrders,
  listAbsenceOrders: queries.listAbsenceOrders,
  orderAbsences: (id) => queries.orderAbsences(v.id(id)),
  endAbsence,
  hireEmployee,
  editEmployee,
  excludeEmployee,
  restoreEmployee,
  listExcluded,
  getWeaponRow: (id) => queries.getWeaponRow(v.id(id)),
  weaponTree,
  addWeapon,
  moveWeapon,
  reorderWeapons,
  attachWeapon,
  giveWeapon,
  editWeapon,
  decommissionWeapon,
  weaponPeople,
  reorderDirections,
  listRanks: queries.listRanks,
 listPermitTypes:queries.listPermitTypes,
 listWeapons:queries.listWeapons,
 createWeapon:queries.createWeapon,
  countActive,
  listEmployees,
  getByIds,
  findAvailable,
  findCandidatesForPosts,
  listAbsentOn,
  findUnfitAssignments,
  addAbsence,
  recordAbsence,
  cancelAbsence,
  getAbsence: queries.getAbsence,
  listAbsencesOnDate: queries.listAbsencesOnDate,
  listAbsenceTypes: queries.listAbsenceTypes,
  listAbsencesFor,
  listPermitsFor: queries.listPermitsFor,
  weaponsOf,
  freeWeapons: queries.freeWeapons,
  assignWeapon,
  releaseWeapon,
  listAllPermitTypes: queries.listAllPermitTypes,
  permitCatalog,
  listDirections: queries.listDirections,
  createDirection,
  updateDirection,
  removeDirection,
  listOrders: queries.listOrders,
  getOrder,
  createOrder,
  updateOrder,
  replaceOrderFile,
  removeOrder,
  orderPermits,
  grantPermit,
  setPermitStatus,
  getPermit: queries.getPermit,
  shortName,
  fullName,
};

for (const name of ['updateOrder', 'removeOrder', 'grantPermit', 'setPermitStatus']) {
  const fn = module.exports[name];
  module.exports[name] = (...args) => db.transaction(() => fn(...args));
}
