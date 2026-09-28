'use strict';

// Творительный падеж для строк приказа: «за лейтенантом Ивановым И.И.».
//
// Склоняются воинские звания справочника и фамилии по правилам русского
// языка для типовых окончаний. Нестандартные фамилии (Шевченко, Черных,
// Дюма) не склоняются — так и положено. Пол в учете не хранится и берется
// из отчества (-вич / -вна), без отчества — из окончания фамилии.

/** Одно слово звания: младший → младшим, рядовой → рядовым, старшина → старшиной. */
function rankWord(word) {
  if (/ий$/.test(word)) return `${word.slice(0, -2)}им`;
  if (/(ый|ой)$/.test(word)) return `${word.slice(0, -2)}ым`;
  if (/а$/.test(word)) return `${word.slice(0, -1)}ой`;
  if (/[ьй]$/.test(word)) return `${word.slice(0, -1)}ем`;
  if (/[а-яё]$/.test(word)) return `${word}ом`;
  return word;
}

/** Звание в творительном: «старший лейтенант» → «старшим лейтенантом». */
function rank(name) {
  if (!name) return '';
  return String(name).trim().split(/\s+/).map((word) => {
    // «генерал-майор»: склоняется последняя часть.
    const parts = word.split('-');
    parts[parts.length - 1] = rankWord(parts[parts.length - 1]);
    return parts.join('-');
  }).join(' ');
}

function isFemale({ lastName, middleName }) {
  const middle = String(middleName || '').toLowerCase();
  if (/(вна|чна|шна|кызы)$/.test(middle)) return true;
  if (/(вич|ич|оглы)$/.test(middle)) return false;
  return /(ова|ева|ёва|ина|ына|ская|цкая|ая)$/.test(String(lastName || '').toLowerCase());
}

function surnamePart(part, female) {
  const low = part.toLowerCase();
  const cut = (n, tail) => part.slice(0, part.length - n) + tail;

  if (female) {
    if (/(ов|ев|ёв|ин|ын)а$/.test(low)) return cut(1, 'ой');
    if (/ая$/.test(low)) return cut(2, 'ой');
    if (/а$/.test(low)) return cut(1, 'ой');
    if (/я$/.test(low)) return cut(1, 'ей');
    return part;
  }

  if (/(ов|ев|ёв|ин|ын)$/.test(low)) return `${part}ым`;
  if (/(ский|цкий)$/.test(low)) return cut(2, 'им');
  if (/(ый|ой)$/.test(low)) return cut(2, 'ым');
  if (/ий$/.test(low)) return cut(2, 'им');
  if (/(их|ых)$/.test(low)) return part;
  if (/а$/.test(low)) return cut(1, 'ой');
  if (/я$/.test(low)) return cut(1, 'ей');
  if (/[ьй]$/.test(low)) return cut(1, 'ем');
  if (/ц$/.test(low)) return `${part}ем`;
  if (/[бвгджзклмнпрстфхчшщ]$/.test(low)) return `${part}ом`;
  return part;
}

/** Фамилия в творительном; двойная склоняется по частям. */
function surname(person) {
  const female = isFemale(person);
  return String(person.lastName || '').split('-').map((p) => surnamePart(p, female)).join('-');
}

function initials({ firstName, middleName }) {
  return [firstName, middleName].filter(Boolean).map((x) => `${x.trim()[0].toUpperCase()}.`).join('');
}

/**
 * «лейтенантом Ивановым И.И.»
 * @param {{rankName?:string, lastName:string, firstName?:string, middleName?:string}} person
 */
function instrumental(person) {
  return [rank(person.rankName), surname(person), initials(person)].filter(Boolean).join(' ');
}

/**
 * Должность ВРИО: «Командир части» → «Врио командира части», «Начальник
 * штаба» → «Врио начальника штаба». Склоняется первое слово должности.
 */
function actingTitle(title) {
  const words = String(title || 'Командир').trim().split(/\s+/);
  const first = words[0].toLowerCase();
  let genitive = first;
  if (/[ьй]$/.test(first)) genitive = `${first.slice(0, -1)}я`;
  else if (/а$/.test(first)) genitive = `${first.slice(0, -1)}ы`;
  else if (/[бвгджзклмнпрстфхцчшщ]$/.test(first)) genitive = `${first}а`;
  return ['Врио', genitive, ...words.slice(1)].join(' ');
}

/**
 * Все падежные формы фамилии (именительный … предложный) — для узнавания
 * человека в тексте приказа, где он может стоять в любом падеже.
 * Двойная фамилия склоняется по частям. Несклоняемые — одной формой.
 */
function surnameForms(person) {
  const female = isFemale(person);
  const one = (part) => {
    const low = part.toLowerCase();
    const cut = (n) => part.slice(0, part.length - n);
    const out = [part];
    const add = (...xs) => out.push(...xs);
    if (female) {
      if (/(ов|ев|ёв|ин|ын)а$/.test(low)) add(`${cut(1)}ой`, `${cut(1)}у`);
      else if (/(ская|цкая)$/.test(low) || /ая$/.test(low)) add(`${cut(2)}ой`, `${cut(2)}ую`);
      else if (/а$/.test(low)) add(`${cut(1)}ы`, `${cut(1)}и`, `${cut(1)}е`, `${cut(1)}у`, `${cut(1)}ой`);
      else if (/я$/.test(low)) add(`${cut(1)}и`, `${cut(1)}е`, `${cut(1)}ю`, `${cut(1)}ей`);
      return out;
    }
    if (/(ов|ев|ёв|ин|ын)$/.test(low)) add(`${part}а`, `${part}у`, `${part}ым`, `${part}е`);
    else if (/(ский|цкий)$/.test(low) || /ий$/.test(low)) add(`${cut(2)}ого`, `${cut(2)}ому`, `${cut(2)}им`, `${cut(2)}ом`);
    else if (/(ый|ой)$/.test(low)) add(`${cut(2)}ого`, `${cut(2)}ому`, `${cut(2)}ым`, `${cut(2)}ом`);
    else if (/(их|ых|[еиоуэюы])$/.test(low)) return out;
    else if (/а$/.test(low)) add(`${cut(1)}ы`, `${cut(1)}и`, `${cut(1)}е`, `${cut(1)}у`, `${cut(1)}ой`);
    else if (/я$/.test(low)) add(`${cut(1)}и`, `${cut(1)}е`, `${cut(1)}ю`, `${cut(1)}ей`);
    else if (/[ьй]$/.test(low)) add(`${cut(1)}я`, `${cut(1)}ю`, `${cut(1)}ем`, `${cut(1)}е`);
    else if (/[бвгджзклмнпрстфхцчшщ]$/.test(low)) add(`${part}а`, `${part}у`, `${part}ом`, `${part}ем`, `${part}е`);
    return out;
  };
  const parts = String(person.lastName || '').split('-').map(one);
  if (parts.length === 1) return [...new Set(parts[0])];
  // Двойная: части склоняются согласованно — берется одна и та же позиция.
  const n = Math.min(...parts.map((p) => p.length));
  const forms = [];
  for (let i = 0; i < n; i += 1) forms.push(parts.map((p) => p[i]).join('-'));
  return [...new Set([...forms, parts.map((p) => p[0]).join('-')])];
}

module.exports = { instrumental, rank, surname, isFemale, actingTitle, surnameForms };
