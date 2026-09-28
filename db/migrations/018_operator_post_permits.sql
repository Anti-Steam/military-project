-- ============================================================================
-- 018. Расширение круга допущенных к постам операторов оперативного дежурства.
--
-- Посты «Старший оператор» и «Оператор» замещаются тем же кругом, что и
-- сержантские посты суточного наряда — дежурные по КПП и парку, дежурные и
-- дневальные по ротам. Суточный наряд крупнее и разбирает этот круг первым,
-- после чего на оперативное дежурство операторов не остается.
--
-- Ограничение по числу допущенных снято: допуск получают все, чье звание
-- соответствует посту (от ефрейтора до старшего прапорщика).
--
-- ДАННЫЕ СИНТЕТИЧЕСКИЕ (раздел 2 ТЗ).
-- ============================================================================

WITH ord AS (
    INSERT INTO personnel.permit_orders (number, issued_on, title)
    VALUES ('66', DATE '2026-05-20', 'О допуске к постам операторов оперативного дежурства')
    RETURNING id
),
posts AS (
    SELECT p.id AS post_id
    FROM duty.duty_posts p
    JOIN duty.duty_types dt ON dt.id = p.duty_type_id AND dt.code = 'OD'
    WHERE p.is_active AND p.name LIKE '%ператор%'
)
INSERT INTO personnel.employee_permits
    (employee_id, permit_type_id, post_id, order_id, issued_at, expires_at, status, document_ref)
SELECT e.id,
       (SELECT id FROM personnel.permit_types WHERE code = 'SN'),
       posts.post_id,
       (SELECT id FROM ord),
       DATE '2026-05-20',
       DATE '2027-05-20',
       'active',
       'приказ № 66 от 20.05.2026'
FROM posts
JOIN personnel.employees e ON e.is_active
JOIN core.ranks r          ON r.id = e.rank_id
WHERE r.seniority BETWEEN 20 AND 80
  AND NOT EXISTS (
      SELECT 1 FROM personnel.employee_permits ep
      WHERE ep.employee_id = e.id AND ep.post_id = posts.post_id
  );
