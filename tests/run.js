'use strict';

// Запускатель проверок: node --env-file=.env tests/run.js [образец имени]
//
// Находит все файлы в tests/checks, вызывает каждую экспортированную функцию
// и печатает по строке на проверку. Возвращает ненулевой код, если хоть одна
// не прошла, — этого достаточно и человеку, и будущей автоматической сборке.
//
// Проверки идут только по military_review_test и отдельному приложению
// на этой БД; порядок запуска приведен в README.TXT, раздел 15.4.

const fs = require('node:fs');
const path = require('node:path');
const { Case, serverAlive, signIn, signOut } = require('./lib');

const CHECKS_DIR = path.join(__dirname, 'checks');

let signedIn = false;
async function runChecks() {
  if (process.env.DB_NAME !== 'military_review_test') {
    throw new Error('Проверки изменяют и удаляют данные. Используйте только DB_NAME=military_review_test и приложение, подключенное к этой тестовой БД.');
  }
  const filter = process.argv[2] || '';
  const files = fs.readdirSync(CHECKS_DIR).filter((f) => f.endsWith('.js')).sort();

  const alive = await serverAlive();
  if (!alive) {
    throw new Error('Тестовое приложение не отвечает. Запустите его с DB_NAME=military_review_test и задайте CHECK_URL.');
  } else {
    // Система закрыта входом: проверки работают под служебной учетной
    // записью, которая заводится на время прогона и удаляется после.
    signedIn = true;
    await signIn();
  }

  const cases = [];

  for (const file of files) {
    const module = require(path.join(CHECKS_DIR, file));

    for (const [name, fn] of Object.entries(module)) {
      if (typeof fn !== 'function') continue;
      if (filter && !name.includes(filter) && !file.includes(filter)) continue;

      const item = new Case(name);
      cases.push(item);

      try {
        await fn(item, { alive });
      } catch (err) {
        item.failures.push(`сорвалась: ${err.message}`);
      }

      const mark = item.failures.length === 0 ? '  ок  ' : ' ОШИБКА';
      console.log(`${mark} ${item.name} (${item.count})`);
      for (const failure of item.failures) console.log(`        ${failure}`);
    }
  }

  const failed = cases.filter((c) => c.failures.length > 0);
  if (cases.length === 0) throw new Error('По указанному фильтру не найдено ни одной проверки.');
  console.log(`\nПроверок: ${cases.length}, утверждений: ${cases.reduce((s, c) => s + c.count, 0)}, не прошло: ${failed.length}`);



  process.exitCode = failed.length > 0 ? 1 : 0;

}

async function main() {
  try { await runChecks(); }
  finally {
    try { if (signedIn) await signOut(); }
    finally { await require('../services/app/db/pool').pool.end(); }
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
