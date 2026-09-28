'use strict';
process.env.TZ='Asia/Krasnoyarsk';
const test=require('node:test');const assert=require('node:assert/strict');
const v=require('../services/app/lib/validation');
const cal=require('../services/app/modules/duty/calendar');
const filter=require('../services/app/modules/duty/candidateFilter');
const {stripTransactionWrapper}=require('../db/migrate');
test('calendar dates reject normalization and invalid values',()=>{
 for(const date of ['2026-02-30','2025-02-29','2026-13-01','0000-01-01','x']) assert.equal(v.isDate(date),false);
 assert.equal(v.isDate('2028-02-29'),true);
 assert.throws(()=>filter.computePeriod({kind:'daily'},[],'2026-02-30'));
});
test('OO holiday block includes multiple shifts',()=>{
 const exceptions=new Map(cal.daysBetween('2030-01-01','2030-01-08').map(d=>[d,'holiday']));
 const type={kind:'multiday',start_time:'17:30:00'};
 const block=cal.orderBlock(type,[{start_weekday:2,end_weekday:5},{start_weekday:5,end_weekday:2}],'2030-01-04',exceptions);
 assert.ok(block.length>=2);assert.equal(new Set(block.map(p=>cal.orderDeadline(p.startDate,exceptions))).size,1);
});
test('rest accounts for long holiday periods without truncating at 14 days',()=>{
 const exceptions=new Map(cal.daysBetween('2030-01-01','2030-01-25').map(d=>[d,'holiday']));
 const rest=cal.restDays('2030-01-01',2,true,exceptions);
 assert.ok(rest.includes('2030-01-28'));assert.ok(rest.length>25);
});
test('migration wrapper removed without removing PL/pgSQL BEGIN',()=>{
 const sql='BEGIN;\nCREATE FUNCTION x() RETURNS void AS $$\nBEGIN\n RETURN;\nEND\n$$ LANGUAGE plpgsql;\nCOMMIT;';
 const result=stripTransactionWrapper(sql);assert.ok(result.includes('\nBEGIN\n'));assert.ok(!result.includes('COMMIT;'));assert.ok(!result.startsWith('BEGIN;'));
});
