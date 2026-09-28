'use strict';

// Разбор приказов (МС-3): структура документа, узнавание людей и значений в
// любой форме, общие правила «пункт — перечень» и «таблица с отметками»,
// проверка и принятие человеком, обучение словаря. Все документы —
// синтетические.

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const blocks = require('../../services/app/modules/orderparse/blocks');
const r = require('../../services/app/modules/orderparse/recognize');
const { parse } = require('../../services/app/modules/orderparse/parse');
const { extract } = require('../../services/app/modules/orderparse/extract');
const personnel = require('../../services/app/modules/personnel/service');
const db = require('../../services/app/db/pool');

const one = async (sql, params = []) => (await db.query(sql, params)).rows[0];

const PEOPLE = [
  { id: 1, last_name: 'Иванов', first_name: 'Иван', middle_name: 'Иванович' },
  { id: 2, last_name: 'Иванова', first_name: 'Анна', middle_name: 'Петровна' },
  { id: 3, last_name: 'Петров', first_name: 'Пётр', middle_name: 'Петрович' },
  { id: 4, last_name: 'Иванов', first_name: 'Олег', middle_name: 'Сергеевич' },
  { id: 5, last_name: 'Сидоров', first_name: 'Семен', middle_name: 'Семенович' },
];
const DICT = {
  orderPermit: ['о допуске', 'допустить'], orderAbsence: ['об убытии', 'полагать убывш'], marks: ['допущен', '+'],
  permits: [{ id: 10, label: 'Дежурный по части' }, { id: 9, label: 'Помощник дежурного по части' },
    { id: 15, label: 'Дежурный по парку', phrases: ['ДПП'] }, { id: 16, label: 'Дневальный' }],
  absences: [{ id: 'VACATION', label: 'Отпуск', phrases: ['отпуск'] }, { id: 'TRIP', label: 'Командировка', phrases: ['командировк'] }],
};

exports.структура_документа = async (t) => {
  const b = blocks.fromHtml(`<p>ПРИКАЗ</p><ol><li><p><span>1.</span>майора Иванова;</p></li></ol>
    <table><tr><td><p>ФИО</p></td><td>Дневальный</td></tr><tr><td>Сидоров С.С.</td><td>допущен</td></tr></table><p>Командир&nbsp;части</p>`);
  t.is(b.map((x) => x.type).join(','), 'p,p,table,p', 'абзацы, пункт перечня, таблица');
  t.is(b[3].text, 'Командир части', 'сущности раскрыты');
  t.is(b[2].rows[1][1], 'допущен', 'ячейки таблицы');
  const text = blocks.fromText('ПРИКАЗ\n\nФИО              Дневальный      Дежурный по парку\nСидоров С.С.     допущен         +\n');
  t.ok(text.some((x) => x.type === 'table' && x.rows.length === 2), 'таблица в тексте PDF — по колонкам');
};

exports.узнавание_людей_и_значений = async (t) => {
  const idx = r.buildPeople(PEOPLE);
  const who = (text) => r.findPeople(text, idx).map((f) => f.employeeId);
  t.is(who('майора Иванова И.И.;').join(), '1', 'родительный + инициалы после');
  t.is(who('И.И. Иванов').join(), '1', 'инициалы перед фамилией');
  t.is(who('Иванову Анну Петровну').join(), '2', 'полное ФИО, женская фамилия');
  t.is(who('Петрова П.П., Иванова О.С.').join(), '3,4', 'двое через запятую');
  const amb = r.findPeople('Иванова', idx)[0];
  t.ok(amb.employeeId === null && amb.candidates.length === 3, 'без инициалов — несколько вариантов');

  const values = r.buildValues(DICT.permits);
  const found = r.findValues('Допустить дежурным по части, помощником дежурного по части и ДПП:', values).map((v) => v.id);
  t.is(found.join(), '10,9,15', 'три допуска из одной фразы, сокращение — по словарю');
  t.is(JSON.stringify(r.findPeriod('с 01.11.2026 по 30.11.2026')), '{"from":"2026-11-01","to":"2026-11-30"}', 'с … по …');
  t.is(r.findPeriod('с 1 ноября 2026 г. на 10 суток').to, '2026-11-10', 'на N суток');
};

