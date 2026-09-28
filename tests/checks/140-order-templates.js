'use strict';

// Шаблон приказа вида наряда: блоки (текст, состав, оружие, подпись),
// раскладка на одни и на несколько суток, контроль изменений версиями,
// неизменность утвержденного приказа.

const tpl = require('../../services/app/modules/duty/order-template');
const duty = require('../../services/app/modules/duty/service');
const db = require('../../services/app/db/pool');

const failure = async (fn) => {
  try { await fn(); return null; } catch (err) { return err.message; }
};

/** Условный приказ: n суток, у первого поста выбрано чужое оружие. */
function orderOf(days) {
  const person = { rank_name: 'рядовой', full_name: 'Образцов Иван Иванович' };
  const sections = [];
  for (let i = 0; i < days; i += 1) {
    const start = new Date(2031, 4, 10 + i, 18, 0);
    sections.push({
      duty: { starts_at: start, ends_at: new Date(+start + 24 * 3600000) },
      postCount: 2,
      roster: [
        { post: { id: 1, name: 'Дежурный по части' }, employee: person,
          weapon: { state: 'loan', orderLine: `За рядовым Образцовым И.И. … сутки ${i + 1}` } },
        { post: { id: 2, name: 'Помощник дежурного' }, employee: person, weapon: { state: 'own' } },
        { post: { id: 3, name: 'Дежурный по КПП' }, employee: person, weapon: null },
      ],
    });
  }
  return {
    dutyType: { code: 'СН', name: 'Суточный наряд' }, sections, orderDate: '2031-05-08',
    totalAssigned: days * 2, context: { unit: 'Войсковая часть 00000',
      commander: { last_name: 'Командиров', first_name: 'Пётр', middle_name: 'Петрович', rank_name: 'полковник' } },
  };
}

const texts = (doc) => doc.items.filter((x) => x.type === 'p').map((x) => `${x.number ? `${x.number} ` : ''}${x.text}`);

/** Раскладка по шаблону по умолчанию: одни сутки. */
exports.раскладка_приказа_на_сутки = async (t) => {
  const doc = tpl.layout(tpl.DEFAULT_TEMPLATE, orderOf(1));
  const lines = texts(doc);

  t.is(doc.page.fontSize, 14, 'кегль 14 по умолчанию');
  t.is(doc.page.marginLeft, 30, 'левое поле 30 мм — под подшивку');
  t.is(lines[0], 'ПРИКАЗ', 'первым — заголовок');
  t.ok(lines.includes('Войсковая часть 00000'), 'подставлено наименование части');
  t.ok(lines.some((l) => l.includes('8 мая 2031 г.')), 'дата приказа словами');
  t.ok(lines.some((l) => /^1\. Назначить в наряд с 18\.00 10\.05\.2031 по 18\.00 11\.05\.2031/.test(l)),
    'состав — пункт 1 со временем заступления и сдачи');
  t.is(doc.items.filter((x) => x.type === 'table').length, 0, 'таблицы нет — состав текстом');
  t.ok(lines.includes('Дежурный по части — рядовой Образцов Иван Иванович;'), 'строка на пост, без номера');
  t.ok(lines.includes('Дежурный по КПП — рядовой Образцов Иван Иванович.'), 'последняя — с точкой');
  t.ok(lines.includes('2. Личному составу наряда получить личное оружие.'), 'оружие — пункт 2');
  t.ok(lines.some((l) => l.startsWith('За рядовым Образцовым')), 'и строка временного закрепления');
  t.ok(lines.includes('3. Контроль за исполнением приказа оставляю за собой.'), 'шаблонный пункт — 3');
  const sign = doc.items.find((x) => x.type === 'sign');
  t.is(sign.right, 'П.П. Командиров', 'подпись: И.О. Фамилия командира');
};

/**
 * Приказ на несколько суток (выходные, праздники) раскладывается сам:
 * состав — подпунктами по суткам, оружие — по суткам, период — весь.
 */
