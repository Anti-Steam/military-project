'use strict';
process.env.TZ = 'Asia/Krasnoyarsk';
const test = require('node:test');
const assert = require('node:assert/strict');
const access = require('../services/app/modules/access/service');
const cal = require('../services/app/modules/duty/calendar');

test('empty password hash cannot authenticate arbitrary passwords', async () => {
  const password = require('../services/app/modules/access/password');
  assert.equal(await password.verify('anything', 'scrypt$131072$8$1$AAAAAAAAAAAAAAAAAAAAAA==$'), false);
});

test('CSRF rejects multibyte input without throwing', () => {
  let status;
  const res = { status(code) { status = code; return this; }, render() {} };
  access.csrf({ method: 'POST', session: { csrfToken: 'a'.repeat(43) },
    body: { _csrf: 'я'.repeat(43) } }, res, () => assert.fail('invalid token accepted'));
  assert.equal(status, 403);
});

test('malformed cookie is treated as an unauthenticated request', async () => {
  let location;
  const res = { locals: {}, set() {}, redirect(value) { location = value; } };
  await access.attach({ headers: { cookie: 'sid=%ZZ' }, method: 'GET', path: '/', originalUrl: '/' },
    res, error => { throw error || new Error('unexpected next'); });
  assert.match(location, /^\/login/);
});

test('rotation counts all starts even more than three years after anchor', () => {
  const type = { kind: 'daily', start_time: '10:00:00', duration_hours: 24 };
  assert.equal(cal.rotationTurn(type, [], {}, '2026-09-01', '2030-01-01'),
    cal.daysBetween('2026-09-01', '2030-01-01').length);
});

test('rotation of multiday and daily shift posts starts at anchor, not earlier shift', () => {
  const type = { kind: 'multiday', start_time: '17:30:00' };
  const schedules = [{ start_weekday: 2, end_weekday: 5 }, { start_weekday: 5, end_weekday: 2 }];
  const since = '2030-01-03';
  for (const post of [{}, { per_day: true, start_time: '08:00:00', duration_hours: 12 }]) {
    const dates = new Set();
    for (const period of cal.expectedDuties(type, schedules, since, '2030-02-01')) {
      for (const date of (cal.isShiftPost(post) ? cal.postShifts(period, post).map(s => s.date) : [period.startDate])) {
        if (date >= since && date <= '2030-02-01') dates.add(date);
      }
    }
    [...dates].sort().forEach((date, index) =>
      assert.equal(cal.rotationTurn(type, schedules, post, since, date), index + 1, date));
    assert.equal(cal.rotationTurn(type, schedules, post, since, '2030-01-02'), null);
  }
});
