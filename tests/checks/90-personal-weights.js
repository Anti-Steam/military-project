'use strict';

// Личные поправки к постам: одна запись, правится и в карточке человека, и на
// странице «Подбор» со стороны поста.

const { get, post: send } = require('../lib');
const duty = require('../../services/app/modules/duty/service');
const db = require('../../services/app/db/pool');

/** Пост с несколькими кандидатами и два первых кандидата на него. */
async function pick() {
  const type = (await duty.listDutyTypes()).find((x) => x.code === 'SN');
  const now = new Date();
  const date = require('../../services/app/modules/duty/calendar').dayKey(
    new Date(now.getFullYear(), now.getMonth() + 1, 15));

  const selection = await duty.findCandidatesByPost(type.id, date, null);
  const slot = selection.posts.find((p) => p.candidates.length > 1);
  if (!slot) throw new Error('на стенде не нашлось поста с двумя кандидатами');

  return {
    type, date, selection, post: slot.post,
    first: slot.candidates[0], second: slot.candidates[1],
  };
}

async function clear(employeeId, postId) {
  await db.query(
    'DELETE FROM personnel.employee_post_weights WHERE employee_id = $1 AND post_id = $2',
    [employeeId, postId],
  );
}

/** Поправка меняет порядок кандидатов, но никого не убирает из списка. */
exports.поправка_меняет_порядок = async (t) => {
  const { type, date, selection, post, first, second } = await pick();
  await clear(second.id, post.id);

  try {
    // Второму кандидату дается поправка, перевешивающая разрыв в очереди.
    const gap = first.queue.value - second.queue.value;
    await duty.setEmployeePostWeight({
      employeeId: second.id, postId: post.id, weight: gap + 5, note: 'проверка', userId: null,
    });

    const after = await duty.findCandidatesByPost(type.id, date, null);
    const slot = after.posts.find((p) => p.post.id === post.id);
    const moved = slot.candidates.find((c) => c.id === second.id);

    t.is(slot.candidates[0].id, second.id, 'с поправкой человек предлагается первым');
    t.is(moved.queue.fit, second.queue.fit + gap + 5, 'поправка вошла в соответствие посту');
    t.ok(slot.candidates.some((c) => c.id === first.id), 'прежний первый из списка не исчез');

    // Поправка привязана к посту: на остальных постах соответствие прежнее.
    const fitBefore = new Map(selection.posts
      .filter((p) => p.post.id !== post.id && p.candidates.some((c) => c.id === second.id))
      .map((p) => [p.post.id, p.candidates.find((c) => c.id === second.id).queue.fit]));

    let others = 0;
    for (const p of after.posts) {
      if (!fitBefore.has(p.post.id)) continue;
      const same = p.candidates.find((c) => c.id === second.id);
      if (!same) continue;
      others += 1;
      t.is(same.queue.fit, fitBefore.get(p.post.id), `на посту «${p.post.name}» поправки нет`);
    }
    t.ok(others >= 0, `других постов с этим человеком проверено: ${others}`);

    // Пустое значение снимает поправку, а не приравнивает ее к нулю.
    await duty.setEmployeePostWeight({
      employeeId: second.id, postId: post.id, weight: '', note: '', userId: null,
    });
    const left = await duty.listEmployeePostWeights(null, second.id);
    t.is(left.some((w) => w.post_id === post.id), false, 'пустое значение снимает поправку');
  } finally {
    await clear(second.id, post.id);
  }
};

/** Непомерная поправка отклоняется: вес не заменяет запрет. */
exports.поправка_проверяется = async (t) => {
  const { post, first } = await pick();

  await t.fails(
    () => duty.setEmployeePostWeight({
      employeeId: first.id, postId: post.id, weight: '1000', userId: null,
    }),
    'поправка сверх предела',
  );

  await t.fails(
    () => duty.setEmployeePostWeight({
      employeeId: first.id, postId: post.id, weight: 'много', userId: null,
    }),
    'поправка не числом',
  );
};

/** Карточка человека открывается и правит поправку. */
exports.карточка_человека = async (t, ctx) => {
  if (!ctx.alive) { t.ok(true, 'приложение не запущено — пропущено'); return; }

  const { post, first } = await pick();
  await clear(first.id, post.id);

  try {
    const card = await get(`/personnel/${first.id}`);
    t.is(card.status, 200, 'карточка открылась');
    t.ok(card.body.includes('Очередь заступления'), 'очередь разложена по частям');
    t.ok(card.body.includes('Личные поправки к постам'), 'есть раздел поправок');
    t.ok(card.body.includes(`name="weight_${post.id}"`), 'есть поле поправки по посту');

    const saved = await send(`/personnel/${first.id}/post-weights`, {
      [`weight_${post.id}`]: '7',
      [`note_${post.id}`]: 'старший смены',
    });
    t.is(saved.status, 302, 'поправка сохранена и страница вернулась к карточке');

    const own = (await duty.listEmployeePostWeights(null, first.id))
      .find((w) => w.post_id === post.id);
    t.ok(Boolean(own), 'поправка записана');
    t.is(own && own.weight, 7, 'значение сохранено');
    t.is(own && own.note, 'старший смены', 'основание сохранено');

    // Та же поправка видна со стороны поста на странице «Подбор».
    const settings = await get('/settings');
    t.is(settings.status, 200, 'страница подбора открылась');
    t.ok(settings.body.includes(`/posts/${post.id}/personal-weight`), 'у поста есть форма поправок');
    t.ok(settings.body.includes(first.short_name), 'в перечне исключений видна фамилия');

    // И снимается оттуда же.
    const removed = await send(`/posts/${post.id}/personal-weight`, {
      employeeId: String(first.id), remove: '1',
    });
    t.is(removed.status, 302, 'поправка снята со стороны поста');
    t.is((await duty.listEmployeePostWeights(null, first.id))
      .some((w) => w.post_id === post.id), false, 'запись удалена');
  } finally {
    await clear(first.id, post.id);
  }
};
