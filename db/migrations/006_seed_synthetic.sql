-- ============================================================================
-- 006_seed_synthetic.sql
-- Синтетические данные для апробации.
--
-- ⚠️ ВСЕ ДАННЫЕ ВЫМЫШЛЕНЫ. Раздел 2 ТЗ: реальные сведения о личном составе
--    на стенд не переносятся. Фамилии, должности, номера приказов и телефоны
--    сгенерированы и не соответствуют ни одному действующему лицу.
--
-- Состав допусков задан НЕРАВНОМЕРНО намеренно: нужны действующие,
-- просроченные, приостановленные и отсутствующие допуски, иначе отбор
-- кандидатов проверяется на идеальных данных и краевые случаи не всплывают.
--
-- Сроки заданы относительно CURRENT_DATE, поэтому набор не «протухает»
-- со временем.
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- Оргструктура: корень и четыре подчиненных подразделения.
-- ----------------------------------------------------------------------------
INSERT INTO core.units (name, short_name, parent_id, sort_order) VALUES
    ('Войсковая часть 00000 (условная)', 'в/ч 00000', NULL, 0)
ON CONFLICT DO NOTHING;

INSERT INTO core.units (name, short_name, parent_id, sort_order)
SELECT v.name, v.short_name, root.id, v.sort_order
FROM (VALUES
    ('Первая рота',          '1 рота', 10),
    ('Вторая рота',          '2 рота', 20),
    ('Узел связи',           'УС',     30),
    ('Техническая служба',   'ТС',     40)
) AS v(name, short_name, sort_order)
CROSS JOIN (SELECT id FROM core.units WHERE short_name = 'в/ч 00000') AS root
WHERE NOT EXISTS (
    SELECT 1 FROM core.units u WHERE u.short_name = v.short_name
);


-- ----------------------------------------------------------------------------
-- Личный состав: 40 вымышленных сотрудников.
-- ----------------------------------------------------------------------------
WITH d AS (
    SELECT
        ARRAY[
            'Абрамов','Белов','Волков','Гусев','Данилов','Ершов','Жданов','Зайцев',
            'Ильин','Кабанов','Лебедев','Морозов','Никитин','Орлов','Панов','Рыбаков',
            'Сафонов','Тарасов','Ушаков','Фомин','Харитонов','Цветков','Чернов','Шилов',
            'Щукин','Юдин','Яковлев','Антонов','Баранов','Виноградов','Головин','Дроздов',
            'Егоров','Жуков','Зимин','Исаев','Крылов','Лукин','Медведев','Носов'
        ]::text[] AS surnames,
        ARRAY[
            'Александр','Борис','Виктор','Григорий','Дмитрий','Евгений','Иван','Кирилл',
            'Леонид','Михаил','Николай','Олег','Павел','Роман','Сергей','Тимофей'
        ]::text[] AS firstnames,
        ARRAY[
            'Александрович','Борисович','Викторович','Григорьевич','Дмитриевич',
            'Евгеньевич','Иванович','Кириллович','Леонидович','Михайлович',
            'Николаевич','Олегович'
        ]::text[] AS patronymics,
        ARRAY[
            'стрелок','водитель','механик','радиотелефонист','оператор',
            'старший техник','командир отделения','заместитель командира взвода'
        ]::text[] AS positions,
        -- Старшинство званий: преобладает рядовой и сержантский состав.
        ARRAY[10,10,20,30,30,40,50,60,70,100,120,130]::int[] AS seniorities,
        ARRAY['1 рота','2 рота','УС','ТС']::text[] AS unit_codes
)
INSERT INTO personnel.employees
    (last_name, first_name, middle_name, rank_id, position, unit_id, personnel_number, phone)
SELECT
    d.surnames[i],
    d.firstnames[1 + (i % array_length(d.firstnames, 1))],
    d.patronymics[1 + (i % array_length(d.patronymics, 1))],
    (SELECT r.id FROM core.ranks r
      WHERE r.seniority = d.seniorities[1 + (i % array_length(d.seniorities, 1))]),
    d.positions[1 + (i % array_length(d.positions, 1))],
    (SELECT u.id FROM core.units u
      WHERE u.short_name = d.unit_codes[1 + (i % array_length(d.unit_codes, 1))]),
    'Т-' || lpad(i::text, 4, '0'),
    '+7 (900) ' || lpad((100 + i)::text, 3, '0') || '-00-' || lpad(i::text, 2, '0')
