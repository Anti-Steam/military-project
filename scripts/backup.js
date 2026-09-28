'use strict';
const fs = require('node:fs');
const path = require('node:path');
const { createHash } = require('node:crypto');
const { spawnSync } = require('node:child_process');
const root = path.resolve(__dirname, '..');
process.chdir(root);
const storage = path.resolve(process.env.DOC_STORAGE || path.join(root, 'storage'));
const dir = path.join(root, 'backups');
fs.mkdirSync(dir, { recursive: true });
const target = path.join(dir, 'backup-' + new Date().toISOString().replace(/[:.]/g, '-'));
const partial = target + '.partial';
fs.mkdirSync(partial, { mode: 0o700 });
try {
  const fd = fs.openSync(path.join(partial, 'database.dump'), 'wx', 0o600);
  try {
    const result = spawnSync('docker', ['compose', 'exec', '-T', 'db', 'pg_dump', '-U',
      process.env.DB_USER || 'military', '-Fc', process.env.DB_NAME || 'military'],
    { stdio: ['ignore', fd, 'inherit'] });
    if (result.error) throw result.error;
    if (result.status !== 0) throw new Error('Не удалось создать резервную копию БД.');
    fs.fsyncSync(fd);
  } finally { fs.closeSync(fd); }
  // Опубликованные файлы неизменяемы и сохраняются после замены/удаления приказа.
  // Поэтому все файлы снимка БД остаются доступны после завершения pg_dump.
  if (fs.existsSync(storage)) fs.cpSync(storage, path.join(partial, 'storage'), { recursive: true, dereference: true });
  else fs.mkdirSync(path.join(partial, 'storage'));
  const files = {};
  function hashTree(folder) {
    for (const item of fs.readdirSync(folder, { withFileTypes: true })) {
      const file = path.join(folder, item.name);
      if (item.isDirectory()) hashTree(file);
      else files[path.relative(partial, file)] = createHash('sha256').update(fs.readFileSync(file)).digest('hex');
    }
  }
  hashTree(partial);
  fs.writeFileSync(path.join(partial, 'manifest.json'), JSON.stringify({ storage, files }, null, 2), { mode: 0o600 });
  fs.renameSync(partial, target);
  console.log('Резервная копия БД и документов: ' + target);
} catch (err) {
  fs.rmSync(partial, { recursive: true, force: true });
  throw err;
}
