'use strict';

// Файл приказа → структура (абзацы и таблицы). Все средствами, которые есть
// на стенде без интернета: DOCX/ODT/RTF/DOC — LibreOffice (пересохранение в
// HTML со структурой), PDF — pdftotext (poppler-utils). Сканы без текста —
// пока нет (распознавание — следующий этап).

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { execFile } = require('node:child_process');
const blocks = require('./blocks');
const documents = require('../../lib/documents');

const TIMEOUT_MS = 120000;

const run = (binary, args) => new Promise((resolve, reject) => {
  execFile(binary, args, { timeout: TIMEOUT_MS, maxBuffer: 32 * 1024 * 1024 },
    (err, stdout, stderr) => (err ? reject(new Error(stderr || err.message)) : resolve(stdout)));
});

const fail = (message) => Object.assign(new Error(message), { userMessage: true, status: 400 });

/** @param {string} full  полный путь к файлу приказа */
async function extract(full) {
  const ext = path.extname(full).toLowerCase();

  if (ext === '.html' || ext === '.htm') return blocks.fromHtml(fs.readFileSync(full, 'utf8'));
  if (ext === '.txt') return blocks.fromText(fs.readFileSync(full, 'utf8'));

  if (ext === '.pdf') {
    let text;
    try {
      text = await run('pdftotext', ['-layout', '-enc', 'UTF-8', full, '-']);
    } catch (err) {
      throw fail(`Не удалось прочитать PDF (нужен pdftotext из poppler-utils): ${err.message}`);
    }
    const result = blocks.fromText(text);
    if (!result.length) {
      throw fail('В PDF нет текста — похоже, это скан. Распознавание сканов пока не подключено: '
        + 'приложите приказ документом Word или внесите данные вручную.');
    }
    return result;
  }

  if (['.doc', '.docx', '.odt', '.rtf'].includes(ext)) {
    const binary = documents.converter();
    if (!binary) throw fail('LibreOffice в системе не найден — прочитать документ нечем.');
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'orderparse-'));
    try {
      await run(binary, ['--headless', '--norestore', '--convert-to', 'html:XHTML Writer File:UTF8',
        '--outdir', dir, full]);
      const html = fs.readdirSync(dir).find((f) => f.endsWith('.html'));
      if (!html) throw fail('LibreOffice не прочитал документ.');
      return blocks.fromHtml(fs.readFileSync(path.join(dir, html), 'utf8'));
    } finally {
      fs.rmSync(dir, { recursive: true, force: true });
    }
  }

  throw fail(`Файл ${ext || 'без расширения'} не разбирается: приложите PDF с текстом или документ Word.`);
}

module.exports = { extract };
