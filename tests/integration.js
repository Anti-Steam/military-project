'use strict';
// Runs exclusively against the explicitly named disposable test database.
process.env.DB_NAME='military_review_test';process.env.TZ=process.env.TZ||'Asia/Krasnoyarsk';
const assert=require('node:assert/strict');
const db=require('../services/app/db/pool');
const service=require('../services/app/modules/duty/service');
const personnel=require('../services/app/modules/personnel/service');
const cal=require('../services/app/modules/duty/calendar');
const rollback=new Error('ROLLBACK_TEST_DATA');
let checks=0;
async function check(name,fn) {await fn();checks++;console.log('OK:',name);}
async function scalar(sql,params=[]) {return (await db.query(sql,params)).rows[0];}
async function main() {
 try {await db.transaction(async()=>{
  const unit=(await scalar('SELECT id FROM core.units WHERE parent_id IS NULL LIMIT 1')).id;
  const admin=(await scalar("SELECT id FROM core.users WHERE role_code='admin' LIMIT 1")).id;
  const type=(await scalar("INSERT INTO duty.duty_types(code,name,kind,start_time,duration_hours,recovery_sleep_days,recovery_off_days,rest_excludes_weekends,base_weight) VALUES('TEST_REVIEW','Тест','daily','10:00',24,1,1,false,1) RETURNING id")).id;
  const post=(await scalar("INSERT INTO duty.duty_posts(duty_type_id,name) VALUES($1,'Тестовый пост') RETURNING id",[type])).id;
  const employees=[];
  for(let i=0;i<8;i++) employees.push((await scalar("INSERT INTO personnel.employees(last_name,first_name,unit_id) VALUES($1,'Синтетический',$2) RETURNING id",['Тест'+i,unit])).id);
  const create=(date,emp=employees[0])=>service.createDuty({dutyTypeId:type,startDate:date,unitId:unit,assignments:[{postId:post,employeeId:emp}],userId:admin});
  const first=await create('2030-01-02');
  await check('duplicate duty rejected',async()=>assert.rejects(()=>create('2030-01-02'),/существует/));
  await check('past date rejected',async()=>assert.rejects(()=>create('2020-01-01'),/прошедшие/));
  await check('rest is checked when saving',async()=>assert.rejects(()=>create('2030-01-03'),/отсыпной/));
  await db.query("INSERT INTO personnel.absences(employee_id,absence_type_id,date_from,date_to) SELECT $1,id,'2030-01-06','2030-01-06' FROM personnel.absence_types WHERE code='OTHER'",[employees[1]]);
  await check('absence on handover day blocks assignment',async()=>assert.rejects(()=>create('2030-01-05',employees[1]),/отсутствует/));
  await check('draft cannot be printed',async()=>assert.rejects(()=>service.getPrintableOrder(first.dutyId),/утверждённого/));
  await service.approveBlock(type,'2030-01-02',null,admin);
  await check('approved complete order printed',async()=>assert.equal((await service.getPrintableOrder(first.dutyId)).sections.length,1));
  await check('admin override of absence persists and permits approval',async()=>{
   await service.saveBlock({dutyTypeId:type,date:'2030-01-05',byDate:new Map(cal.orderBlock({kind:'daily',start_time:'10:00:00'},[],'2030-01-05',new Map()).map((p,i)=>[p.startDate,new Map([[post,employees[i+2]]])])),userId:admin});
   const duty=(await scalar('SELECT id FROM duty.duties WHERE duty_type_id=$1 AND start_date=$2',[type,'2030-01-05'])).id;
   await service.replaceMember({dutyId:duty,postId:post,employeeId:employees[1],note:'Тест исключения',userId:admin,override:true});
   const plan=await service.getBlockPlan(type,'2030-01-05',null);assert.equal(plan.brokenTotal,0);
   await service.approveBlock(type,'2030-01-05',null,admin);
  });
  await check('withdrawal unapproves entire weekend order',async()=>{
   await service.withdrawEmployee({employeeId:employees[1],dateFrom:'2030-01-05',dateTo:'2030-01-05',documentRef:'ТЕСТ',userId:admin});
   const rows=(await db.query("SELECT status FROM duty.duties WHERE duty_type_id=$1 AND start_date BETWEEN '2030-01-05' AND '2030-01-07'",[type])).rows;
   assert.ok(rows.length===3 && rows.every(r=>r.status==='draft'));
  });
  await check('calendar change unapproves affected future order',async()=>{
   await service.setCalendarRange('2030-01-01','2030-01-01','holiday','Тестовый праздник',admin);
   assert.equal((await scalar('SELECT status FROM duty.duties WHERE id=$1',[first.dutyId])).status,'draft');
  });
  await db.query("UPDATE duty.duty_posts SET required_weapon_kind='rifle' WHERE id=$1",[post]);
  const weapon=(await scalar("INSERT INTO personnel.weapons(name,serial_number,manufactured_on,kind,owner_id) VALUES('Тест автомат','REVIEW-LOAN','2020-01-01','rifle',$1) RETURNING id",[employees[6]])).id;
  const block=(date,emp,weaponId)=>service.saveBlock({dutyTypeId:type,date,byDate:new Map([[date,new Map([[post,emp]])]]),
   weapons:new Map([[date,new Map([[post,weaponId]])]]),userId:admin});
  await check('person without weapon can be assigned, but order is not approved until a weapon is chosen',async()=>{
   await block('2030-02-01',employees[5],null);
   await assert.rejects(()=>service.approveBlock(type,'2030-02-01',null,admin),/не выбрано оружие/);
  });
  const loanDuty=(await scalar("SELECT id,starts_at,ends_at FROM duty.duties WHERE duty_type_id=$1 AND start_date='2030-02-01'",[type]));
  await check('weapon chosen at assignment is lent for the duty and the order can be approved',async()=>{
   await block('2030-02-01',employees[5],weapon);
   assert.equal((await scalar('SELECT weapon_id FROM duty.duty_assignments WHERE duty_id=$1',[loanDuty.id])).weapon_id,weapon);
   await service.approveBlock(type,'2030-02-01',null,admin);
   const order=await service.getPrintableOrder(loanDuty.id);
   assert.match(order.sections[0].roster[0].weapon.orderLine,/^За .* закрепить автомат № REVIEW-LOAN 2020 г\.$/);
  });
  await check('same weapon cannot be lent to an overlapping neighbour',async()=>assert.rejects(()=>block('2030-02-02',employees[7],weapon),/уже выдано/));
  await check('weapon of an owner on duty in these or next days is rejected',async()=>{
   await block('2030-02-10',employees[6],null);
   await assert.rejects(()=>block('2030-02-09',employees[7],weapon),/владелец/);
  });
  await check('invalid block rejected without writes',async()=>{
   const before=(await scalar('SELECT count(*)::int AS n FROM duty.duties WHERE duty_type_id=$1',[type])).n;
   await assert.rejects(()=>service.saveBlock({dutyTypeId:type,date:'2030-03-02',byDate:new Map([['2030-03-02',new Map([[post,employees[0]]])],['2030-03-03',new Map([[post,employees[0]]])]]),userId:admin}));
   assert.equal((await scalar('SELECT count(*)::int AS n FROM duty.duties WHERE duty_type_id=$1',[type])).n,before);
  });
  await check('post without required permit offers active people once each',async()=>{
   await db.query('UPDATE duty.duty_posts SET required_weapon_kind=NULL WHERE id=$1',[post]);
   const result=await service.findCandidatesByPost(type,'2030-05-01');
   const candidates=result.posts[0].candidates;assert.ok(candidates.some(c=>c.id===employees[0]));assert.equal(candidates.length,new Set(candidates.map(c=>c.id)).size);
  });
  await check('shared role permit covers posts in different units',async()=>{
   const posts=(await db.query("SELECT id,required_permit_type_id FROM duty.duty_posts WHERE name LIKE 'Дневальный по %' ORDER BY id")).rows;
   assert.ok(posts.length>=2);assert.equal(new Set(posts.map(p=>p.required_permit_type_id)).size,1);
   await db.query("INSERT INTO personnel.employee_permits(employee_id,permit_type_id,issued_at,expires_at,status) VALUES($1,$2,'2020-01-01','2040-01-01','active')",[employees[0],posts[0].required_permit_type_id]);
   const result=await personnel.findCandidatesForPosts('2030-05-01',[],posts,'2030-05-01T10:00:00+07:00','2030-05-02T10:00:00+07:00');
   assert.ok(posts.every(p=>result.get(p.id).some(e=>e.id===employees[0])));
  });
  await check('ordinary chief cannot override but may receive transfer authority',async()=>{
   const access=require('../services/app/modules/access/service');
   assert.equal(access.can({role_code:'chief'},'duty.override'),false);
   assert.equal(access.can({role_code:'chief'},'weapon.transfer'),false);
   assert.equal(access.can({role_code:'chief',permissions:new Set(['weapon.transfer'])},'weapon.transfer'),true);
   assert.equal(access.can({role_code:'admin',permissions:new Set(['duty.override'])},'duty.override'),true);
  });
  await check('empty post does not become filled when another post is disabled',async()=>{
   const extra=(await scalar("INSERT INTO duty.duty_posts(duty_type_id,name) VALUES($1,'Ещё один пост') RETURNING id",[type])).id;
   const plan=await service.getBlockPlan(type,'2030-02-01',null);assert.equal(plan.unfilledTotal,1);
   await assert.rejects(()=>service.getPrintableOrder(loanDuty.id),/неполный/);
   await db.query('UPDATE duty.duty_posts SET is_active=false WHERE id=$1',[extra]);
  });
  await check('replacing the person drops the lent weapon with the old assignment',async()=>{
   await db.query("UPDATE duty.duty_posts SET required_weapon_kind='rifle' WHERE id=$1",[post]);
   await service.replaceMember({dutyId:loanDuty.id,postId:post,employeeId:employees[7],note:'Тест замены',userId:admin});
   assert.equal((await scalar('SELECT weapon_id FROM duty.duty_assignments WHERE duty_id=$1',[loanDuty.id])).weapon_id,null);
  });
  const accessQueries = require('../services/app/modules/access/queries');
  const sessionId = require('node:crypto').randomBytes(32).toString('base64url');
  await db.query('UPDATE core.users SET must_change_password=false WHERE id=$1',[admin]);
  await accessQueries.createSession({id:sessionId,userId:admin,csrfToken:'review-token',expiresAt:new Date(Date.now()+3600000)});
  // Render every changed page using the same locals/routes as the application.
  const {app}=require('../services/app/server');
  const http=require('node:http');const server=http.createServer(app);
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
  try {
   const base='http://127.0.0.1:'+server.address().port;
   for(const route of ['/','/duties?month=2026-08','/posts/new','/posts/'+post+'/edit','/personnel','/weapons',`/duties/${first.dutyId}`,`/duties/plan?type=${type}&date=2030-01-05`,`/duties/approve?type=${type}&date=2030-01-05`]) {
    await check('HTTP '+route,async()=>{const response=await fetch(base+route,{headers:{cookie:`sid=${sessionId}`},redirect:'manual'});const body=await response.text();assert.equal(response.status,200,body.slice(-700));assert.ok(!body.includes('<h1>Вход</h1>')); });
   }
  } finally {await new Promise(resolve=>server.close(resolve));}
  throw rollback;
 });} catch(e) {if(e!==rollback) throw e;}
 await atomicWriteCheck();
 await require('./review-integration')(db, check);
 console.log(`Integration checks passed: ${checks}. Test records rolled back.`);
}
async function atomicWriteCheck() {
 const queries=require('../services/app/modules/duty/queries');
 const fixture=await db.transaction(async()=>{
   const type=(await scalar("INSERT INTO duty.duty_types(code,name,kind,start_time,duration_hours,recovery_sleep_days,recovery_off_days,rest_excludes_weekends,base_weight) VALUES('TEST_ATOMIC','Проверка отката','daily','10:00',24,1,1,false,1) RETURNING id")).id;
   const post=(await scalar("INSERT INTO duty.duty_posts(duty_type_id,name) VALUES($1,'Тест отката') RETURNING id",[type])).id;
   const employees=(await db.query('SELECT id FROM personnel.employees WHERE is_active ORDER BY id LIMIT 2')).rows.map(r=>r.id);
   return {type,post,employees};
 });
 const original=queries.createDuty;let calls=0;
 try {
  queries.createDuty=async data=>{if(++calls===2)throw new Error('TEST_SECOND_WRITE_FAILURE');return original(data);};
  await check('transaction rolls back first day when second write fails',async()=>{
   await assert.rejects(()=>service.saveBlock({dutyTypeId:fixture.type,date:'2030-03-02',
    byDate:new Map([['2030-03-02',new Map([[fixture.post,fixture.employees[0]]])],['2030-03-03',new Map([[fixture.post,fixture.employees[1]]])]])}),/TEST_SECOND_WRITE_FAILURE/);
   assert.equal(calls,2);
   assert.equal((await scalar('SELECT count(*)::int AS n FROM duty.duties WHERE duty_type_id=$1',[fixture.type])).n,0);
  });
  queries.createDuty=original;
  await check('simultaneous creation cannot duplicate daily duty',async()=>{
   const data={dutyTypeId:fixture.type,startDate:'2030-03-20',assignments:[{postId:fixture.post,employeeId:fixture.employees[0]}]};
   const results=await Promise.allSettled([service.createDuty(data),service.createDuty(data)]);
   assert.equal(results.filter(r=>r.status==='fulfilled').length,1);
   assert.equal((await scalar('SELECT count(*)::int AS n FROM duty.duties WHERE duty_type_id=$1',[fixture.type])).n,1);
  });
  await check('disabling post releases future assignments',async()=>{
   await service.updatePost(fixture.post,{name:'Тест отката',isActive:false});
   assert.equal((await scalar('SELECT count(*)::int AS n FROM duty.duty_assignments WHERE post_id=$1',[fixture.post])).n,0);
  });
 }finally {
  queries.createDuty=original;
  await db.transaction(async()=>{
   await db.query('DELETE FROM duty.duties WHERE duty_type_id=$1',[fixture.type]);
   await db.query('DELETE FROM duty.duty_posts WHERE duty_type_id=$1',[fixture.type]);
   await db.query('DELETE FROM duty.duty_types WHERE id=$1',[fixture.type]);
  });
 }
}
main().catch(e=>{console.error(e);process.exitCode=1;}).finally(()=>db.pool.end());
