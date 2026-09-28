'use strict';

// Демо-набор (db/demo, решение 158): без служебного и без настоящих паролей,
// файлы приказов, на которые он ссылается, — рядом.

const fs = require('node:fs');
const path = require('node:path');
const password = require('../../services/app/modules/access/password');

const DIR = path.join(__dirname, '../../db/demo');

exports.демо_набор = async (t) => {
  const file = path.join(DIR, 'demo.sql');
  if (!fs.existsSync(file)) { t.ok(true, 'демо-набор не снят — пропущено'); return; }
  const sql = fs.readFileSync(file, 'utf8');

  for (const table of ['audit.changes', 'core.sessions', 'core.security_events', 'core.login_failures']) {
    t.is(sql.includes(`COPY ${table} `), false, `без данных ${table}`);
  }
  t.ok(sql.includes('COPY personnel.employees ') && sql.includes('COPY duty.duty_assignments '), 'люди и наряды на месте');

  // Пароли: у всех учетных записей — общий демо-пароль.
  const users = sql.split('COPY core.users ')[1].split('\n\\.\n')[0].split('\n').slice(1);
  const hashes = [...new Set(users.map((line) => line.split('\t').find((x) => x.startsWith('scrypt$'))))];
  t.ok(users.length > 0 && hashes.length === 1, 'у всех записей один пароль');
  t.is(await password.verify('demo', hashes[0]), true, 'и это демо-пароль «demo»');

  // Файлы приказов, на которые ссылается снимок, — в db/demo/storage.
  const referenced = [...sql.matchAll(/storage\/[^\t\n]+?\.(pdf|docx|doc|odt|rtf|jpg|png)/g)].map((m) => m[0]);
  t.ok(referenced.every((rel) => fs.existsSync(path.join(DIR, rel))), 'файлы приказов приложены');
};
