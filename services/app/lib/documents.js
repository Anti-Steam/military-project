'use strict';

// Хранилище документов и пересохранение в PDF.
//
// Приказ приходит по-разному: PDF, скан, DOC, DOCX. Читать его должны
// одинаково и без установленного на рабочем месте офисного пакета, поэтому
// система хранит ДВА файла: присланный оригинал и PDF для чтения. Для PDF
// это один и тот же файл.
//
// Пересохранение делает LibreOffice, который на Astra Linux есть в поставке.
// Если его нет, приказ все равно сохраняется: пропадает просмотр, но не
// документ. Причина отказа записывается и показывается вместо пустой
// страницы — иначе пользователь видит «ничего» и не знает, чего ждать.

const fs = require('node:fs');
const path = require('node:path');
const { execFile } = require('node:child_process');

const ROOT = path.resolve(__dirname, '../../..');
const STORAGE = process.env.DOC_STORAGE || path.join(ROOT, 'storage');

const CONVERTIBLE = new Set(['.doc', '.docx', '.odt', '.rtf', '.txt', '.xls', '.xlsx']);
const CONVERT_TIMEOUT_MS = 120000;

/** Путь в хранилище; каталоги создаются по мере надобности. */
function storagePath(...parts) {
  const full = path.join(STORAGE, ...parts);
  fs.mkdirSync(path.dirname(full), { recursive: true });
  return full;
}

/**
 * Безопасное имя файла.
 *
 * Имя приходит от пользователя и в путь подставляться как есть не может:
 * «../../» в нем достаточно, чтобы записать файл мимо хранилища.
 */
function safeName(name) {
  return path.basename(String(name || 'file'))
    .replace(/[^\wа-яА-ЯёЁ.\- ]+/g, '_')
    .slice(0, 120) || 'file';
}

/** Есть ли в системе LibreOffice. */
function converter() {
  for (const candidate of ['soffice', 'libreoffice']) {
    for (const dir of (process.env.PATH || '').split(path.delimiter)) {
      const full = path.join(dir, candidate);
      try {
        fs.accessSync(full, fs.constants.X_OK);
        return full;
      } catch { /* дальше */ }
    }
  }
  return null;
}

function convert(binary, file, outDir) {
  return new Promise((resolve, reject) => {
    execFile(binary, ['--headless', '--norestore', '--convert-to', 'pdf', '--outdir', outDir, file],
      { timeout: CONVERT_TIMEOUT_MS },
      (err, stdout, stderr) => (err ? reject(new Error(stderr || err.message)) : resolve(stdout)));
  });
}

/**
 * Сохранение документа: оригинал и PDF для чтения.
 *
 * @param {object} file  {fileName, mime, data}
 * @param {string} folder  подкаталог хранилища, например 'permit-orders/2026'
 * @returns {{filePath, fileName, mime, size, pdfPath, pdfError}} пути от корня проекта
 */
async function store(file, folder) {
  const stamp = `${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
  const name = safeName(file.fileName);
  const ext = path.extname(name).toLowerCase();

  const target = storagePath(folder, `${stamp}${ext}`);
  fs.writeFileSync(target, file.data, { mode: 0o640 });

  const result = {
    fileName: name,
    filePath: path.relative(ROOT, target),
    mime: file.mime,
    size: file.data.length,
    pdfPath: null,
    pdfError: null,
  };

  if (ext === '.pdf') {
    result.pdfPath = result.filePath;
    return result;
  }

  if (!CONVERTIBLE.has(ext)) {
    result.pdfError = `Файл ${ext || 'без расширения'} в PDF не пересохраняется. `
      + 'Для просмотра приложите PDF или документ Word; сканы доступны как оригинал.';
    return result;
  }

  const binary = converter();
  if (!binary) {
    result.pdfError = 'LibreOffice в системе не найден, пересохранить в PDF нечем. '
      + 'Оригинал сохранен; установите libreoffice и загрузите приказ заново.';
    return result;
  }

  try {
    const outDir = path.dirname(target);
    await convert(binary, target, outDir);

    const pdf = path.join(outDir, `${path.basename(target, ext)}.pdf`);
    if (!fs.existsSync(pdf)) throw new Error('LibreOffice не создал PDF');
    result.pdfPath = path.relative(ROOT, pdf);
  } catch (err) {
    result.pdfError = `Не удалось пересохранить в PDF: ${err.message}`;
  }

  return result;
}

/** Полный путь к файлу хранилища; за его пределы выйти нельзя. */
function resolve(relative) {
  if (!relative) return null;
  const full = path.resolve(ROOT, relative);
  try {
    const root = fs.realpathSync(STORAGE);
    const actual = fs.realpathSync(full);
    const rel = path.relative(root, actual);
    if (!rel || rel === '..' || rel.startsWith(`..${path.sep}`) || path.isAbsolute(rel)) return null;
    return fs.statSync(actual).isFile() ? actual : null;
  } catch { return null; }
}

function remove(relative) {
  const full = resolve(relative);
  if (full) try { fs.unlinkSync(full); } catch { /* уже нет */ }
}

module.exports = { store, resolve, remove, safeName, converter, STORAGE };
