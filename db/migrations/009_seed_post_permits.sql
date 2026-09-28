-- ============================================================================
-- 009_seed_post_permits.sql
-- Синтетические постовые допуски.
--
-- ⚠️ ВСЕ ДАННЫЕ ВЫМЫШЛЕНЫ.
--
-- Распределение задано так, чтобы получить пригодный для проверки набор:
--   • на каждый пост допущено несколько человек, но не весь личный состав;
--   • на старшие посты допущены только лица от сержанта и выше;
--   • к постам, относящимся к роте, допущены только служащие этой роты;
--   • допуски оформлены тремя разными приказами.
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- Приказы о допуске
-- ----------------------------------------------------------------------------
INSERT INTO personnel.permit_orders (number, issued_on, title) VALUES
    ('51',  CURRENT_DATE - INTERVAL '7 months', 'О допуске личного состава к несению службы в суточном наряде'),
    ('52',  CURRENT_DATE - INTERVAL '5 months', 'О допуске личного состава к оперативному дежурству'),
    ('53',  CURRENT_DATE - INTERVAL '4 months', 'О допуске личного состава к несению службы в дежурной смене')
ON CONFLICT (number, issued_on) DO NOTHING;


-- ----------------------------------------------------------------------------
-- Постовые допуски
--
-- Вид допуска определяется видом наряда, которому принадлежит пост:
--   посты ДСОО      → допуск «Охрана и оборона»
--   посты СН и ОД   → допуск «Суточный наряд»
-- ----------------------------------------------------------------------------
INSERT INTO personnel.employee_permits
    (employee_id, permit_type_id, post_id, order_id, issued_at, expires_at, status, document_ref)
SELECT
    e.id,
    pt.id,
    p.id,
    ord.id,
    CURRENT_DATE - INTERVAL '4 months',
    CURRENT_DATE + INTERVAL '8 months',
    'active',
    'приказ № ' || ord.number
FROM (
    SELECT id, unit_id, rank_id, (substring(personnel_number from 3))::int AS i
    FROM personnel.employees
) e
JOIN core.ranks r              ON r.id = e.rank_id
CROSS JOIN duty.duty_posts p
JOIN duty.duty_types dt        ON dt.id = p.duty_type_id
JOIN personnel.permit_types pt ON pt.code = CASE WHEN dt.code = 'OO' THEN 'OO' ELSE 'SN' END
JOIN personnel.permit_orders ord ON ord.number = CASE dt.code
                                                     WHEN 'SN' THEN '51'
                                                     WHEN 'OD' THEN '52'
                                                     ELSE '53'
                                                 END
WHERE
    -- Разреженное, но воспроизводимое распределение: примерно каждый пятый.
    (e.i + p.id * 3) % 5 = 0
    -- К посту роты допускаются только служащие этой роты.
    AND (p.unit_id IS NULL OR p.unit_id = e.unit_id)
    -- Старшие посты — от сержанта и выше.
    AND (p.sort_order > 20 OR r.seniority >= 40);

COMMIT;