exports.правила_разбора = async (t) => {
  const permit = parse(blocks.fromHtml(`<p>О допуске личного состава</p>
    <p>1. Допустить к несению службы дежурным по части, помощником дежурного по части:</p>
    <ol><li><p>майора Иванова И.И.;</p></li><li><p>капитана Петрова П.П.</p></li></ol>
    <table><tr><td>ФИО</td><td>Дежурный по парку</td><td>Дневальный</td></tr>
    <tr><td>Сидоров С.С.</td><td>допущен</td><td></td></tr><tr><td>Неизвестный Н.Н.</td><td>+</td><td></td></tr></table>
    <p>2. Козлова К.К. и Иванову А.П. ознакомить.</p>`), DICT, PEOPLE, 'permit');
  const pairs = permit.facts.map((f) => `${f.employeeId}:${f.valueId}`);
  t.is(permit.detected, 'permit', 'вид по заголовку — допуск');
  t.ok(['1:10', '1:9', '3:10', '3:9'].every((p) => pairs.includes(p)), 'перечень под пунктом — оба допуска каждому');
  t.ok(pairs.includes('5:15') && !pairs.includes('5:16'), 'таблица: отметка — допуск, пусто — нет');
  t.ok(permit.unknown.some((u) => u.name.startsWith('Неизвестный')), 'не узнанный в таблице — в перечне не узнанных');

  const absence = parse(blocks.fromHtml(`<p>Об убытии в отпуск и командировку</p>
    <p>Полагать убывшими в очередной отпуск с 01.11.2026 по 30.11.2026:</p>
    <p>рядового Иванова И.И.;</p><p>Иванову А.П. с 05.11.2026 по 20.11.2026.</p>
    <p>Полагать убывшим в командировку:</p><p>Петрова П.П. с 10.11.2026 на 5 суток.</p>`), DICT, PEOPLE, 'absence');
  const byId = new Map(absence.facts.map((f) => [f.employeeId, f]));
  t.ok(byId.get(1).valueId === 'VACATION' && byId.get(1).dateTo === '2026-11-30', 'общий период пункта');
  t.is(byId.get(2).dateFrom, '2026-11-05', 'свой период человека сильнее общего');
  t.ok(byId.get(3).valueId === 'TRIP' && byId.get(3).dateTo === '2026-11-14', 'новый пункт — новая причина');

  const lost = parse(blocks.fromHtml('<p>Приказ</p><p>Иванова И.И. считать.</p>'), DICT, PEOPLE, 'permit');
  t.ok(lost.unparsed.length === 1 && lost.facts[0].valueId === null, 'люди без «что» — в не разобранные, строка для ручной доделки');
};

/** Настоящий DOCX (собран LibreOffice из синтетического текста) читается со структурой. */
exports.чтение_docx = async (t) => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'check-parse-'));
  try {
    fs.writeFileSync(path.join(dir, 'order.html'), `<html><head><meta charset="utf-8"></head><body>
      <p>О допуске</p><p>Допустить дежурным по части:</p><ol><li>майора Иванова И.И.</li></ol>
      <table border="1"><tr><td>ФИО</td><td>Дневальный</td></tr><tr><td>Сидоров С.С.</td><td>+</td></tr></table></body></html>`);
    execFileSync('soffice', ['--headless', '--norestore', '--infilter=HTML (StarWriter)', '--convert-to',
      'docx:MS Word 2007 XML', '--outdir', dir, path.join(dir, 'order.html')], { timeout: 120000 });
    const b = await extract(path.join(dir, 'order.docx'));
    t.ok(b.some((x) => x.type === 'p' && /Допустить дежурным/.test(x.text)), 'абзацы DOCX прочитаны');
    t.ok(b.some((x) => x.type === 'table' && x.rows.length === 2), 'таблица DOCX прочитана');
    const res = parse(b, DICT, PEOPLE, 'permit');
    t.ok(res.facts.some((f) => f.employeeId === 1 && f.valueId === 10), 'из DOCX: Иванов — к дежурному по части');
    t.ok(res.facts.some((f) => f.employeeId === 5 && f.valueId === 16), 'из таблицы DOCX: Сидоров — дневальный');
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
};

