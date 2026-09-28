'use strict';
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const documents = require('../../services/app/lib/documents');
const personnel = require('../../services/app/modules/personnel/service');
const queries = require('../../services/app/modules/personnel/queries');
const db = require('../../services/app/db/pool');

exports.storageBoundary = async t => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'document-boundary-'));
  const original = process.env.DOC_STORAGE;
  const modulePath = require.resolve('../../services/app/lib/documents');
  const cached = require.cache[modulePath];
  try {
    const storage = path.join(root, 'storage');
    fs.mkdirSync(storage);
    fs.mkdirSync(storage + '-other');
    fs.writeFileSync(path.join(storage, 'valid.pdf'), 'test');
    const outside = path.join(storage + '-other', 'secret.pdf');
    fs.writeFileSync(outside, 'test');
    fs.symlinkSync(outside, path.join(storage, 'link.pdf'));
    process.env.DOC_STORAGE = storage;
    delete require.cache[modulePath];
    const docs = require(modulePath);
    t.ok(docs.resolve(path.join(storage, 'valid.pdf')), 'Файл внутри хранилища доступен');
    t.is(docs.resolve(outside), null, 'Соседний каталог запрещён');
    t.is(docs.resolve(path.join(storage, 'link.pdf')), null, 'Ссылка наружу запрещена');
    t.is(docs.resolve(storage), null, 'Каталог не является документом');
  } finally {
    require.cache[modulePath] = cached;
    if (original === undefined) delete process.env.DOC_STORAGE;
    else process.env.DOC_STORAGE = original;
    fs.rmSync(root, { recursive: true, force: true });
  }
};

exports.orderIntegrity = async t => {
  const originals = { getOrder: queries.getOrder, updateOrder: queries.updateOrder,
    setOrderFile: queries.setOrderFile, transaction: db.transaction, store: documents.store, remove: documents.remove };
  try {
    db.transaction = fn => fn();
    queries.getOrder = async () => ({ id: 1, number: '1', issued_on: '2020-01-01', direction_id: 1, permits: 1 });
    let updates = 0;
    queries.updateOrder = async () => { updates++; };
    await t.fails(() => personnel.updateOrder(1, { number: '2', issuedOn: '2020-01-01', directionId: 1 }), 'Реквизиты использованного приказа защищены');
    t.is(updates, 0, 'Записи после отказа нет');
    await personnel.updateOrder(1, { number: '1', issuedOn: '2020-01-01', directionId: 1, note: 'Примечание' });
    t.is(updates, 1, 'Примечание можно изменить');
    const removed = [];
    documents.store = async () => ({ filePath: 'new.doc', pdfPath: 'new.pdf' });
    documents.remove = file => removed.push(file);
    queries.setOrderFile = async () => { throw new Error('write failed'); };
    await t.fails(() => personnel.replaceOrderFile(1, { data: Buffer.from('test') }, 1), 'Ошибка записи передана вызывающему коду');
    t.is(removed, ['new.doc', 'new.pdf'], 'Оба новых файла убраны после отказа БД');
  } finally {
    for (const key of ['getOrder', 'updateOrder', 'setOrderFile']) queries[key] = originals[key];
    db.transaction = originals.transaction;
    documents.store = originals.store;
    documents.remove = originals.remove;
  }
};

exports.dutyTypeIntegrity = async t => {
  const duty = require('../../services/app/modules/duty/service');
  const q = require('../../services/app/modules/duty/queries');
  const names = ['getDutyType', 'getSchedules', 'createDutyType', 'setSchedules', 'setGeneralPermits'];
  const originals = Object.fromEntries(names.map(n => [n, q[n]]));
  const transaction = db.transaction, query = db.query;
  const data = { code: 'TEST', name: 'Тест', kind: 'daily', startTime: '12:00', durationHours: 24, holidayRule: 'any' };
  let inserted = false, inside = false;
  try {
    db.transaction = async fn => {
      inside = true;
      try { return await fn(); } catch (err) { inserted = false; throw err; }
      finally { inside = false; }
    };
    q.createDutyType = async () => { t.ok(inside, 'Создание внутри транзакции'); inserted = true; return 1; };
    q.setSchedules = async () => {};
    q.setGeneralPermits = async () => { throw new Error('invalid reference'); };
    await t.fails(() => duty.createDutyType(data), 'Ошибка связанного допуска');
    t.is(inserted, false, 'Ошибка откатывает создание вида');
    q.getDutyType = async () => ({ kind: 'daily', start_time: '10:00:00', duration_hours: 24, holiday_rule: 'any' });
    q.getSchedules = async () => [];
    db.query = async () => ({ rows: [{}] });
    await t.fails(() => duty.updateDutyType(1, data), 'График существующего наряда защищён');
  } finally {
    for (const n of names) q[n] = originals[n];
    db.transaction = transaction; db.query = query;
  }
};

exports.permitScope = async t => {
  const router = require('../../services/app/modules/personnel/routes');
  const access = require('../../services/app/modules/access/service');
  const org = require('../../services/app/modules/org/service');
  const original = { require: access.require, getPermit: personnel.getPermit,
    setPermitStatus: personnel.setPermitStatus, assertInScope: org.assertInScope };
  try {
    access.require = () => true;
    personnel.getPermit = async () => ({ id: 1, unit_id: 2 });
    let writes = 0, status;
    personnel.setPermitStatus = async () => { writes++; };
    org.assertInScope = async (user, unit) => {
      t.is(unit, 2, 'Проверяется подразделение владельца допуска');
      throw Object.assign(new Error('outside scope'), { userMessage: true, status: 403 });
    };
    const handler = router.stack.find(s => s.route?.path === '/permits/:id/status').route.stack[0].handle;
    await handler({ user: { scope_unit_id: 1 }, params: { id: '1' }, body: { status: 'revoked' } },
      { status(n) { status = n; return this; }, render() {} }, err => { throw err; });
    t.is(status, 403, 'Чужой допуск запрещён');
    t.is(writes, 0, 'Статус чужого допуска не изменён');
  } finally {
    access.require = original.require; personnel.getPermit = original.getPermit;
    personnel.setPermitStatus = original.setPermitStatus; org.assertInScope = original.assertInScope;
  }
};
