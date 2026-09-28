'use strict';

// Демонстрационный набор данных — синтетический, для разработки и показа.
//
//   node scripts/demo.js save   снять набор с текущей базы в db/demo/
//   node scripts/demo.js load   залить набор в базу (ЗАМЕНЯЕТ ее содержимое)
//
// Набор — обычный SQL-снимок базы (db/demo/demo.sql) и файлы приказов, на
// которые он ссылается (db/demo/storage/). Миграции новее снимка
// применяются после заливки обычным порядком.
//
// При снятии из снимка убирается служебное: журнал изменений, журнал
// доступа, сеансы, счетчики неверных попыток. Пароли всех учетных записей
// заменяются на общий демо-пароль DEMO_PASSWORD — в репозиторий не должен
// попасть ничей рабочий пароль.
//
// Реальные данные в набор не кладутся НИКОГДА (CLAUDE.md): снимать его можно
// только с базы, где все данные синтетические.

const fs = require('node:fs');
const path = require('node:path');
const readline = require('node:readline/promises');
const { spawnSync } = require('node:child_process');

const root = path.resolve(__dirname, '..');
process.chdir(root);
if (!fs.existsSync('.env')) {
  console.error('Нет файла .env. Сначала один раз запустите ./start — он создаст .env и базу.');
  process.exit(1);
}
process.loadEnvFile('.env');

const DEMO_DIR = path.join(root, 'db/demo');
const DEMO_SQL = path.join(DEMO_DIR, 'demo.sql');
const DEMO_STORAGE = path.join(DEMO_DIR, 'storage');
const DEMO_PASSWORD = 'demo';
const USER = process.env.DB_USER || 'military';
const DB = process.env.DB_NAME || 'military';
const EXPORT_DB = 'military_demo_export';

// Служебное, без которого работать можно: в снимок идет только схема.
const SKIP_DATA = ['audit.changes', 'core.sessions', 'core.security_events', 'core.login_failures'];

/** Команда внутри контейнера БД; input — что подать на вход. */
function inDb(args, { input, capture = false } = {}) {
  const result = spawnSync('docker', ['compose', 'exec', '-T', 'db', ...args], {
    input, maxBuffer: 512 * 1024 * 1024,
    stdio: [input === undefined ? 'ignore' : 'pipe', capture ? 'pipe' : 'inherit', 'inherit'],
  });
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error(`Не выполнилось: ${args.slice(0, 2).join(' ')} (код ${result.status}).`);
  return result.stdout;
}

const psql = (db, sqlOrArgs, input) => inDb(['psql', '-U', USER, '-d', db, '-v', 'ON_ERROR_STOP=1', '-q',
  ...(Array.isArray(sqlOrArgs) ? sqlOrArgs : ['-c', sqlOrArgs])], { input });

/** Пересоздать пустую базу (соединения с ней обрываются). */
function recreate(db) {
  psql('postgres', ['-c', `DROP DATABASE IF EXISTS "${db}" WITH (FORCE)`, '-c', `CREATE DATABASE "${db}"`]);
}

function run(command, args) {
  const result = spawnSync(command, args, { stdio: 'inherit', env: process.env });
  if (result.status !== 0) throw new Error(`${command} ${args.join(' ')}: код ${result.status}`);
}

async function save() {
  console.log(`Снимок демо-набора с базы ${DB}.`);
  const dump = inDb(['pg_dump', '-U', USER, '-Fc', DB], { capture: true });
  recreate(EXPORT_DB);
  try {
    inDb(['pg_restore', '-U', USER, '-d', EXPORT_DB, '--no-owner', '--exit-on-error'], { input: dump });

    // Общий демо-пароль вместо настоящих; смена при входе не требуется.
    const password = require(path.join(root, 'services/app/modules/access/password'));
    const hash = await password.hash(DEMO_PASSWORD);
    psql(EXPORT_DB, `UPDATE core.users SET password_hash = '${hash}', must_change_password = false,
      failed_attempts = 0, locked_until = NULL, last_login_at = NULL`);

    const sql = inDb(['pg_dump', '-U', USER, '-d', EXPORT_DB, '--no-owner', '--no-privileges',
      ...SKIP_DATA.map((t) => `--exclude-table-data=${t}`)], { capture: true });
    fs.mkdirSync(DEMO_DIR, { recursive: true });
    fs.writeFileSync(DEMO_SQL, sql);

    // Файлы приказов, на которые ссылается снимок.
    const list = inDb(['psql', '-U', USER, '-d', EXPORT_DB, '-At', '-c',
      `SELECT file_path FROM personnel.permit_orders WHERE file_path IS NOT NULL
       UNION SELECT pdf_path FROM personnel.permit_orders WHERE pdf_path IS NOT NULL`], { capture: true })
      .toString().split('\n').map((s) => s.trim()).filter(Boolean);
    fs.rmSync(DEMO_STORAGE, { recursive: true, force: true });
    let copied = 0;
    for (const rel of list) {
      const from = path.resolve(root, rel);
      if (!rel.startsWith('storage/') || !fs.existsSync(from)) continue;
      const to = path.join(DEMO_DIR, rel);
      fs.mkdirSync(path.dirname(to), { recursive: true });
      fs.copyFileSync(from, to);
      copied += 1;
    }
    console.log(`Готово: ${path.relative(root, DEMO_SQL)} (${Math.round(sql.length / 1024)} КБ), файлов приказов: ${copied}.`);
  } finally {
    psql('postgres', `DROP DATABASE IF EXISTS "${EXPORT_DB}" WITH (FORCE)`);
  }
}

async function load() {
  if (!fs.existsSync(DEMO_SQL)) throw new Error(`Нет ${path.relative(root, DEMO_SQL)} — набор не снят.`);
  if (!process.argv.includes('--yes')) {
    const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
    const answer = await rl.question(`Содержимое базы ${DB} будет ЗАМЕНЕНО демо-набором (все, что в ней есть, пропадет). `
      + 'Продолжить? Введите «да»: ');
    rl.close();
    if (answer.trim().toLowerCase() !== 'да') { console.log('Отменено.'); return; }
  }
  console.log('Запуск PostgreSQL…');
  run('docker', ['compose', 'up', '-d', '--wait', 'db']);
  console.log(`Заливка демо-набора в ${DB}…`);
  recreate(DB);
  psql(DB, ['-o', '/dev/null', '-f', '-'], fs.readFileSync(DEMO_SQL));
  if (fs.existsSync(DEMO_STORAGE)) fs.cpSync(DEMO_STORAGE, path.join(root, 'storage'), { recursive: true });
  console.log('Миграции новее набора…');
  run(process.execPath, ['db/migrate.js']);
  const users = inDb(['psql', '-U', USER, '-d', DB, '-At', '-F', ' — ', '-c',
    `SELECT u.login, r.name FROM core.users u JOIN core.roles r ON r.code = u.role_code
     WHERE u.is_active AND u.login <> 'check.runner' ORDER BY r.level, u.login`], { capture: true }).toString().trim();
  console.log(`\nДемо-набор залит. Учетные записи (пароль у всех — «${DEMO_PASSWORD}»):`);
  for (const line of users.split('\n')) console.log(`  ${line}`);
  console.log('\nЗапустите (или перезапустите) систему: ./start');
}

const command = process.argv[2];
const job = { save, load }[command];
if (!job) {
  console.log('Использование: node scripts/demo.js save | load [--yes]');
  process.exit(1);
}
job().catch((err) => { console.error(err.message); process.exitCode = 1; });