exports.раскладка_приказа_на_выходные = async (t) => {
  const doc = tpl.layout(tpl.DEFAULT_TEMPLATE, orderOf(3));
  const lines = texts(doc);

  t.ok(lines.some((l) => l.includes('с 18.00 10.05.2031 по 18.00 13.05.2031')), 'период — от первого заступления до последней сдачи');
  for (const [n, day] of [[1, '10'], [2, '11'], [3, '12']]) {
    t.ok(lines.some((l) => l.startsWith(`1.${n}. Назначить в наряд с 18.00 ${day}.05.2031`)), `сутки ${n} — подпункт 1.${n}`);
  }
  t.is(lines.filter((l) => l.startsWith('Дежурный по части —')).length, 3, 'на каждые сутки свой состав');
  t.ok(lines.includes('2. Личному составу наряда получить личное оружие.'), 'оружие — один пункт');
  t.ok(lines.includes('С 18.00 11.05.2031 по 18.00 12.05.2031:'), 'закрепления оружия — по суткам');
  t.is(lines.filter((l) => l.startsWith('За рядовым')).length, 3, 'по строке на каждые сутки');
};

/** Шаблон проверяется: без состава, с пустым текстом, с чужими полями — отказ. */
exports.проверка_шаблона = async (t) => {
  const fails = (template) => {
    try { tpl.normalize(template); return false; } catch { return true; }
  };
  const ok = tpl.DEFAULT_TEMPLATE;
  t.is(fails(ok), false, 'шаблон по умолчанию верен');
  t.ok(fails({ ...ok, blocks: ok.blocks.filter((b) => b.kind !== 'roster') }), 'без блока состава — отказ');
  t.ok(fails({ ...ok, blocks: [...ok.blocks, { kind: 'text', text: '  ' }] }), 'пустой текстовый блок — отказ');
  t.ok(fails({ ...ok, blocks: [...ok.blocks, { kind: 'script', text: 'x' }] }), 'неизвестный вид блока — отказ');
  t.ok(fails({ ...ok, page: { ...ok.page, marginLeft: 500 } }), 'поле за пределами — отказ');

  // Из формы — массивами в порядке строк; порядок блоков сохраняется.
  const form = tpl.fromForm({
    marginTop: '20', marginBottom: '20', marginLeft: '30', marginRight: '10', fontSize: '14', lineHeight: '1,5',
    blockKind: ['roster', 'text'], blockText: ['Назначить:', 'Контроль — начальнику штаба.'],
    blockRight: ['', ''], blockAlign: ['justify', 'left'], blockIndent: ['1.25', '0'],
    blockSpace: ['0', '6'], blockBold: ['no', 'yes'], blockNumbered: ['yes', 'yes'], blockFormat: ['list', 'table'],
    blockPosts: ['', ''],
  });
  t.is(form.page.lineHeight, 1.5, 'дробное через запятую принято');
  t.is(form.blocks[1].text, 'Контроль — начальнику штаба.', 'порядок блоков из формы');
  t.is(form.blocks[1].bold, true, 'оформление блока из формы');

  const list = texts(tpl.layout(form, orderOf(1)));
  t.ok(list.includes('Дежурный по части — рядовой Образцов Иван Иванович;'), 'состав списком');
  t.ok(list.includes('Дежурный по КПП — рядовой Образцов Иван Иванович.'), 'последняя строка — с точкой');
  t.ok(list.includes('2. Контроль — начальнику штаба.'), 'шаблонный пункт после состава');
};

/**
 * Контроль: без основания шаблон не меняется; каждое изменение — версия с
 * автором; прежнюю можно вернуть; утвержденный приказ остается по своей.
 */
