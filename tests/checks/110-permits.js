'use strict';

// Приказы на допуск: каталог «направление — год — приказ», приложенный файл,
// выдача допуска по приказу.

const fs = require('node:fs');
const { get, post: send, raw, token } = require('../lib');
const personnel = require('../../services/app/modules/personnel/service');
const documents = require('../../services/app/lib/documents');
const db = require('../../services/app/db/pool');

const NUMBER = 'ЧК-1';

/** Минимальный, но настоящий PDF. */
function pdfBytes() {
  return Buffer.from('%PDF-1.4\n'
    + '1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n'
    + '2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj\n'
    + '3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 200 200]>>endobj\n'
    + 'trailer<</Root 1 0 R>>\n%%EOF');
}

/**
 * Документ, присланный НЕ в PDF: его и должна пересохранить система.
 *
 * Берется RTF — формат, который Word и LibreOffice читают одинаково, а
 * собрать его можно честно, без сторонних средств: проверка не должна
 * зависеть от того, чем ее запускают.
 */
function documentBytes() {
  return Buffer.from('{\\rtf1\\ansi\\ansicpg1251\\deff0'
    + '{\\fonttbl{\\f0 Times New Roman;}}'
    + '\\f0\\fs28 PRIKAZ o dopuske (proverka)\\par}');
}

/** Отправка формы с файлом — так ее шлет браузер. */
async function upload(path, fields, file) {
  const boundary = `----check${Date.now()}${Math.random().toString(36).slice(2, 8)}`;
  const parts = [];

  for (const [name, value] of Object.entries(fields)) {
    parts.push(Buffer.from(`--${boundary}\r\nContent-Disposition: form-data; name="${name}"\r\n\r\n${value}\r\n`));
  }

  if (file) {
    parts.push(Buffer.concat([
      Buffer.from(`--${boundary}\r\nContent-Disposition: form-data; name="file"; `
        + `filename="${file.name}"\r\nContent-Type: ${file.mime}\r\n\r\n`),
      file.data,
      Buffer.from('\r\n'),
    ]));
  }

  parts.push(Buffer.from(`--${boundary}--\r\n`));
  return raw(path, Buffer.concat(parts), `multipart/form-data; boundary=${boundary}`);
}

async function dropCheckOrders() {
  const { rows } = await db.query('SELECT id, file_path, pdf_path FROM personnel.permit_orders '
    + 'WHERE number LIKE $1', [`${NUMBER}%`]);
  for (const row of rows) {
    await db.query('DELETE FROM personnel.employee_permits WHERE order_id = $1', [row.id]);
    await db.query('DELETE FROM personnel.permit_orders WHERE id = $1', [row.id]);
    if (row.file_path) documents.remove(row.file_path);
    if (row.pdf_path && row.pdf_path !== row.file_path) documents.remove(row.pdf_path);
  }
}

/** Каталог: направления, внутри — годы, внутри — приказы. */
exports.каталог_приказов = async (t, ctx) => {
  if (!ctx.alive) { t.ok(true, 'приложение не запущено — пропущено'); return; }

  const page = await get('/permits');
  t.is(page.status, 200, 'вкладка допусков открывается');
  t.ok(page.body.includes('Допуски'), 'это она');

  const catalog = await personnel.permitCatalog();
  t.ok(catalog.length > 0, `направлений в каталоге: ${catalog.length}`);

  const withOrders = catalog.find((d) => d.years.length > 0);
  t.ok(Boolean(withOrders), 'есть направление с приказами');
  if (!withOrders) return;

  // Годы выводятся из даты издания и идут от новых к старым.
  const years = withOrders.years.map((y) => y.year);
  t.is(years, [...years].sort((a, b) => b - a), 'годы идут от новых к старым');

  for (const year of withOrders.years) {
    t.ok(year.orders.every((o) => o.issued_on.startsWith(String(year.year))),
      `приказы ${year.year} года изданы в этом году`);
  }
};

