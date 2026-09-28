'use strict';

// ============================================================================
// Применение миграций БД.
//
//   node db/migrate.js            применить непримененные миграции
//   node db/migrate.js --status   показать состояние, ничего не менять
//
// Миграции — файлы db/migrations/NNN_имя.sql, применяются по возрастанию имени.
// Каждая выполняется в отдельной транзакции: при ошибке изменения этой
// миграции откатываются целиком, уже примененные остаются на месте.
//
// Учет ведется в таблице public.schema_migrations. Для каждой миграции
// сохраняется контрольная сумма: если файл изменили после применения,
// скрипт об этом предупредит — на стенде такое расхождение означает, что
// структура БД не соответствует репозиторию.
// ============================================================================

const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { Client } = require('pg');

const MIGRATIONS_DIR = path.join(__dirname, 'migrations');
const STATUS_ONLY = process.argv.includes('--status');

// Значения по умолчанию совпадают с .env.example.
const config = {
  host: process.env.DB_HOST || 'localhost',
  port: Number(process.env.DB_PORT || 5433),
  database: process.env.DB_NAME || 'military',
  user: process.env.DB_USER || 'military',
  password: process.env.DB_PASSWORD || 'change_me',
  options: `-c timezone=${process.env.TZ || 'Asia/Krasnoyarsk'}`,
};

function checksum(text) {
  return crypto.createHash('sha256').update(text).digest('hex').slice(0, 16);
}

function readMigrations() {
  if (!fs.existsSync(MIGRATIONS_DIR)) {
    throw new Error(`Каталог миграций не найден: ${MIGRATIONS_DIR}`);
  }

  return fs
    .readdirSync(MIGRATIONS_DIR)
    .filter((name) => name.endsWith('.sql'))
    .sort()
    .map((name) => {
      const sql = fs.readFileSync(path.join(MIGRATIONS_DIR, name), 'utf8');
      return { name, sql, checksum: checksum(sql) };
    });
}

async function main() {
  const client = new Client(config);

  try {
    await client.connect();
  } catch (err) {
    console.error(`Не удалось подключиться к БД ${config.user}@${config.host}:${config.port}/${config.database}`);
    console.error(`  ${err.message}`);
    console.error('Проверьте, что контейнер запущен: docker compose ps');
    process.exit(1);
  }

  try {
    if(!STATUS_ONLY) await client.query('SELECT pg_advisory_lock(734821)');
    if (!STATUS_ONLY) await client.query(`
      CREATE TABLE IF NOT EXISTS public.schema_migrations (
        name       text PRIMARY KEY,
        checksum   text        NOT NULL,
        applied_at timestamptz NOT NULL DEFAULT now()
      )
    `);

    const exists=await client.query("SELECT to_regclass('public.schema_migrations') AS name");
    const { rows } = exists.rows[0].name ? await client.query('SELECT name, checksum FROM public.schema_migrations') : {rows:[]};
    const applied = new Map(rows.map((r) => [r.name, r.checksum]));

    const migrations = readMigrations();
    if (migrations.length === 0) {
      console.log('Миграций не найдено.');
      return;
    }

    let pending = 0;

    for (const migration of migrations) {
      const appliedChecksum = applied.get(migration.name);

      if (appliedChecksum === undefined) {
        pending += 1;

        if (STATUS_ONLY) {
          console.log(`  ОЖИДАЕТ   ${migration.name}`);
          continue;
        }

        process.stdout.write(`  применяю  ${migration.name} ... `);
        try {
          await client.query('BEGIN');
          // Старые файлы обёрнуты в BEGIN/COMMIT. Транзакцией владеет
          // запускатель, включая запись контрольной суммы. Исходный файл
          // и его контрольная сумма при этом остаются неизменными.
          await client.query(stripTransactionWrapper(migration.sql));
          await client.query(
            'INSERT INTO public.schema_migrations (name, checksum) VALUES ($1, $2)',
            [migration.name, migration.checksum],
          );
          await client.query('COMMIT');
          console.log('готово');
        } catch (err) {
          await client.query('ROLLBACK');
          console.log('ОШИБКА');
          console.error(`\n${migration.name}: ${err.message}`);
          if (err.position) console.error(`  позиция в файле: ${err.position}`);
          process.exit(1);
        }
      } else if (appliedChecksum !== migration.checksum) {
        console.warn(`  ИЗМЕНЕН   ${migration.name} — файл правили после применения.`);
        console.warn('            Структура БД не соответствует репозиторию.');
        console.warn('            Изменения следует оформлять новой миграцией.');
      } else if (STATUS_ONLY) {
        console.log(`  применена ${migration.name}`);
      }
    }

    if (!STATUS_ONLY) {
      console.log(pending === 0 ? 'Новых миграций нет, БД в актуальном состоянии.' : `Применено миграций: ${pending}.`);
    }
  } finally {
    await client.end();
  }
}

function stripTransactionWrapper(sql) {
 return sql.replace(/^\s*(?:BEGIN|COMMIT);[ \t]*$/gm, '');
}
module.exports={stripTransactionWrapper};
if(require.main===module) main().catch((err) => {
  console.error(err);
  process.exit(1);
});
