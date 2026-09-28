'use strict';

// Журнал изменений (МС-4): чтение и понятная подача — разделы и поля
// по-русски, номера людей, подразделений, постов и видов нарядов — именами.

const queries = require('./queries');

const TABLES = {
  'personnel.employees': 'Личный состав',
  'core.positions': 'Штат (должности)',
  'core.units': 'Подразделения',
  'core.acting_commanders': 'ВРИО командира',
  'personnel.absences': 'Отсутствия',
  'personnel.employee_permits': 'Допуски людей',
  'personnel.permit_orders': 'Приказы на допуск',
  'personnel.permit_directions': 'Направления приказов',
  'personnel.permit_types': 'Виды допусков',
  'personnel.absence_types': 'Причины отсутствия',
  'personnel.weapons': 'Оружие',
  'personnel.employee_post_weights': 'Личные поправки к постам',
  'duty.duties': 'Наряды',
  'duty.duty_assignments': 'Назначения в наряд',
  'duty.duty_posts': 'Посты',
  'duty.duty_types': 'Виды нарядов',
  'duty.duty_type_schedules': 'Расписание видов нарядов',
  'duty.duty_type_permits': 'Допуски вида наряда',
  'duty.order_template_versions': 'Шаблоны приказов',
  'duty.post_units': 'Очередь подразделений на посту',
  'duty.post_employees': 'Закрепленные за постом',
  'duty.post_responsibilities': 'Точечное закрепление поста',
  'duty.post_rank_weights': 'Веса званий на постах',
  'core.calendar_days': 'Выходные и праздники',
  'core.settings': 'Настройки подбора',
  'core.users': 'Учетные записи',
  'core.user_permissions': 'Права пользователей',
  'core.role_permissions': 'Права ролей',
  'core.roles': 'Роли',
  'core.ranks': 'Звания',
};

const FIELDS = {
  last_name: 'фамилия', first_name: 'имя', middle_name: 'отчество', rank_id: 'звание',
  personnel_number: 'личный номер', phone: 'телефон', email: 'почта', position: 'должность',
  unit_id: 'подразделение', is_active: 'действует', excluded_on: 'исключен', exclusion_reason: 'основание исключения',
  title: 'наименование', employee_id: 'человек', is_commander: 'командирская', sort_order: 'порядок',
  name: 'наименование', short_name: 'кратко', parent_id: 'входит в', commander_employee_id: 'командир',
  is_headquarters: 'штаб', date_from: 'с', date_to: 'по', reason: 'основание', cancelled_at: 'снято',
  document_ref: 'документ', note: 'примечание', source: 'источник', absence_type_id: 'причина',
  serial_number: 'заводской номер', manufactured_on: 'дата производства', kind: 'вид', owner_id: 'закреплено за',
  post_id: 'пост', duty_type_id: 'вид наряда', duty_id: 'наряд', on_date: 'сутки', weapon_id: 'оружие',
  status: 'состояние', starts_at: 'заступление', ends_at: 'сдача', start_date: 'дата', approved_at: 'утвержден',
  role_code: 'роль', scope_unit_id: 'зона', login: 'учетная запись', permission_code: 'право', granted: 'выдано',
  weight: 'вес', code: 'обозначение', required_weapon_kind: 'оружие на посту', required_permit_type_id: 'допуск к посту',
  allow_consecutive: 'подряд', order_template: 'шаблон приказа', version: 'версия', template: 'шаблон',
  permit_type_id: 'вид допуска', issued_at: 'выдан', expires_at: 'до', order_id: 'приказ',
};

// Какие поля — ссылки на что: подписываются именами.
const REFS = {
  employee_id: 'employee', owner_id: 'employee', commander_employee_id: 'employee',
  unit_id: 'unit', parent_id: 'unit', scope_unit_id: 'unit',
  post_id: 'post', duty_type_id: 'type',
};
const ACTIONS = { insert: 'добавлено', update: 'изменено', delete: 'удалено' };
// Служебное — в перечне изменений не показывается.
const HIDDEN = new Set(['id', 'created_at', 'created_by', 'noted_by', 'noted_at', 'cancelled_by',
  'override_by', 'unapproved_at', 'unapproved_by', 'approved_by', 'approved_snapshot', 'order_snapshot']);

function show(value, key, names) {
  if (value === null || value === undefined || value === '') return '—';
  if (REFS[key] && names.has(`${REFS[key]}:${value}`)) return names.get(`${REFS[key]}:${value}`);
  if (value === true) return 'да';
  if (value === false) return 'нет';
  if (value === 'infinity') return 'без срока';
  if (typeof value === 'object') return 'изменено';
  const text = String(value);
  if (/^\d{4}-\d{2}-\d{2}/.test(text)) {
    const [y, m, d] = text.slice(0, 10).split('-');
    return `${d}.${m}.${y}${text.length > 10 && text[10] === 'T' ? ` ${text.slice(11, 16)}` : ''}`;
  }
  return text.length > 120 ? `${text.slice(0, 117)}…` : text;
}

/** Журнал с фильтрами — готовый к показу. */
async function journal(filters) {
  const limit = 200;
  const rows = await queries.listChanges({ ...filters, limit });

  // Подписи к номерам — одним запросом на страницу.
  const ids = { employee: new Set(), unit: new Set(), post: new Set(), type: new Set() };
  for (const r of rows) {
    if (r.table_name === 'personnel.employees' && r.row_id) ids.employee.add(Number(r.row_id));
    for (const data of [r.old_data, r.new_data]) {
      for (const [k, val] of Object.entries(data || {})) {
        if (REFS[k] && Number.isInteger(Number(val)) && val !== null) ids[REFS[k]].add(Number(val));
      }
    }
  }
  const names = new Map((await queries.labels({
    employee: [...ids.employee], unit: [...ids.unit], post: [...ids.post], type: [...ids.type],
  })).map((l) => [`${l.kind}:${l.id}`, l.label]));

  const items = rows.map((r) => {
    const keys = [...new Set([...Object.keys(r.old_data || {}), ...Object.keys(r.new_data || {})])]
      .filter((k) => !HIDDEN.has(k));
    const changes = keys.map((k) => ({
      field: FIELDS[k] || k,
      from: r.action === 'insert' ? null : show((r.old_data || {})[k], k, names),
      to: r.action === 'delete' ? null : show((r.new_data || {})[k], k, names),
    })).filter((c) => r.action !== 'update' || c.from !== c.to);
    // О ком / о чем запись: человек, иначе подпись самой записи.
    const data = r.new_data || r.old_data || {};
    const person = r.table_name === 'personnel.employees' ? names.get(`employee:${r.row_id}`)
      : (data.employee_id ? names.get(`employee:${data.employee_id}`) : null);
    return {
      id: r.id, at: r.changed_at, author: r.login || (r.user_id ? `№ ${r.user_id}` : 'система'),
      section: TABLES[r.table_name] || r.table_name, table: r.table_name, rowId: r.row_id,
      action: ACTIONS[r.action], actionCode: r.action,
      subject: person || data.title || data.name || data.short_name || data.serial_number || (r.row_id ? `№ ${r.row_id}` : ''),
      changes,
    };
  });
  return { items, more: rows.length === limit, lastId: rows.length ? rows[rows.length - 1].id : null };
}

module.exports = { journal, listAuthors: queries.listAuthors, TABLES };
