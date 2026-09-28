'use strict';
const assert = require('node:assert/strict');
const { Readable } = require('node:stream');
const v = require('../../services/app/lib/validation');
const upload = require('../../services/app/lib/upload');
const access = require('../../services/app/modules/access/service');

exports.identifiers = async t => {
  for (const value of ['1', 2147483647]) t.is(v.id(value), Number(value), 'Допустимый ID');
  for (const value of [0, -1, 1.5, 2147483648, '', 'abc', null, undefined, Infinity]) {
    assert.throws(() => v.id(value), { status: 400, userMessage: true });
    t.ok(true, `Недопустимый ID: ${String(value)}`);
  }
};

exports.calendarInput = async t => {
  for (const value of ['1900-01-01', '2000-02-29', '2028-02-29', '9998-12-31']) {
    t.is(v.date(value), value, 'Корректная дата');
  }
  for (const value of ['1900-02-29', '2100-02-29', '2026-04-31', '2026-2-01', '2026-01-01T00:00:00', '9999-01-01', null]) {
    assert.throws(() => v.date(value), { status: 400 });
    t.ok(true, `Некорректная дата: ${value}`);
  }
};

exports.csrfTokens = async t => {
  const req = { session: { csrfToken: 'a'.repeat(43) } };
  access.checkToken(req, 'a'.repeat(43));
  t.ok(true, 'Верный токен принят');
  for (const token of [undefined, '', 'b'.repeat(43), 'я'.repeat(43)]) {
    assert.throws(() => access.checkToken(req, token), { status: 403 });
    t.ok(true, 'Поддельный токен отклонён с 403');
  }
};

exports.permissionChecks = async t => {
  const user = { permissions: new Set(['personnel.view']) };
  t.is(access.can(user, 'personnel.view'), true, 'Разрешённое действие');
  t.is(access.can(user, 'permit.manage'), false, 'Чтение не даёт права записи');
  t.is(access.can(null, 'personnel.view'), false, 'Без пользователя доступа нет');
};

function request(bytes, contentType = 'multipart/form-data; boundary="check-boundary"') {
  // Разбиваем тело внутри заголовков и двоичных данных: так приходит реальный поток.
  const req = Readable.from([bytes.subarray(0, 17), bytes.subarray(17, 91), bytes.subarray(91)]);
  req.headers = { 'content-type': contentType };
  return req;
}
function form() {
  const data = Buffer.from([0, 255, 13, 10, 128, 42]);
  const body = Buffer.concat([
    Buffer.from('--check-boundary\r\nContent-Disposition: form-data; name="tag"\r\n\r\nпервый\r\n'
      + '--check-boundary\r\nContent-Disposition: form-data; name="tag"\r\n\r\nвторой\r\n'
      + '--check-boundary\r\nContent-Disposition: form-data; name="file"; filename="Приказ.pdf"\r\nContent-Type: application/pdf\r\n\r\n'),
    data, Buffer.from('\r\n--check-boundary--\r\n'),
  ]);
  return { body, data };
}
exports.multipartBinary = async t => {
  const { body, data } = form();
  const result = await upload.parseForm(request(body), { limit: body.length });
  t.is(result.fields.tag, ['первый', 'второй'], 'Повторяющиеся поля и UTF-8');
  t.is(result.files.file.fileName, 'Приказ.pdf', 'Кириллица в имени файла');
  t.is(result.files.file.mime, 'application/pdf', 'MIME сохранён');
  t.is(result.files.file.data, data, 'Двоичные данные сохранены побайтно');
};
exports.multipartLimits = async t => {
  const { body } = form();
  await assert.rejects(upload.parseForm(request(body), { limit: body.length - 1 }), { status: 413 });
  t.ok(true, 'Лимит тела запроса соблюдается');
  await assert.rejects(upload.parseForm(request(body, 'multipart/form-data')), { status: 400 });
  t.ok(true, 'Без boundary получаем ошибку формы');
  const req = new Readable({ read() { this.destroy(new Error('connection lost')); } });
  req.headers = { 'content-type': 'multipart/form-data; boundary=x' };
  await assert.rejects(upload.parseForm(req), /connection lost/);
  t.ok(true, 'Ошибка потока передаётся вызывающему коду');
};
