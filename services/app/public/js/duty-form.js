'use strict';
(function(){
 const type=document.getElementById('dutyTypeId');const date=document.getElementById('startDate');
 const box=document.getElementById('candidates');if(!type||!date||!box)return;
 let pending;
 async function load(){
  pending?.abort();pending=new AbortController();const request=pending;
  if(!type.value||!date.value){box.textContent='Выберите вид наряда и дату.';return;}
  box.textContent='Подбор кандидатов…';
  try {
   const response=await fetch('/duties/candidates?'+new URLSearchParams({dutyTypeId:type.value,date:date.value}),{signal:request.signal});
   const html=await response.text();if(request!==pending)return;
   if(!response.ok){box.textContent='Не удалось подобрать состав. Проверьте дату и вид наряда.';return;}
   box.innerHTML=html;filterSelected();
  }catch(e){if(e.name!=='AbortError'&&request===pending)box.textContent='Не удалось получить список кандидатов.';}
 }
 function filterSelected(){
  const selects=[...box.querySelectorAll('select[name^="post_"]')];
  for(const select of selects){const used=new Set(selects.filter(s=>s!==select).map(s=>s.value).filter(Boolean));
   for(const option of select.options){option.disabled=Boolean(option.value)&&used.has(option.value)&&option.value!==select.value;}
  }
 }
 type.addEventListener('change',load);date.addEventListener('change',load);box.addEventListener('change',filterSelected);
 if(type.value&&date.value)load();
})();
