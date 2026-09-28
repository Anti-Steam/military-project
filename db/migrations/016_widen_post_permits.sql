-- ============================================================================
-- 016. Увеличение запаса допущенных к посту.
--
-- В 014 на пост выдавалось двенадцать допусков. С учетом отсыпного этого
-- впритык: при заполнении месяца отдельные сутки оперативного дежурства
-- оставались с незамещенным постом не из-за нехватки штата, а из-за узкого
-- круга допущенных. Запас увеличен до восемнадцати.
--
-- Диапазоны званий по постам — те же, что в 014.
--
-- ДАННЫЕ СИНТЕТИЧЕСКИЕ (раздел 2 ТЗ).
-- ============================================================================

CREATE TEMP TABLE post_rank_range ON COMMIT DROP AS
SELECT p.id AS post_id,
       CASE
           WHEN p.name LIKE 'Оперативный дежурный%'                THEN 90
           WHEN p.name LIKE 'Старший помощник оперативного%'       THEN 90
           WHEN p.name LIKE 'Помощник оперативного%'               THEN 70
           WHEN p.name LIKE '%ператор%'                            THEN 20
           WHEN p.name LIKE 'Командир дежурной смены%'             THEN 90
           WHEN p.name LIKE 'Заместитель командира дежурной смены%' THEN 90
           WHEN p.name LIKE 'Начальник ПНР%'                       THEN 70
           WHEN p.name LIKE 'Номер расчета%'                       THEN 10
           WHEN p.name LIKE 'Дежурный по части%'                   THEN 70
           WHEN p.name LIKE 'Помощник дежурного по части%'         THEN 70
           WHEN p.name LIKE 'Дежурный по %роте%'                   THEN 30
           WHEN p.name LIKE 'Дневальный%'                          THEN 10
           WHEN p.name LIKE 'Дежурный по %'                        THEN 20
           ELSE 10
       END AS min_seniority,
       CASE
           WHEN p.name LIKE 'Оперативный дежурный%'                THEN 150
           WHEN p.name LIKE 'Старший помощник оперативного%'       THEN 140
           WHEN p.name LIKE 'Помощник оперативного%'               THEN 130
           WHEN p.name LIKE '%ператор%'                            THEN 80
           WHEN p.name LIKE 'Командир дежурной смены%'             THEN 150
           WHEN p.name LIKE 'Заместитель командира дежурной смены%' THEN 140
           WHEN p.name LIKE 'Начальник ПНР%'                       THEN 130
           WHEN p.name LIKE 'Номер расчета%'                       THEN 60
           WHEN p.name LIKE 'Дежурный по части%'                   THEN 140
           WHEN p.name LIKE 'Помощник дежурного по части%'         THEN 120
           WHEN p.name LIKE 'Дежурный по %роте%'                   THEN 60
           WHEN p.name LIKE 'Дневальный%'                          THEN 20
           WHEN p.name LIKE 'Помощник дежурного по %'              THEN 40
           WHEN p.name LIKE 'Дежурный по %'                        THEN 60
           ELSE 150
       END AS max_seniority
FROM duty.duty_posts p;

WITH ord AS (
    INSERT INTO personnel.permit_orders (number, issued_on, title)
    VALUES ('64', DATE '2026-04-15', 'О дополнительном допуске к постам')
    RETURNING id
),
have AS (
    SELECT post_id, count(*)::int AS n
    FROM personnel.employee_permits
    WHERE post_id IS NOT NULL
    GROUP BY post_id
),
candidates AS (
    SELECT p.id AS post_id,
           dt.code AS duty_code,
           e.id AS employee_id,
           row_number() OVER (PARTITION BY p.id ORDER BY r.seniority, e.id) AS rn,
           18 - coalesce(h.n, 0) AS need
    FROM duty.duty_posts p
    JOIN duty.duty_types dt ON dt.id = p.duty_type_id
    JOIN post_rank_range rr ON rr.post_id = p.id
    LEFT JOIN have h        ON h.post_id = p.id
    JOIN personnel.employees e ON e.is_active
    JOIN core.ranks r          ON r.id = e.rank_id
    WHERE p.is_active
      AND r.seniority BETWEEN rr.min_seniority AND rr.max_seniority
      AND (p.unit_id IS NULL OR e.unit_id = p.unit_id)
      AND NOT EXISTS (
          SELECT 1 FROM personnel.employee_permits ep
          WHERE ep.employee_id = e.id AND ep.post_id = p.id
      )
)
INSERT INTO personnel.employee_permits
    (employee_id, permit_type_id, post_id, order_id, issued_at, expires_at, status, document_ref)
SELECT c.employee_id,
       (SELECT id FROM personnel.permit_types
         WHERE code = CASE WHEN c.duty_code = 'OO' THEN 'OO' ELSE 'SN' END),
       c.post_id,
       (SELECT id FROM ord),
       DATE '2026-04-15',
       DATE '2027-04-15',
       'active',
       'приказ № 64 от 15.04.2026'
FROM candidates c
WHERE c.rn <= c.need;
