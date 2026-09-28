'use strict';

// Структура документа для разбора: абзацы и таблицы по порядку.
//   { type: 'p', text }                — абзац или пункт перечня
//   { type: 'table', rows: [[text]] }  — таблица (приложение) построчно
//
// Источники: HTML, который отдает LibreOffice из DOCX/ODT/RTF/DOC, и
// текст PDF (pdftotext -layout) — там таблица узнается по колонкам,
// разделенным пробелами. Модуль чистый: без файлов и процессов.

const ENTITIES = { nbsp: ' ', amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", laquo: '«', raquo: '»',
  ndash: '–', mdash: '—', hellip: '…' };

function decode(text) {
  return text.replace(/&(#x[0-9a-f]+|#\d+|[a-z]+);/gi, (all, code) => {
    if (code[0] === '#') {
      const n = code[1] === 'x' || code[1] === 'X' ? parseInt(code.slice(2), 16) : parseInt(code.slice(1), 10);
      return Number.isFinite(n) ? String.fromCodePoint(n) : all;
    }
    return ENTITIES[code.toLowerCase()] ?? all;
  });
}

const clean = (text) => decode(text).replace(/\s+/g, ' ').trim();

/**
 * HTML → блоки. Абзацы — <p>, <li>, <h1..6>; таблицы — <table>/<tr>/<td|th>
 * (текст ячейки — все ее абзацы через пробел). Стили и скрипты пропускаются.
 */
function fromHtml(html) {
  const body = String(html)
    .replace(/<(style|script|head)[\s\S]*?<\/\1>/gi, '')
    .replace(/<!--[\s\S]*?-->/g, '');
  const blocks = [];
  const tokens = body.split(/(<[^>]+>)/);
  let text = '';
  let table = null;
  let row = null;
  let cell = null;
  let depth = 0;                 // вложенные таблицы — одной (текст ячейки)

  const flush = () => {
    const t = clean(text);
    text = '';
    if (!t) return;
    if (cell !== null) cell += (cell ? ' ' : '') + t;
    else blocks.push({ type: 'p', text: t });
  };

  for (const token of tokens) {
    if (!token.startsWith('<')) { text += token; continue; }
    const m = /^<\s*(\/)?\s*([a-z0-9]+)/i.exec(token);
    if (!m) continue;
    const closing = Boolean(m[1]);
    const tag = m[2].toLowerCase();

    if (tag === 'table') {
      flush();
      if (!closing) {
        depth += 1;
        if (depth === 1) table = [];
      } else {
        depth -= 1;
        if (depth === 0 && table) {
          const rows = table.filter((r) => r.some((c) => c));
          if (rows.length) blocks.push({ type: 'table', rows });
          table = null;
        }
      }
    } else if (tag === 'tr' && depth === 1) {
      flush();
      if (!closing) row = [];
      else if (row) { table.push(row); row = null; }
    } else if ((tag === 'td' || tag === 'th') && depth === 1) {
      if (!closing) { flush(); cell = ''; } else { flush(); if (row) row.push(cell || ''); cell = null; }
    } else if (['p', 'li', 'div', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'br'].includes(tag)) {
      if (tag === 'br') text += ' ';
      else if (closing || tag === 'div') flush();
    }
  }
  flush();
  return blocks;
}

/**
 * Текст (PDF через pdftotext -layout, .txt) → блоки. Абзацы — по пустым
 * строкам; строки с двумя и более колонками (разрыв в 3+ пробела) подряд —
 * таблица.
 */
function fromText(text) {
  const blocks = [];
  let para = [];
  let table = null;
  const flushPara = () => {
    const t = para.join(' ').replace(/\s+/g, ' ').trim();
    if (t) blocks.push({ type: 'p', text: t });
    para = [];
  };
  const flushTable = () => {
    if (table && table.length >= 2) blocks.push({ type: 'table', rows: table });
    else if (table) table.forEach((r) => para.push(r.join(' ')));
    table = null;
  };
  for (const raw of String(text).replace(/\f/g, '\n').split(/\r?\n/)) {
    const line = raw.replace(/\s+$/, '');
    if (!line.trim()) { flushTable(); flushPara(); continue; }
    const cols = line.trim().split(/\s{3,}/);
    if (cols.length >= 2) {
      flushPara();
      if (!table) table = [];
      table.push(cols.map((c) => c.trim()));
    } else {
      flushTable();
      para.push(line.trim());
    }
  }
  flushTable();
  flushPara();
  return blocks;
}

module.exports = { fromHtml, fromText, decode };