/** Через страницы: разобрать приказ, принять, «уже внесено», научить словарь. */
exports.разбор_через_страницы = async (t, ctx) => {
  if (!ctx.alive) { t.ok(true, 'приложение не запущено — пропущено'); return; }
  const { get, post: send } = require('../lib');
  const person = await one(`SELECT e.id, e.last_name, e.first_name, e.middle_name FROM personnel.employees e
    WHERE e.is_active AND e.unit_id IS NOT NULL AND e.middle_name IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM personnel.absences a WHERE a.employee_id = e.id AND a.cancelled_at IS NULL AND a.date_to >= CURRENT_DATE)
      AND (SELECT count(*) FROM personnel.employees x WHERE x.last_name = e.last_name) = 1
    LIMIT 1`);
  const type = await one("SELECT id, name FROM personnel.permit_types WHERE NOT is_post_specific AND name LIKE 'Дежурный по части' LIMIT 1")
    || await one('SELECT id, name FROM personnel.permit_types WHERE NOT is_post_specific LIMIT 1');
  const direction = await one('SELECT id FROM personnel.permit_directions LIMIT 1');
  const name = `${person.last_name} ${person.first_name[0]}.${person.middle_name[0]}.`;
  const abbreviation = `пдч${Date.now() % 100000}`;
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'check-parse-'));
  const ids = [];
  try {
    const docx = (html) => {
      fs.writeFileSync(path.join(dir, 'o.html'), `<html><head><meta charset="utf-8"></head><body>${html}</body></html>`);
      execFileSync('soffice', ['--headless', '--norestore', '--infilter=HTML (StarWriter)', '--convert-to',
        'docx:MS Word 2007 XML', '--outdir', dir, path.join(dir, 'o.html')], { timeout: 120000 });
      return { fileName: 'o.docx', mime: 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
        data: fs.readFileSync(path.join(dir, 'o.docx')) };
    };
    const issued = new Date(Date.now() - 86400000).toISOString().slice(0, 10);
    // Даты отпуска — ближайшие: отсутствие заводится не дальше чем на год вперед.
    const day = (n) => new Date(Date.now() + n * 86400000);
    const iso = (d) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
    const ru = (d) => iso(d).split('-').reverse().join('.');
    const [from, to] = [day(30), day(45)];

    // Приказ о допуске: пункт и перечень.
    const permitOrder = await personnel.createOrder({ kind: 'permit', directionId: direction.id, number: `РП-${Date.now()}`,
      issuedOn: issued, title: 'Проверка разбора' }, docx(`<p>О допуске личного состава</p>
        <p>Допустить к несению службы: ${type.name.toLowerCase()} и ${abbreviation}:</p><ol><li>${name}</li></ol>`), null);
    ids.push(permitOrder);

    const page = await get(`/permits/orders/${permitOrder}/parse`);
    t.is(page.status, 200, 'страница разбора открывается');
    t.ok(page.body.includes('Принять отмеченные') && page.body.includes(`value="${type.id}" selected`), 'предложен допуск');
    t.ok(page.body.includes(`<option value="${person.id}" selected>`), 'узнан человек');

    const applied = await send(`/permits/orders/${permitOrder}/parse/apply`, { count: '1', accept_0: 'on',
      employee_0: String(person.id), value_0: String(type.id), to_0: '' });
    t.is(applied.status, 302, 'принято');
    const granted = await one('SELECT count(*)::int AS n FROM personnel.employee_permits WHERE order_id = $1 AND employee_id = $2',
      [permitOrder, person.id]);
    t.is(granted.n, 1, 'допуск выдан по приказу');
    const again = await get(`/permits/orders/${permitOrder}/parse`);
    t.ok(again.body.includes('уже внесено'), 'повторно — «уже внесено»');

    // Научить: сокращение из этого приказа — вид допуска.
    const taught = await send('/orders/parse/phrases', { kind: 'permit', target: String(type.id), phrase: abbreviation,
      back: `/permits/orders/${permitOrder}/parse` });
    t.is(taught.status, 302, 'сокращение запомнено');
    const dict = await get('/orders/parse');
    t.ok(dict.body.includes(abbreviation), 'в словаре разбора');

    // Приказ об отпуске: причина и даты.
    const absenceOrder = await personnel.createOrder({ kind: 'absence', number: `РО-${Date.now()}`, issuedOn: issued },
      docx(`<p>Об убытии в отпуск</p><p>Полагать убывшим в очередной отпуск с ${ru(from)} по ${ru(to)}:</p><p>${name}</p>`), null);
    ids.push(absenceOrder);
    const ab = await get(`/permits/orders/${absenceOrder}/parse`);
    t.ok(ab.body.includes(`value="${iso(from)}"`) && ab.body.includes('value="VACATION" selected'), 'отпуск и даты предложены');
    await send(`/permits/orders/${absenceOrder}/parse/apply`, { count: '1', accept_0: 'on', employee_0: String(person.id),
      value_0: 'VACATION', from_0: iso(from), to_0: iso(to) });
    const absence = await one('SELECT source, order_id FROM personnel.absences WHERE employee_id = $1 AND order_id = $2',
      [person.id, absenceOrder]);
    t.ok(absence && absence.source === 'import', 'отсутствие внесено с пометкой «из приказа»');
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
    const documents = require('../../services/app/lib/documents');
    for (const id of ids) {
      const files = await one('SELECT file_path, pdf_path FROM personnel.permit_orders WHERE id = $1', [id]);
      if (files) { documents.remove(files.file_path); documents.remove(files.pdf_path); }
      await db.query('DELETE FROM personnel.employee_permits WHERE order_id = $1', [id]);
      await db.query('DELETE FROM personnel.absences WHERE order_id = $1', [id]);
      await db.query('DELETE FROM personnel.permit_orders WHERE id = $1', [id]);
    }
    await db.query('DELETE FROM parse.phrases WHERE phrase = $1', [abbreviation]);
  }
};

