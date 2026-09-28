-- ============================================================================
-- 017. Расширение круга допущенных к старшим постам.
--
-- Восемь старших постов (оперативный дежурный и его помощники, командир
-- дежурной смены и его заместители, дежурный по части и его помощник) делили
-- 35 человек, причем старшие лейтенанты и старшие прапорщики не были допущены
-- никуда: миграции 014 и 016 выдавали допуски в одном порядке по старшинству,
-- и один и тот же круг офицеров получал допуск сразу ко всем старшим постам.
--
-- В сутки такие посты требуют восьми человек, и с учетом отсыпного круга из
-- 35 не хватает — оперативное дежурство оставалось незамещенным.
--
-- Ограничение по числу допущенных здесь снято: допуск получают все, чье
-- звание соответствует посту. Верхняя граница у старших постов — майор:
-- подполковник и полковник наряд не несут, они его утверждают.
--
-- ДАННЫЕ СИНТЕТИЧЕСКИЕ (раздел 2 ТЗ).
-- ============================================================================

CREATE TEMP TABLE senior_posts ON COMMIT DROP AS
SELECT p.id AS post_id, dt.code AS duty_code, rng.min_seniority, rng.max_seniority
FROM duty.duty_posts p
JOIN duty.duty_types dt ON dt.id = p.duty_type_id
JOIN LATERAL (
    SELECT * FROM (VALUES
        ('Оперативный дежурный%',                 90, 130),
        ('Старший помощник оперативного%',        90, 120),
        ('Помощник оперативного%',                70, 120),
        ('Командир дежурной смены%',              90, 130),
        ('Заместитель командира дежурной смены%', 90, 120),
        ('Начальник ПНР%',                        70, 120),
        ('Дежурный по части%',                    70, 130),
        ('Помощник дежурного по части%',          70, 110)
    ) AS v(pattern, min_seniority, max_seniority)
    WHERE p.name LIKE v.pattern
) rng ON true
WHERE p.is_active;

WITH ord AS (
    INSERT INTO personnel.permit_orders (number, issued_on, title)
    VALUES ('65', DATE '2026-05-12',
            'О допуске офицеров и прапорщиков к старшим постам суточного наряда, ОД и ДСОО')
    RETURNING id
)
INSERT INTO personnel.employee_permits
    (employee_id, permit_type_id, post_id, order_id, issued_at, expires_at, status, document_ref)
SELECT e.id,
       (SELECT id FROM personnel.permit_types
         WHERE code = CASE WHEN sp.duty_code = 'OO' THEN 'OO' ELSE 'SN' END),
       sp.post_id,
       (SELECT id FROM ord),
       DATE '2026-05-12',
       DATE '2027-05-12',
       'active',
       'приказ № 65 от 12.05.2026'
FROM senior_posts sp
JOIN personnel.employees e ON e.is_active
JOIN core.ranks r          ON r.id = e.rank_id
WHERE r.seniority BETWEEN sp.min_seniority AND sp.max_seniority
  AND NOT EXISTS (
      SELECT 1 FROM personnel.employee_permits ep
      WHERE ep.employee_id = e.id AND ep.post_id = sp.post_id
  );


-- Снятие допусков к старшим постам у подполковников и полковников: наряд они
-- не несут. Допуски выданы миграциями 014 и 016 без такого разграничения.
DELETE FROM personnel.employee_permits ep
USING personnel.employees e, core.ranks r, senior_posts sp
WHERE ep.post_id = sp.post_id
  AND e.id = ep.employee_id
  AND r.id = e.rank_id
  AND r.seniority > sp.max_seniority;
