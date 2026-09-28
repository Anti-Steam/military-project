'use strict';

// Настройка весов подбора (решение 157): готовность — от суток СДАЧИ,
// граница и дробные значения веса звания, пояснения на страницах.

const duty = require('../../services/app/modules/duty/service');
const queries = require('../../services/app/modules/duty/queries');
const db = require('../../services/app/db/pool');

const one = async (sql, params = []) => (await db.query(sql, params)).rows[0];

/** Простой считается от сдачи: многосуточная смена простоем не засчитывается. */
exports.готовность_от_сдачи = async (t) => {
  const row = await one(`SELECT employee_id FROM duty.v_assignment_periods
    WHERE status <> 'cancelled' AND ends_at::date > starts_at::date AND starts_at < now() LIMIT 1`);
  if (!row) { t.ok(true, 'нарядов через полночь нет — пропущено'); return; }
  const before = new Date().toISOString();
  const expected = await one(`SELECT to_char(max(ends_at), 'YYYY-MM-DD') AS d FROM duty.v_assignment_periods
    WHERE employee_id = $1 AND status <> 'cancelled' AND starts_at < $2`, [row.employee_id, before]);
  const got = (await queries.lastDutyEnds(before)).find((r) => r.employee_id === row.employee_id);
  t.is(got.last_date, expected.d, 'последний наряд — сутки сдачи, а не заступления');
};

exports.вес_звания = async (t, ctx) => {
  const post = await one('SELECT id FROM duty.duty_posts WHERE is_active ORDER BY id LIMIT 1');
  const rank = await one('SELECT id FROM core.ranks ORDER BY seniority LIMIT 1');
  await t.fails(() => duty.setPostRankWeights(post.id, [{ rankId: rank.id, weight: 150 }]), 'больше 100 — отказ');
  if (!ctx.alive) return;
  const { post: send } = require('../lib');
  const saved = (await db.query('SELECT rank_id, weight::float AS weight FROM duty.post_rank_weights WHERE post_id = $1',
    [post.id])).rows;
  try {
    const body = Object.fromEntries(saved.map((w) => [`rank_${w.rank_id}`, String(w.weight)]));
    body[`rank_${rank.id}`] = '1,5';
    t.is((await send(`/posts/${post.id}/rank-weights`, body)).status, 302, 'дробный вес с запятой принят');
    const w = await one('SELECT weight::float AS weight FROM duty.post_rank_weights WHERE post_id = $1 AND rank_id = $2',
      [post.id, rank.id]);
    t.is(w && w.weight, 1.5, 'и сохранен как 1,5');
  } finally {
    await duty.setPostRankWeights(post.id, saved.map((w) => ({ rankId: w.rank_id, weight: w.weight })));
  }
};

exports.пояснения = async (t, ctx) => {
  if (!ctx.alive) { t.ok(true, 'приложение не запущено — пропущено'); return; }
  const { get } = require('../lib');
  const settings = await get('/settings');
  t.ok((settings.body.match(/Пример: /g) || []).length >= 4, 'у каждого параметра подбора — пример');
  t.ok(settings.body.includes('за все время учета'), 'надбавка описана верно: ни разу не заступавшим');
  t.ok(settings.body.includes('×1,5') && settings.body.includes('0,5 за каждые сутки отсыпного'), 'из чего нагрузка');
  t.ok(settings.body.includes('<strong>Вес звания</strong>') && settings.body.includes('<strong>Личные поправки</strong>'),
    'пояснены вес звания и личные поправки');

  const person = await one('SELECT id FROM personnel.employees WHERE is_active AND unit_id IS NOT NULL LIMIT 1');
  const card = await get(`/personnel/${person.id}`);
  t.ok(card.body.includes('Последний наряд сдан'), 'в карточке — от сдачи');
  t.is((card.body.match(/<div class="muted">/g) || []).length >= 5, true, 'пояснение под каждой строкой очереди');
  t.ok(card.body.includes('<strong>Личная поправка</strong>') && card.body.includes('<strong>Основание</strong>'),
    'пояснены столбцы поправок');

  const type = await one('SELECT id FROM duty.duty_types ORDER BY id LIMIT 1');
  const edit = await get(`/duty-types/${type.id}/edit`);
  t.ok(edit.body.includes('по часам поста') && edit.body.includes('На нагрузку и очередь не влияет'), 'вес наряда и отдых пояснены');
};
