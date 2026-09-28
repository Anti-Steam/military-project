'use strict';

// Прием файла из формы (multipart/form-data).
//
// Своя разборка, а не библиотека: на изолированный стенд все уезжает вместе с
// node_modules, и каждая лишняя зависимость — это лишний повод объяснять, что
// именно там лежит. Задача узкая: одна форма с одним файлом и обычными
// полями, и разбирается она сотней строк.
//
// Поток читается в память с ЖЕСТКИМ пределом: приказ — это документ на
// несколько страниц, а не архив, и принимать гигабайт, чтобы затем его
// отвергнуть, незачем.

const MAX_BYTES = 25 * 1024 * 1024;

/** Граница из заголовка: multipart/form-data; boundary=---- */
function boundaryOf(contentType) {
  const match = /boundary=(?:"([^"]+)"|([^;]+))/i.exec(contentType || '');
  return match ? (match[1] || match[2]).trim() : null;
}

/** Тело запроса целиком, но не больше предела. */
function readBody(req, limit) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;

    req.on('data', (chunk) => {
      size += chunk.length;
      if (size > limit) {
        reject(Object.assign(new Error('Файл больше допустимого размера.'),
          { userMessage: true, status: 413 }));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });

    req.on('end', () => resolve(Buffer.concat(chunks)));
    req.on('error', reject);
  });
}

/** Разбор одной части: заголовки до пустой строки, дальше содержимое. */
function parsePart(part) {
  const split = part.indexOf('\r\n\r\n');
  if (split === -1) return null;

  const head = part.slice(0, split).toString('utf8');
  const body = part.slice(split + 4);

  const name = /name="([^"]*)"/i.exec(head);
  if (!name) return null;

  const fileName = /filename="([^"]*)"/i.exec(head);
  const mime = /content-type:\s*([^\r\n]+)/i.exec(head);

  return {
    name: name[1],
    fileName: fileName ? fileName[1] : null,
    mime: mime ? mime[1].trim() : null,
    body,
  };
}

/**
 * Поля и файлы формы.
 *
 * @returns {{fields: object, files: object}} файл — {fileName, mime, data}
 */
async function parseForm(req, { limit = MAX_BYTES } = {}) {
  const boundary = boundaryOf(req.headers['content-type']);
  if (!boundary) {
    const err = new Error('Форма отправлена без файла.');
    err.userMessage = true;
    err.status = 400;
    throw err;
  }

  const body = await readBody(req, limit);
  const separator = Buffer.from(`--${boundary}`);

  const fields = {};
  const files = {};

  let position = body.indexOf(separator);
  while (position !== -1) {
    const start = position + separator.length;
    // Конец формы помечается двумя дефисами после границы.
    if (body.slice(start, start + 2).toString() === '--') break;

    const next = body.indexOf(separator, start);
    if (next === -1) break;

    // Перед следующей границей стоит CRLF, он к содержимому не относится.
    const part = parsePart(body.slice(start + 2, next - 2));
    position = next;
    if (!part) continue;

    if (part.fileName) {
      files[part.name] = {
        fileName: part.fileName,
        mime: part.mime || 'application/octet-stream',
        data: part.body,
      };
    } else {
      const value = part.body.toString('utf8');
      // Несколько значений одного поля — как в обычной форме.
      if (part.name in fields) {
        fields[part.name] = [].concat(fields[part.name], value);
      } else {
        fields[part.name] = value;
      }
    }
  }

  return { fields, files };
}

module.exports = { parseForm, MAX_BYTES };
