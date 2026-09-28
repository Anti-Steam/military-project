'use strict';
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const access = require('../services/app/modules/access/service');
const accessQueries = require('../services/app/modules/access/queries');
const duty = require('../services/app/modules/duty/service');
const org = require('../services/app/modules/org/service');

module.exports = async function review(db, check) {
  const rollback = new Error('review rollback');
  const scalar = async (sql, args = []) => (await db.query(sql, args)).rows[0];
  const login = 'review.' + crypto.randomBytes(6).toString('hex');
  try {
    await db.transaction(async () => {
      const user = await access.createUser({ login, roleCode: 'user', permissions: [] });
      await check('lockout expiry restores three attempts', async () => {
        for (let i = 0; i < 3; i++) await assert.rejects(() => access.login({ login, password: 'wrong' }));
        // Счетчики — по паре «запись + компьютер» (решение 155); без адреса — «неизвестен».
        await db.query("UPDATE core.login_failures SET locked_until=now()-interval '1 minute' WHERE user_id=$1", [user.id]);
        await assert.rejects(() => access.login({ login, password: 'wrong' }));
        const state = await scalar('SELECT failed_attempts,locked_until FROM core.login_failures WHERE user_id=$1', [user.id]);
        assert.equal(state.failed_attempts, 1);
        assert.equal(state.locked_until, null);
      });
      const session = await access.login({ login, password: user.password });
      await check('session id survives SQL joins and idle renewal', async () => {
        assert.equal((await accessQueries.findSession(session.sessionId)).session_id, session.sessionId);
        await db.query("UPDATE core.sessions SET expires_at=now()+interval '1 hour' WHERE id=$1", [session.sessionId]);
        const req = { headers: { cookie: `sid=${session.sessionId}` }, path: '/password', method: 'GET' };
        let renewed;
        await access.attach(req, { locals: {}, set() {}, cookie(name, value) { renewed = value; } }, err => { if (err) throw err; });
        assert.equal(req.session.id, session.sessionId);
        assert.equal(renewed, session.sessionId);
        // Продление идет от этого обращения на весь срок бездействия.
        const stored = await accessQueries.findSession(session.sessionId);
        const idle = access.SESSION_LIMITS.idleHours * 3600000;
        assert.ok(new Date(stored.expires_at).getTime() > Date.now() + idle - 3600000);
      });
      await check('absolute session expiry deletes the actual session', async () => {
        const extra = await access.login({ login, password: user.password });
        // Сессия старше предела на сутки; предел берется из настройки, а не
        // вписывается числом — иначе проверка ломается при каждой правке .env.
        const hours = access.SESSION_LIMITS.absoluteHours;
        if (hours === 0) return;
        await db.query('UPDATE core.sessions SET created_at=now()-make_interval(hours => $2) WHERE id=$1',
          [extra.sessionId, hours + 24]);
        let redirect;
        await access.attach({ headers: { cookie: `sid=${extra.sessionId}` } },
          { locals: {}, set() {}, clearCookie() {}, redirect(path) { redirect = path; } }, err => { throw err; });
        assert.equal(redirect, '/login');
        assert.equal(await accessQueries.findSession(extra.sessionId), null);
      });
      await check('password change revokes every session', async () => {
        await access.changePassword(user.id, { current: user.password, next: 'Review-New-Password-2026', repeat: 'Review-New-Password-2026' });
        assert.equal(await accessQueries.findSession(session.sessionId), null);
      });

      const root = (await scalar('SELECT id FROM core.units WHERE parent_id IS NULL LIMIT 1')).id;
      const type = (await scalar("INSERT INTO duty.duty_types(code,name,kind,start_time,duration_hours) VALUES('REVIEW_SHIFTS','Тест выходов','multiday','17:30',NULL) RETURNING id")).id;
      await db.query('INSERT INTO duty.duty_type_schedules(duty_type_id,start_weekday,end_weekday) VALUES($1,2,5),($1,5,2)', [type]);
      const post = (await scalar("INSERT INTO duty.duty_posts(duty_type_id,name,per_day,start_time,duration_hours,recovery_sleep_days) VALUES($1,'Тестовый посменный',true,'08:00',12,0) RETURNING id", [type])).id;
      const employee = (await scalar("INSERT INTO personnel.employees(last_name,first_name,unit_id) VALUES('ТестВыходов','Синтетический',$1) RETURNING id", [root])).id;
      const { dutyId } = await duty.createDuty({ dutyTypeId: type, startDate: '2030-01-01', assignments: [
        { postId: post, employeeId: employee, onDate: '2030-01-02' },
        { postId: post, employeeId: employee, onDate: '2030-01-03' },
      ] });
      await check('repeated employee on distinct shifts counts occupied slots', async () => {
        assert.equal((await duty.getDutyForEdit(dutyId)).assignedCount, 2);
      });
      await check('shift dates cannot escape duty period or be omitted', async () => {
        for (const onDate of [null, '2030-01-01', '2030-01-05']) {
          await assert.rejects(() => duty.updateAssignments(dutyId, [{ postId: post, employeeId: employee, onDate }]));
          await assert.rejects(() => duty.replaceMember({ dutyId, postId: post, employeeId: employee, onDate, note: 'Тест' }));
        }
      });
      await check('withdrawal removes only overlapping shifts', async () => {
        await duty.withdrawEmployee({ employeeId: employee, dateFrom: '2030-01-03', dateTo: '2030-01-03', documentRef: 'ТЕСТ' });
        const rows = (await db.query("SELECT to_char(on_date,'YYYY-MM-DD') AS day FROM duty.duty_assignments WHERE duty_id=$1", [dutyId])).rows;
        assert.deepEqual(rows, [{ day: '2030-01-02' }]);
      });
      throw rollback;
    });
  } catch (error) { if (error !== rollback) throw error; }

  await check('failed account creation rolls back account and permissions together', async () => {
    await assert.rejects(() => access.createUser({ login, roleCode: 'user', permissions: [{ code: 'unknown.permission', granted: true }] }));
    assert.equal(await accessQueries.findByLogin(login), null);
  });

  await check('simultaneous unit moves cannot create a cycle', async () => {
    const user = { scope_unit_id: null };
    const root = (await scalar('SELECT id FROM core.units WHERE parent_id IS NULL LIMIT 1')).id;
    const a = await org.createUnit(user, { parentId: root, name: 'Тест А', shortName: 'Тест А' });
    const b = await org.createUnit(user, { parentId: root, name: 'Тест Б', shortName: 'Тест Б' });
    try {
      const results = await Promise.allSettled([
        org.updateUnit(user, a, { parentId: b, name: 'Тест А', shortName: 'Тест А' }),
        org.updateUnit(user, b, { parentId: a, name: 'Тест Б', shortName: 'Тест Б' }),
      ]);
      assert.equal(results.filter(r => r.status === 'fulfilled').length, 1);
    } finally {
      await db.query('UPDATE core.units SET parent_id=$1 WHERE id=ANY($2::int[])', [root, [a, b]]);
      await org.removeUnit(user, a);
      await org.removeUnit(user, b);
    }
  });
};
