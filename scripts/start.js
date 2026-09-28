'use strict';
const path=require('node:path');
const fs=require('node:fs');
const {spawn}=require('node:child_process');
const root=path.resolve(__dirname,'..');
process.chdir(root);
if(!fs.existsSync('.env')) {
 fs.copyFileSync('.env.example','.env');
 const crypto=require('node:crypto');
 fs.writeFileSync('.env',fs.readFileSync('.env','utf8').replace('DB_PASSWORD=change_me','DB_PASSWORD='+crypto.randomBytes(24).toString('hex')),{mode:0o600});
 fs.chmodSync('.env',0o600);
 console.log('Создан .env с паролем локальной тестовой БД.');
}
process.loadEnvFile('.env');
let child;
function run(command,args) {
 return new Promise((resolve,reject)=>{
  child=spawn(command,args,{cwd:root,env:process.env,stdio:'inherit'});
  child.once('error',reject);
  child.once('exit',(code,signal)=>code===0?resolve():reject(new Error(`${command}: ${signal || `код ${code}`}`)));
 });
}
let stopping=false;
for(const signal of ['SIGINT','SIGTERM']) process.on(signal,()=>{stopping=true;if(child) child.kill(signal);});
const wait=ms=>new Promise(resolve=>setTimeout(resolve,ms));
const alive=pid=>{try {process.kill(pid,0);return true;}catch {return false;}};
// Прежние экземпляры ИМЕННО ЭТОГО приложения НА ЭТОМ ЖЕ ПОРТУ: сверяется
// полный путь к server.js, поэтому чужие процессы, занявшие порт, не
// затрагиваются — решение о них принимает человек.
//
// Порт проверяется отдельно: рядом работает тестовый экземпляр на другом
// порту и на отдельной БД (раздел 15.4), и снимать его при обычном запуске
// нельзя — проверки молча остались бы без приложения.
function previousServers() {
 const target=path.join(root,'services/app/server.js');
 const port=String(process.env.APP_PORT || '');
 const found=[];
 if(!fs.existsSync('/proc')) return found;
 for(const entry of fs.readdirSync('/proc')) {
  const pid=Number(entry);
  if(!Number.isInteger(pid) || pid===process.pid) continue;
  let args,cwd,env;
  try {
   args=fs.readFileSync(`/proc/${pid}/cmdline`,'utf8').split('\0').filter(Boolean);
   cwd=fs.readlinkSync(`/proc/${pid}/cwd`);
   env=fs.readFileSync(`/proc/${pid}/environ`,'utf8').split('\0');
  } catch {continue;}
  if(!args.some(a=>a.endsWith('server.js') && path.resolve(cwd,a)===target)) continue;
  const theirPort=(env.find(line=>line.startsWith('APP_PORT='))||'').slice('APP_PORT='.length);
  if(theirPort && port && theirPort!==port) continue;
  found.push(pid);
 }
 return found;
}
// Перезапуск вместо отказа: повторный ./start — обычный способ применить
// изменения, и требовать ручной остановки значит требовать помнить, чем
// запускали прошлый раз. Прежний экземпляр завершается штатно, чтобы он
// успел закрыть соединения с БД.
async function stopPrevious() {
 let pids=previousServers();
 if(pids.length===0) return;
 console.log(`Остановка прежнего экземпляра (${pids.join(', ')})…`);
 for(const pid of pids) try {process.kill(pid,'SIGTERM');}catch {}
 for(let i=0;i<50 && pids.length>0;i+=1) {await wait(100);pids=pids.filter(alive);}
 if(pids.length>0) {
  console.log('Штатно не завершился, снимается принудительно.');
  for(const pid of pids) try {process.kill(pid,'SIGKILL');}catch {}
  await wait(300);
 }
}
async function main() {
 for(const [dir,name] of [[root,'pg'],[path.join(root,'services/app'),'express'],[path.join(root,'services/app'),'ejs']]) {
  try {require.resolve(name,{paths:[dir]});}catch {throw new Error(`Не установлены зависимости: выполните npm ci${dir===root?'':' --prefix services/app'}. Для офлайн-стенда зависимости должны быть в поставке.`);}
 }
 console.log('Запуск PostgreSQL…');
 await run('docker',['compose','up','-d','--wait','db']);
 if(stopping) return;
 console.log('Проверка и применение миграций…');
 await run(process.execPath,['db/migrate.js']);
 if(stopping) return;
 // Первый вход: в начальном наполнении пароля администратора нет. Временный
 // выдается здесь и печатается ОДИН раз тому, кто поднимает стенд, — в базе
 // он не хранится, и повторить показ невозможно.
 try {
  const access=require(path.join(root,'services/app/modules/access/service'));
  const issued=await access.ensureInitialPassword();
  if(issued) {
   console.log('');
   console.log('  Вход в систему еще не был настроен. Выдан временный пароль:');
   console.log(`      логин:  ${issued.login}`);
   console.log(`      пароль: ${issued.password}`);
   console.log('  Он подлежит смене при первом входе. Запишите его сейчас.');
   console.log('');
  }
 } catch(e) {
  console.error('Не удалось проверить учетную запись администратора:', e.message);
 }
 if(stopping) return;
 // Прежний экземпляр снимается только теперь: если миграции не прошли,
 // работающая служба остается работать, а не заменяется неисправной.
 await stopPrevious();
 if(stopping) return;
 console.log('Запуск приложения. Остановка: Ctrl+C. Данные БД сохраняются.');
 await run(process.execPath,['services/app/server.js']);
}
main().catch(e=>{if(!stopping){console.error(e.message);process.exitCode=1;}});