/** «Приказы → Допуски»: направления и годы свернуты, направления — перетаскиваются. */
exports.каталог_свернут = async (t, ctx) => {
  if (!ctx.alive) { t.ok(true, 'приложение не запущено — пропущено'); return; }
  const { get } = require('../lib');
  const page = await get('/permits');
  const catalog = page.body.slice(page.body.indexOf('data-sortable="/permits/directions/within/root/order"'));
  t.ok(catalog.length < page.body.length, 'каталог направлений перетаскивается');
  t.is(/<details class="unit-node" data-sort-id="\d+"\s+open/.test(page.body), false, 'направления при входе свернуты');
  t.ok(page.body.includes('class="drag-handle"'), 'у направления — «⠿»');
  if (page.body.includes('class="year-box"')) {
    t.is(/<details class="year-box"\s+open/.test(page.body), false, 'годы — сворачиваемые и свернуты');
  }
  const abs = await get('/orders/absences');
  t.is(/<details class="year-box"\s+open/.test(abs.body), false, 'в «Отсутствиях» годы тоже свернуты');
};

/** Словарь: разделы свернуты; слово — в раздел своего назначения; своих разделов нет (их заменили виды приказов). */
exports.разделы_словаря = async (t, ctx) => {
  if (!ctx.alive) { t.ok(true, 'приложение не запущено — пропущено'); return; }
  const { get, post: send } = require('../lib');
  const service = require('../../services/app/modules/orderparse/service');
  const word = `спч${Date.now() % 100000}`;
  const type = await one('SELECT id, name FROM personnel.permit_types WHERE NOT is_post_specific LIMIT 1');
  try {
    const page = await get('/orders/parse');
    t.ok(page.body.includes('class="unit-node dict-section"'), 'разделы — сворачиваемые');
    t.is(/<details class="unit-node dict-section" id="section-[a-z_]+"\s+open/.test(page.body), false, 'при входе свернуты');
    t.is(page.body.includes('Новый раздел'), false, 'своих разделов больше нет');
    t.ok(page.body.includes('Виды приказов'), 'вместо них — виды приказов');

    const added = await send('/orders/parse/phrases', { kind: 'permit', phrase: word, target: String(type.id) });
    t.is(added.status, 302, 'слово добавлено');
    t.ok((added.location || '').includes('open=permit'), 'раздел открыт после добавления');
    const row = await one('SELECT s.kind FROM parse.phrases p JOIN parse.sections s ON s.id = p.section_id WHERE p.phrase = $1', [word]);
    t.is(row && row.kind, 'permit', 'слово — в стандартном разделе своего назначения');
    const dict = await service.dictionary();
    t.ok(dict.permits.find((p) => p.id === type.id).phrases.includes(word), 'слово работает в разборе');
    t.is((await one('SELECT count(*)::int AS n FROM parse.sections WHERE NOT builtin')).n, 0, 'в базе только стандартные разделы');
  } finally {
    await db.query('DELETE FROM parse.phrases WHERE phrase = $1', [word]);
  }
};