FROM d, generate_series(1, 40) AS i
ON CONFLICT (personnel_number) DO NOTHING;


-- ----------------------------------------------------------------------------
-- Медицинский допуск УМО/ВВК — есть у всех, но не у всех действующий.
--   i % 10 = 0  → просрочен
--   i % 10 = 1  → приостановлен
-- ----------------------------------------------------------------------------
INSERT INTO personnel.employee_permits
    (employee_id, permit_type_id, issued_at, expires_at, status,
     suspended_from, suspended_to, suspend_reason, document_ref)
SELECT
    e.id,
    (SELECT id FROM personnel.permit_types WHERE code = 'UMO_VVK'),
    CURRENT_DATE - INTERVAL '8 months',
    CASE WHEN e.i % 10 = 0
         THEN CURRENT_DATE - INTERVAL '2 months'      -- просрочен
         ELSE CURRENT_DATE + INTERVAL '4 months'
    END,
    CASE WHEN e.i % 10 = 1 THEN 'suspended' ELSE 'active' END,
    CASE WHEN e.i % 10 = 1 THEN CURRENT_DATE - INTERVAL '20 days' END,
    CASE WHEN e.i % 10 = 1 THEN CURRENT_DATE + INTERVAL '40 days' END,
    CASE WHEN e.i % 10 = 1 THEN 'приостановлен по результатам медицинского осмотра' END,
    'приказ № 12 (условный)'
FROM (SELECT id, (substring(personnel_number from 3))::int AS i
        FROM personnel.employees) e;


-- ----------------------------------------------------------------------------
-- Допуск психолога МПФО — срок 5 лет.
--   i % 10 = 2  → допуск отсутствует вовсе
--   i % 10 = 3  → просрочен
-- ----------------------------------------------------------------------------
INSERT INTO personnel.employee_permits
    (employee_id, permit_type_id, issued_at, expires_at, status, document_ref)
SELECT
    e.id,
    (SELECT id FROM personnel.permit_types WHERE code = 'MPFO'),
    CURRENT_DATE - INTERVAL '3 years',
    CASE WHEN e.i % 10 = 3
         THEN CURRENT_DATE - INTERVAL '1 month'       -- просрочен
         ELSE CURRENT_DATE + INTERVAL '2 years'
    END,
    'active',
    'приказ № 7 (условный)'
FROM (SELECT id, (substring(personnel_number from 3))::int AS i
        FROM personnel.employees) e
WHERE e.i % 10 <> 2;                                  -- допуск не оформлялся


-- ----------------------------------------------------------------------------
-- Допуск «Суточный наряд» к виду наряда СН.
-- Оформляется отдельно к каждому виду наряда (is_duty_specific = true),
-- поэтому заполняется duty_type_id.
-- ----------------------------------------------------------------------------
INSERT INTO personnel.employee_permits
    (employee_id, permit_type_id, duty_type_id, issued_at, expires_at, status, document_ref)
SELECT
    e.id,
    (SELECT id FROM personnel.permit_types WHERE code = 'SN'),
    (SELECT id FROM duty.duty_types WHERE code = 'SN'),
    CURRENT_DATE - INTERVAL '6 months',
    CURRENT_DATE + INTERVAL '6 months',
    'active',
    'приказ № 21 (условный)'
FROM (SELECT id, (substring(personnel_number from 3))::int AS i
        FROM personnel.employees) e
WHERE e.i % 2 = 0;


-- ----------------------------------------------------------------------------
-- Допуск «Суточный наряд» к виду наряда ОД (оперативное дежурство).
-- ----------------------------------------------------------------------------
INSERT INTO personnel.employee_permits
    (employee_id, permit_type_id, duty_type_id, issued_at, expires_at, status, document_ref)
SELECT
    e.id,
    (SELECT id FROM personnel.permit_types WHERE code = 'SN'),
    (SELECT id FROM duty.duty_types WHERE code = 'OD'),
    CURRENT_DATE - INTERVAL '6 months',
    CURRENT_DATE + INTERVAL '6 months',
    'active',
    'приказ № 21 (условный)'
