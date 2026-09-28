'use strict';
function fail(message, status=400) { throw Object.assign(new Error(message), {status, userMessage:true}); }
function isDate(value) {
 if (typeof value!=='string' || !/^\d{4}-\d{2}-\d{2}$/.test(value)) return false;
 const [y,m,d]=value.split('-').map(Number);
 if(y<1900 || y>9998) return false;
 const parsed=new Date(y,m-1,d,12);
 return parsed.getFullYear()===y && parsed.getMonth()===m-1 && parsed.getDate()===d;
}
function date(value) { if(!isDate(value)) fail('Некорректная календарная дата.'); return value; }
function id(value) { const n=Number(value); if(!Number.isSafeInteger(n)||n<=0||n>2147483647) fail('Некорректный идентификатор.'); return n; }
function future(value) { date(value); const now=new Date(); const today=`${now.getFullYear()}-${String(now.getMonth()+1).padStart(2,'0')}-${String(now.getDate()).padStart(2,'0')}`; if(value<=today) fail('Текущие и прошедшие сутки изменять нельзя.'); return value; }
/**
 * Новый порядок списка после перетаскивания — одна проверка для всех
 * списков. Принимается только ПОЛНЫЙ перечень без повторов: частичный
 * оставил бы пропущенные элементы со старыми номерами вперемешку с новыми,
 * а устаревший (кто-то добавил элемент, пока страница была открыта) молча
 * переставил бы не то.
 */
function order(raw, ownIds) {
 const ids=(Array.isArray(raw) ? raw : [raw]).filter((x)=>x!==undefined && x!=='').map(id);
 if(new Set(ids).size!==ids.length) fail('Элемент в перечне повторяется.');
 const own=new Set(ownIds);
 if(ids.length!==own.size || !ids.every((x)=>own.has(x))) fail('Перечень устарел — обновите страницу.');
 return ids;
}
module.exports={fail,isDate,date,id,future,order};
