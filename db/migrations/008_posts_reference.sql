-- ============================================================================
-- 008_posts_reference.sql
-- Наполнение справочника постов (раздел 8.2 ТЗ).
--
-- На каждый пост назначается один человек. Там, где на должности несколько
-- человек, посты заведены нумерованными: «Дневальный по роте — 1», «— 2».
-- Количество таких постов правится администратором через справочник.
--
-- Посты, относящиеся к подразделению (дежурный и дневальный по роте),
-- заведены отдельно для каждой роты — согласовано.
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- ОД — оперативное дежурство
-- ----------------------------------------------------------------------------
INSERT INTO duty.duty_posts (duty_type_id, unit_id, short_name, name, sort_order)
SELECT dt.id, NULL, v.short_name, v.name, v.sort_order
FROM duty.duty_types dt
CROSS JOIN (VALUES
    ('ОД',   'Оперативный дежурный',                        10),
    ('СПОД', 'Старший помощник оперативного дежурного',     20),
    ('ПОД',  'Помощник оперативного дежурного',             30),
    ('СО',   'Старший оператор',                            40),
    ('О',    'Оператор',                                    50)
) AS v(short_name, name, sort_order)
WHERE dt.code = 'OD';


-- ----------------------------------------------------------------------------
-- СН — суточный наряд. Посты, общие для части.
-- ----------------------------------------------------------------------------
INSERT INTO duty.duty_posts (duty_type_id, unit_id, short_name, name, sort_order)
SELECT dt.id, NULL, v.short_name, v.name, v.sort_order
FROM duty.duty_types dt
CROSS JOIN (VALUES
    ('ДЧ',   'Дежурный по части',                 10),
    ('ПДЧ',  'Помощник дежурного по части',       20),
    ('ДКПП', 'Дежурный по КПП',                   50),
    ('ПДКПП','Помощник дежурного по КПП',         60),
    ('ДП',   'Дежурный по парку',                 70),
    ('ПДП',  'Помощник дежурного по парку',       80)
) AS v(short_name, name, sort_order)
WHERE dt.code = 'SN';


-- ----------------------------------------------------------------------------
-- СН — посты в ротах. Заводятся отдельно по каждой роте.
-- ----------------------------------------------------------------------------
INSERT INTO duty.duty_posts (duty_type_id, unit_id, short_name, name, sort_order)
SELECT
    dt.id,
    u.id,
    NULL,
    'Дежурный по ' || u.short_name,
    30
FROM duty.duty_types dt
CROSS JOIN core.units u
WHERE dt.code = 'SN'
  AND u.short_name IN ('1 рота', '2 рота');

-- Дневальных по роте двое; при необходимости число правится в справочнике.
INSERT INTO duty.duty_posts (duty_type_id, unit_id, short_name, name, sort_order)
SELECT
    dt.id,
    u.id,
    NULL,
    'Дневальный по ' || u.short_name || ' — ' || n,
    40
FROM duty.duty_types dt
CROSS JOIN core.units u
CROSS JOIN generate_series(1, 2) AS n
WHERE dt.code = 'SN'
  AND u.short_name IN ('1 рота', '2 рота');


-- ----------------------------------------------------------------------------
-- ОО — дежурная смена «Охрана и оборона» (ДСОО)
-- ----------------------------------------------------------------------------
INSERT INTO duty.duty_posts (duty_type_id, unit_id, short_name, name, sort_order)
SELECT dt.id, NULL, v.short_name, v.name, v.sort_order
FROM duty.duty_types dt
CROSS JOIN (VALUES
    ('КДС',  'Командир дежурной смены',              10),
    ('ЗКДС', 'Заместитель командира дежурной смены', 20),
    ('НПНР', 'Начальник ПНР',                        30)
) AS v(short_name, name, sort_order)
WHERE dt.code = 'OO';

-- Номера расчета 1–5.
INSERT INTO duty.duty_posts (duty_type_id, unit_id, short_name, name, sort_order)
SELECT
    dt.id,
    NULL,
    n::text,
    'Номер расчета ' || n,
    40 + n
FROM duty.duty_types dt
CROSS JOIN generate_series(1, 5) AS n
WHERE dt.code = 'OO';

COMMIT;
