'use strict';
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const vm = require('node:vm');
const { createHash } = require('node:crypto');
const source = fs.readFileSync(path.resolve(__dirname, '../../scripts/backup.js'), 'utf8');

// Настоящие файловые операции во временном каталоге; Docker заменён фиктивным pg_dump.
function runBackup(root, spawnSync) {
  vm.runInNewContext(source, {
    __dirname: path.join(root, 'scripts'),
    process: { env: { DB_NAME: 'military_review_test', DOC_STORAGE: path.join(root, 'documents') }, chdir() {} },
    console: { log() {} },
    require: name => name === 'node:child_process' ? { spawnSync } : require(name),
  }, { filename: 'scripts/backup.js' });
}
exports.backupContents = async t => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'backup-check-'));
  try {
    const storage = path.join(root, 'documents', 'permit-orders');
    fs.mkdirSync(storage, { recursive: true });
    const original = Buffer.from('%PDF synthetic document');
    fs.writeFileSync(path.join(storage, 'Приказ.pdf'), original);
    runBackup(root, (command, args, options) => {
      t.is(command, 'docker', 'Используется Docker');
      t.ok(args.includes('military_review_test'), 'Выбрана тестовая БД');
      fs.writeSync(options.stdio[1], Buffer.from('synthetic database dump'));
      return { status: 0 };
    });
    const names = fs.readdirSync(path.join(root, 'backups'));
    t.is(names.length, 1, 'Создана одна копия');
    t.is(names[0].endsWith('.partial'), false, 'Копия опубликована только после завершения');
    const backup = path.join(root, 'backups', names[0]);
    const manifest = JSON.parse(fs.readFileSync(path.join(backup, 'manifest.json')));
    t.is(manifest.storage, path.join(root, 'documents'), 'Нестандартный DOC_STORAGE сохранён');
    t.is(Object.keys(manifest.files).sort(), ['database.dump', 'storage/permit-orders/Приказ.pdf'], 'Дамп и документ включены в манифест');
    for (const [name, hash] of Object.entries(manifest.files)) {
      t.is(createHash('sha256').update(fs.readFileSync(path.join(backup, name))).digest('hex'), hash, 'SHA-256 соответствует содержимому');
    }
    const restored = path.join(root, 'restored');
    fs.cpSync(path.join(backup, 'storage'), restored, { recursive: true });
    t.is(fs.readFileSync(path.join(restored, 'permit-orders', 'Приказ.pdf')), original, 'Документ восстанавливается побайтно');
  } finally { fs.rmSync(root, { recursive: true, force: true }); }
};
exports.backupFailureCleanup = async t => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'backup-failure-'));
  try {
    for (const result of [{ status: 1 }, { error: new Error('docker unavailable') }]) {
      let failed = false;
      try { runBackup(root, () => result); } catch { failed = true; }
      t.is(failed, true, 'Ошибка создания дампа передана');
      t.is(fs.readdirSync(path.join(root, 'backups')), [], 'Незавершённая копия удалена');
    }
  } finally { fs.rmSync(root, { recursive: true, force: true }); }
};