FROM (SELECT id, (substring(personnel_number from 3))::int AS i
        FROM personnel.employees) e
WHERE e.i % 3 = 0;


-- ----------------------------------------------------------------------------
-- Допуск «Охрана и оборона» — профильный для многодневной смены ОО.
-- ----------------------------------------------------------------------------
INSERT INTO personnel.employee_permits
    (employee_id, permit_type_id, issued_at, expires_at, status, document_ref)
SELECT
    e.id,
    (SELECT id FROM personnel.permit_types WHERE code = 'OO'),
    CURRENT_DATE - INTERVAL '5 months',
    CURRENT_DATE + INTERVAL '7 months',
    'active',
    'приказ № 33 (условный)'
FROM (SELECT id, (substring(personnel_number from 3))::int AS i
        FROM personnel.employees) e
WHERE e.i % 4 = 0;


-- ----------------------------------------------------------------------------
-- Прочие допуски — для проверки карточки сотрудника, на отбор в наряд
-- не влияют.
-- ----------------------------------------------------------------------------
INSERT INTO personnel.employee_permits
    (employee_id, permit_type_id, issued_at, expires_at, status, document_ref)
SELECT
    e.id,
    pt.id,
    CURRENT_DATE - INTERVAL '4 months',
    CURRENT_DATE + INTERVAL '8 months',
    'active',
    'приказ № 45 (условный)'
FROM (SELECT id, (substring(personnel_number from 3))::int AS i
        FROM personnel.employees) e
JOIN personnel.permit_types pt ON pt.code IN ('TECH', 'WORK_CTRL')
WHERE e.i % 5 = 0;


-- ----------------------------------------------------------------------------
-- Отсутствия. Часть периодов накрывает текущую дату — эти сотрудники
-- должны отсеиваться при отборе кандидатов.
-- ----------------------------------------------------------------------------
INSERT INTO personnel.absences (employee_id, absence_type_id, date_from, date_to, document_ref)
SELECT
    e.id,
    (SELECT id FROM personnel.absence_types WHERE code = 'VACATION'),
    CURRENT_DATE - INTERVAL '10 days',
    CURRENT_DATE + INTERVAL '20 days',
    'приказ на убытие № 101 (условный)'
FROM (SELECT id, (substring(personnel_number from 3))::int AS i
        FROM personnel.employees) e
WHERE e.i IN (3, 14, 27);

INSERT INTO personnel.absences (employee_id, absence_type_id, date_from, date_to, document_ref)
SELECT
    e.id,
    (SELECT id FROM personnel.absence_types WHERE code = 'SICK'),
    CURRENT_DATE - INTERVAL '4 days',
    CURRENT_DATE + INTERVAL '6 days',
    'справка (условная)'
FROM (SELECT id, (substring(personnel_number from 3))::int AS i
        FROM personnel.employees) e
WHERE e.i IN (8, 22);

INSERT INTO personnel.absences (employee_id, absence_type_id, date_from, date_to, document_ref)
SELECT
    e.id,
    (SELECT id FROM personnel.absence_types WHERE code = 'TRIP'),
    CURRENT_DATE + INTERVAL '5 days',
    CURRENT_DATE + INTERVAL '15 days',
    'приказ на убытие № 118 (условный)'
FROM (SELECT id, (substring(personnel_number from 3))::int AS i
        FROM personnel.employees) e
WHERE e.i IN (5, 31);


-- ----------------------------------------------------------------------------
-- Учетная запись администратора.
--
-- ⚠️ Аутентификация не реализована (этап 5). В поле password_hash записана
--    заглушка, которая заведомо не совпадет ни с одним паролем — вход по ней
--    невозможен. При внедрении МС-5 заглушку следует заменить настоящим хешем.
-- ----------------------------------------------------------------------------
INSERT INTO core.users (employee_id, login, password_hash, role_code)
SELECT e.id, 'admin', 'NOT_SET:auth_not_implemented', 'admin'
FROM personnel.employees e
WHERE e.personnel_number = 'Т-0001'
ON CONFLICT (login) DO NOTHING;

COMMIT;