exports.контроль_версий_шаблона = async (t) => {
  const rollback = new Error('rollback order templates');
  try {
    await db.transaction(async () => {
      const one = async (sql, params = []) => (await db.query(sql, params)).rows[0];
      const root = (await one('SELECT id FROM core.units WHERE parent_id IS NULL LIMIT 1')).id;
      const admin = (await one("SELECT id FROM core.users WHERE role_code = 'admin' LIMIT 1")).id;
      const type = (await one(`INSERT INTO duty.duty_types
          (code, name, kind, start_time, duration_hours, recovery_sleep_days, recovery_off_days,
           rest_excludes_weekends, base_weight)
        VALUES ('TEST_ORD', 'Проверка приказа', 'daily', '18:00', 24, 1, 0, false, 1) RETURNING id`)).id;
      const post = (await one(`INSERT INTO duty.duty_posts (duty_type_id, name) VALUES ($1, 'Пост приказа')
        RETURNING id`, [type])).id;
      const person = (await one(`INSERT INTO personnel.employees (last_name, first_name, unit_id)
        VALUES ('Приказов', 'Тест', $1) RETURNING id`, [root])).id;

      const form = (control) => ({
        reason: 'проверка', marginTop: '20', marginBottom: '20', marginLeft: '30', marginRight: '15',
        fontSize: '14', lineHeight: '1', blockKind: ['roster', 'text'], blockText: ['Назначить:', control],
        blockRight: ['', ''], blockAlign: ['justify', 'justify'], blockIndent: ['1.25', '1.25'],
        blockSpace: ['0', '0'], blockBold: ['no', 'no'], blockNumbered: ['yes', 'yes'], blockFormat: ['table', 'table'],
      });

      t.ok(/основание/i.test(await failure(() => duty.saveOrderTemplate(type, { ...form('А'), reason: ' ' }, admin)) || ''),
        'без основания шаблон не меняется');
      t.is((await duty.getOrderTemplate(type)).version, 0, 'и версии не появилось');

      t.is(await duty.saveOrderTemplate(type, form('Контроль — версия А.'), admin), 1, 'первая версия');

      // Приказ, утвержденный по версии 1.
      const D = '2031-06-11';
      await duty.saveBlock({ dutyTypeId: type, date: D, userId: admin,
        byDate: new Map([[D, new Map([[post, person]])]]) });
      await duty.approveBlock(type, D, null, admin);
      const { id: dutyId } = await one('SELECT id FROM duty.duties WHERE duty_type_id = $1 AND start_date = $2', [type, D]);

      t.is(await duty.saveOrderTemplate(type, form('Контроль — версия Б.'), admin), 2, 'вторая версия');

      const approved = await duty.getPrintableOrder(dutyId);
      t.is(approved.templateVersion, 1, 'утвержденный приказ помнит версию шаблона');
      t.ok(texts(duty.orderLayout(approved)).includes('2. Контроль — версия А.'),
        'и печатается по ней, а не по новой');

      t.is(await duty.saveOrderTemplate(type, { reason: 'вернуть А' }, admin, { restore: 1 }), 3, 'возврат — новая версия');
      const current = await duty.getOrderTemplate(type);
      t.is(current.template.blocks[1].text, 'Контроль — версия А.', 'возвращена прежняя');

      t.is(await duty.saveOrderTemplate(type, { reason: 'по умолчанию' }, admin, { reset: true }), 4, 'сброс — тоже версия');
      const reset = await duty.getOrderTemplate(type);
      t.is(reset.custom, false, 'действует шаблон по умолчанию');
      t.is(reset.versions.length, 4, 'история — все четыре изменения');
      t.ok(reset.versions.every((x) => x.reason && x.author), 'у каждого — основание и автор');

      throw rollback;
    });
  } catch (err) {
    if (err !== rollback) throw err;
  }
};

