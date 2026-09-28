'use strict';
const assert = require('node:assert/strict');
const { randomUUID } = require('node:crypto');
const db = require('../../services/app/db/pool');
const duty = require('../../services/app/modules/duty/service');
const personnel = require('../../services/app/modules/personnel/service');

function guard() {
  if (process.env.DB_NAME !== 'military_review_test') throw new Error('Разрешена только military_review_test');
}
async function one(sql, args = []) { return (await db.query(sql, args)).rows[0]; }
const typeData = code => ({ code, name: 'Синтетический вид', kind: 'daily', startTime: '10:00', durationHours: 24, holidayRule: 'any' });

exports.createTypeRollback = async t => {
  guard();
  const code = 'T' + randomUUID().replaceAll('-', '').slice(0, 12);
  try {
    // Отдельная транзакция сервиса: именно её откат проверяется чтением после ошибки.
    const missing = await one('SELECT id FROM personnel.permit_types WHERE id=2147483647');
    assert.equal(missing, undefined, 'ID для проверки должен отсутствовать');
    await assert.rejects(duty.createDutyType({ ...typeData(code), permitTypeIds: [2147483647] }), { code: '23503' });
    t.is((await one('SELECT count(*)::int AS n FROM duty.duty_types WHERE code=$1', [code])).n, 0,
      'Ошибка связанного допуска откатывает весь вид');
  } finally { await db.query('DELETE FROM duty.duty_types WHERE code=$1', [code]); }
};
exports.updateTypeRollback = async t => {
  guard();
  const code = 'T' + randomUUID().replaceAll('-', '').slice(0, 12);
  let id;
  try {
    id = await duty.createDutyType(typeData(code));
    assert.equal(await one('SELECT id FROM personnel.permit_types WHERE id=2147483647'), undefined);
    await assert.rejects(duty.updateDutyType(id, { ...typeData(code), name: 'Не должно сохраниться',
      schedules: [{ startWeekday: 1 }], permitTypeIds: [2147483647] }), { code: '23503' });
    const card = await duty.getDutyTypeCard(id);
    t.is(card.type.name, 'Синтетический вид', 'Имя откатилось');
    t.is(card.schedules, [], 'Расписание откатилось');
    t.is(card.permits, [], 'Допуски не записались частично');
  } finally { if (id) await db.query('DELETE FROM duty.duty_types WHERE id=$1', [id]); }
};
exports.permitHistoryDatabase = async t => {
  guard();
  const rollback = new Error('ROLLBACK_FIXTURE');
  try {
    await db.transaction(async () => {
      const suffix = randomUUID();
      const unit = await one("INSERT INTO core.units(name,short_name) VALUES('Синтетический тест','Тест') RETURNING id");
      const person = await one("INSERT INTO personnel.employees(last_name,first_name,unit_id) VALUES('Тестов','Иван',$1) RETURNING id", [unit.id]);
      const type = await one("INSERT INTO personnel.permit_types(code,name) VALUES($1,'Тестовый допуск') RETURNING id", [suffix]);
      const direction = await one("INSERT INTO personnel.permit_directions(name) VALUES('Тестовое направление') RETURNING id");
      const data = { directionId: direction.id, number: suffix, issuedOn: '2020-01-01' };
      const orderId = await personnel.createOrder(data, null, null);
      const permitId = await personnel.grantPermit({ employeeId: person.id, permitTypeId: type.id, orderId });
      const [permit] = await personnel.orderPermits(orderId);
      t.is(permit.full_name, 'Тестов Иван', 'SQL возвращает поля для имени');
      t.is(permit.issued_at, '2020-01-01', 'Дата допуска согласована с приказом');
      await personnel.setPermitStatus(permitId, 'revoked');
      await assert.rejects(personnel.removeOrder(orderId), { status: 400 });
      t.ok(true, 'Отзыв не позволяет удалить основание');
      await assert.rejects(personnel.updateOrder(orderId, { ...data, issuedOn: '2020-02-01' }), { status: 400 });
      t.is((await personnel.getOrder(orderId)).issued_on, '2020-01-01', 'Дата приказа не изменилась');
      t.is((await personnel.getPermit(permitId)).status, 'revoked', 'История отзыва сохранена');
      throw rollback;
    });
  } catch (err) { if (err !== rollback) throw err; }
};
