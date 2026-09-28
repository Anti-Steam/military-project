'use strict';

// Сжатие страниц gzip — встроенным zlib, без сторонних пакетов (стенд
// изолирован, каждая зависимость — лишний перенос). Страницы назначения и
// подразделений весят по 300 КБ, сжатые — в 8–10 раз меньше.
//
// Сжимаются только текстовые ответы res.send (страницы, JSON) от 1 КБ.
// Статика раздается express.static как есть: она мелкая и кэшируется.

const zlib = require('node:zlib');

const MIN_BYTES = 1024;

function compress(req, res, next) {
  if (!/\bgzip\b/.test(req.headers['accept-encoding'] || '')) return next();

  const send = res.send.bind(res);
  res.send = (body) => {
    const type = String(res.get('Content-Type') || 'text/html');
    if (typeof body !== 'string' || Buffer.byteLength(body) < MIN_BYTES
      || !/text|json|javascript/.test(type) || res.get('Content-Encoding')) {
      return send(body);
    }
    const packed = zlib.gzipSync(body, { level: 6 });
    res.set('Content-Encoding', 'gzip');
    res.append('Vary', 'Accept-Encoding');
    if (!res.get('Content-Type')) res.type('html');
    return send(packed);
  };
  next();
}

module.exports = { compress };