/** Страница шаблона, предпросмотр на сутки и на выходные. */
exports.страницы_шаблона_приказа = async (t, ctx) => {
  if (!ctx.alive) { t.ok(true, 'приложение не запущено — пропущено'); return; }
  const { get, post: send } = require('../lib');

  const type = (await duty.listDutyTypes())[0];

  const list = await get('/duty-types');
  t.ok(list.body.includes(`/duty-types/${type.id}/order`), 'у вида наряда есть «приказ»');

  const page = await get(`/duty-types/${type.id}/order`);
  t.is(page.status, 200, 'страница шаблона открывается');
  t.ok(page.body.includes('Основание изменения'), 'изменение требует основания');
  t.ok(page.body.includes('data-sortable=""'), 'блоки переставляются перетаскиванием');
  t.ok(page.body.includes('История шаблона'), 'видна история');

  const before = (await duty.getOrderTemplate(type.id)).version;
  const refused = await send(`/duty-types/${type.id}/order`, { action: 'reset', reason: '' });
  t.is(refused.status, 400, 'без основания — отказ');
  t.is((await duty.getOrderTemplate(type.id)).version, before, 'и ничего не записано');

  const preview = await get(`/duty-types/${type.id}/order/preview`);
  t.is(preview.status, 200, 'предпросмотр открывается');
  t.ok(preview.body.includes('ПРИКАЗ') && preview.body.includes('Образцов'), 'образец по шаблону с условными людьми');
  t.ok(/@page \{ size: A4; margin: \d+mm/.test(preview.body), 'поля листа — из шаблона');

  const weekend = await get(`/duty-types/${type.id}/order/preview?days=3`);
  t.ok(weekend.body.includes('1.3.'), 'образец на трое суток — подпункты по суткам');
};

/**
 * Наряды одного приказа делятся на блоки: у блока состава — свои посты,
 * блок без выбранных постов берет остальные.
 */
exports.блоки_состава_по_постам = async (t) => {
  const block = (text, posts) => ({ kind: 'roster', text, numbered: true, posts });
  const template = tpl.normalize({
    page: tpl.DEFAULT_TEMPLATE.page,
    blocks: [
      block('Назначить дежурную службу с {{с}} по {{по}}:', []),
      block('Назначить на КПП с {{с}} по {{по}}:', [3]),
      { kind: 'text', text: 'Контроль — за собой.', numbered: true },
    ],
  });

  const one = texts(tpl.layout(template, orderOf(1)));
  const kpp = one.indexOf('2. Назначить на КПП с 18.00 10.05.2031 по 18.00 11.05.2031:');
  t.ok(one.includes('1. Назначить дежурную службу с 18.00 10.05.2031 по 18.00 11.05.2031:'), 'первый блок — пункт 1');
  t.ok(kpp > 0, 'КПП — отдельный пункт 2');
  t.is(one[kpp + 1], 'Дежурный по КПП — рядовой Образцов Иван Иванович.', 'в блоке КПП — только его пост');
  t.is(one.indexOf('Дежурный по КПП — рядовой Образцов Иван Иванович.'), kpp + 1, 'и в первом блоке его нет');
  t.ok(one.includes('Помощник дежурного — рядовой Образцов Иван Иванович.'), 'остальные — в блоке без выбора');
  t.ok(one.includes('3. Контроль — за собой.'), 'нумерация сквозная');

  const three = texts(tpl.layout(template, orderOf(3)));
  t.ok(three.includes('2.3. Назначить на КПП с 18.00 12.05.2031 по 18.00 13.05.2031:'), 'на выходные — подпункты в каждом блоке');

  // Блок без людей в приказ не попадает и номер не занимает.
  const empty = tpl.normalize({ page: tpl.DEFAULT_TEMPLATE.page, blocks: [
    block('Назначить:', []), block('Назначить на пост 99:', [99]), { kind: 'text', text: 'Итог.', numbered: true },
  ] });
  const lines = texts(tpl.layout(empty, orderOf(1)));
  t.is(lines.some((l) => l.includes('пост 99')), false, 'пустой блок не выводится');
  t.ok(lines.includes('2. Итог.'), 'и номер не занимает');

  const fails = (blocks) => { try { tpl.normalize({ blocks }); return false; } catch { return true; } };
  t.ok(fails([block('А', [1]), block('Б', [1])]), 'пост в двух блоках — отказ');
  t.ok(fails([block('А', []), block('Б', [])]), 'два блока «остальные» — отказ');
};