/** Приказ заводится с файлом, PDF отдается по ссылке. */
exports.приказ_с_файлом = async (t, ctx) => {
  if (!ctx.alive) { t.ok(true, 'приложение не запущено — пропущено'); return; }

  await dropCheckOrders();
  const direction = (await personnel.listDirections())[0];

  try {
    const created = await upload('/permits/orders', {
      _csrf: token(),
      directionId: String(direction.id),
      number: NUMBER,
      issuedOn: '2026-09-20',
      title: 'Приказ проверки (PDF)',
    }, { name: 'prikaz.pdf', mime: 'application/pdf', data: pdfBytes() });

    t.is(created.status, 302, 'приказ заведен');
    const id = Number((created.location || '').match(/(\d+)$/)[1]);

    const order = await personnel.getOrder(id);
    t.is(order.number, NUMBER, 'номер сохранен');
    t.is(order.year, 2026, 'год выведен из даты издания');
    t.ok(Boolean(order.pdf_path), 'PDF приложен');
    t.is(order.pdf_path, order.file_path, 'для PDF оригинал и есть документ для чтения');

    const pdf = await get(`/permits/orders/${id}/pdf`);
    t.is(pdf.status, 200, 'приказ отдается по ссылке');
    t.ok(pdf.body.startsWith('%PDF'), 'и это действительно PDF');

    // Файл лежит в хранилище, а не в базе.
    t.ok(Boolean(documents.resolve(order.file_path)), 'файл сохранен в хранилище');
    t.ok(order.file_path.startsWith('storage/'), 'внутри хранилища, а не где попало');
  } finally {
    await dropCheckOrders();
  }
};

/** Документ Word пересохраняется в PDF — читать приказ должны все одинаково. */
exports.документ_пересохраняется_в_pdf = async (t, ctx) => {
  if (!ctx.alive) { t.ok(true, 'приложение не запущено — пропущено'); return; }
  if (!documents.converter()) { t.ok(true, 'LibreOffice не установлен — пропущено'); return; }

  await dropCheckOrders();
  const direction = (await personnel.listDirections())[0];

  try {
    const created = await upload('/permits/orders', {
      _csrf: token(),
      directionId: String(direction.id),
      number: `${NUMBER}-doc`,
      issuedOn: '2026-09-20',
      title: 'Приказ проверки (документ)',
    }, { name: 'prikaz.rtf', mime: 'application/rtf', data: documentBytes() });

    t.is(created.status, 302, 'приказ с документом заведен');
    const id = Number((created.location || '').match(/(\d+)$/)[1]);

    const order = await personnel.getOrder(id);
    t.is(order.pdf_error, null, `пересохранение прошло без ошибки${order.pdf_error ? ': ' + order.pdf_error : ''}`);
    t.ok(Boolean(order.pdf_path), 'PDF построен');
    t.ok(order.pdf_path !== order.file_path, 'и лежит рядом с оригиналом, не заменяя его');

    const pdf = await get(`/permits/orders/${id}/pdf`);
    t.is(pdf.status, 200, 'приказ открывается');
    t.ok(pdf.body.startsWith('%PDF'), 'PDF-ом, хотя присылали документ');

    const original = await get(`/permits/orders/${id}/file`);
    t.is(original.status, 200, 'оригинал тоже доступен');
  } finally {
    await dropCheckOrders();
  }
};

/** Допуск выдается по приказу и виден с обеих сторон. */
exports.выдача_допуска_по_приказу = async (t, ctx) => {
  if (!ctx.alive) { t.ok(true, 'приложение не запущено — пропущено'); return; }

  await dropCheckOrders();
  const direction = (await personnel.listDirections())[0];
  const person = (await personnel.listEmployees())[0];
  const type = (await personnel.listPermitTypes())[0];

  try {
    const created = await upload('/permits/orders', {
      _csrf: token(),
      directionId: String(direction.id),
      number: `${NUMBER}-grant`,
      issuedOn: '2026-09-20',
      title: 'Приказ проверки (выдача)',
    }, null);
    const id = Number((created.location || '').match(/(\d+)$/)[1]);

    const granted = await send('/permits/grant', {
      employeeId: String(person.id),
      permitTypeId: String(type.id),
      orderId: String(id),
      back: `/personnel/${person.id}`,
    });
    t.is(granted.status, 302, 'допуск выдан');

    // Со стороны приказа видно, кого он допустил.
    const permits = await personnel.orderPermits(id);
    t.is(permits.length, 1, 'в приказе один допущенный');
    t.is(permits[0].employee_id, person.id, 'именно тот человек');
    t.is(permits[0].issued_at, '2026-09-20', 'дата выдачи взята из приказа');

    // Со стороны человека виден приказ.
    const card = await get(`/personnel/${person.id}`);
    t.is(card.status, 200, 'карточка человека открывается');
    t.ok(card.body.includes(`/permits/orders/${id}`), 'в ней ссылка на приказ-основание');

    // Дважды один и тот же допуск по одному приказу не выдается.
    const again = await send('/permits/grant', {
      employeeId: String(person.id),
      permitTypeId: String(type.id),
      orderId: String(id),
    });
    t.is(again.status, 400, 'повторная выдача отклонена');

    // Приказ с допусками не удаляется: допуск без основания непроверяем.
    const refused = await send(`/permits/orders/${id}/delete`, {});
    t.is(refused.status, 400, 'приказ с допусками не удаляется');

    // Отзыв допуска — состояние, а не удаление записи.
    const revoked = await send(`/permits/${permits[0].id}/status`,
      { status: 'revoked', back: `/personnel/${person.id}` });
    t.is(revoked.status, 302, 'допуск отозван');

    const after = await personnel.orderPermits(id);
    t.is(after[0].status, 'revoked', 'запись сохранена и помечена отозванной');
  } finally {
    await dropCheckOrders();
  }
};

/** Направление с приказами не удаляется, пустое — удаляется. */
exports.направления_каталога = async (t, ctx) => {
  if (!ctx.alive) { t.ok(true, 'приложение не запущено — пропущено'); return; }

  const name = `Проверочное направление ${Date.now()}`;

  const created = await send('/permits/directions', { name });
  t.is(created.status, 302, 'направление заведено');

  const made = (await personnel.listDirections()).find((d) => d.name === name);
  t.ok(Boolean(made), 'и видно в перечне');
  if (!made) return;

  try {
    // Пока пусто — удаляется.
    const removed = await send(`/permits/directions/${made.id}/delete`, {});
    t.is(removed.status, 302, 'пустое направление удаляется');
    t.is((await personnel.listDirections()).some((d) => d.id === made.id), false, 'и его нет');

    // Направление с приказами удалить нельзя.
    const busy = (await personnel.listDirections()).find((d) => d.orders > 0);
    if (busy) {
      const refused = await send(`/permits/directions/${busy.id}/delete`, {});
      t.is(refused.status, 400, 'направление с приказами не удаляется');
    }
  } finally {
    await db.query('DELETE FROM personnel.permit_directions WHERE name = $1', [name]);
  }
};

/**
 * Оружие человека видно в его карточке — закрепленное и числящееся за ним
 * как за командиром. Распоряжаются им во вкладке «Оружие».
 */
exports.оружие_в_карточке = async (t, ctx) => {
  if (!ctx.alive) { t.ok(true, 'приложение не запущено — пропущено'); return; }

  const { rows: [weapon] } = await db.query(`SELECT id, serial_number, owner_id FROM personnel.weapons
    WHERE is_active AND owner_id IS NOT NULL LIMIT 1`);
  if (!weapon) { t.ok(true, 'закрепленного оружия нет — пропущено'); return; }

  const own = await personnel.weaponsOf(weapon.owner_id);
  t.ok(own.some((w) => w.id === weapon.id && w.own), 'закрепленное числится за человеком');

  const card = await get(`/personnel/${weapon.owner_id}`);
  t.is(card.status, 200, 'карточка открывается');
  t.ok(card.body.includes('id="weapons"'), 'в ней есть раздел оружия');
  t.ok(card.body.includes(weapon.serial_number), 'с заводским номером');
  t.ok(card.body.includes('href="/weapons"'), 'распоряжаются — во вкладке «Оружие»');
  t.is(card.body.includes('/weapons/release'), false, 'закрепления из карточки больше нет');
};
