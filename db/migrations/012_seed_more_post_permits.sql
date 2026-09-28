-- ============================================================================
-- 012. Расширение синтетических постовых допусков.
--
-- В 009 допуски выдавались редкой выборкой, и на посты роты приходилось по
-- два допущенных на три поста. Полный состав суточного наряда при этом
-- недостижим: один человек не может занимать два поста одновременно, и
-- график оказывается сплошь красным независимо от работы системы.
--
-- ДАННЫЕ СИНТЕТИЧЕСКИЕ. Реальные сведения о личном составе на стенд не
-- переносятся (раздел 2 ТЗ).
-- ============================================================================

WITH ord AS (
    INSERT INTO personnel.permit_orders (number, issued_on, title)
    VALUES ('54', DATE '2026-08-20',
            'О допуске к постам суточного наряда (дополнение к приказам № 51—53)')
    RETURNING id
),
-- Кандидаты на допуск: служащие того подразделения, которому принадлежит
-- пост, еще не допущенные к нему.
targets AS (
    SELECT p.id AS post_id,
           e.id AS employee_id,
           row_number() OVER (PARTITION BY p.id ORDER BY e.id) AS rn
    FROM duty.duty_posts p
    JOIN personnel.employees e ON e.unit_id = p.unit_id AND e.is_active
    WHERE p.is_active
      AND p.unit_id IS NOT NULL
      AND NOT EXISTS (
          SELECT 1 FROM personnel.employee_permits ep
          WHERE ep.employee_id = e.id AND ep.post_id = p.id
      )
)
INSERT INTO personnel.employee_permits
    (employee_id, permit_type_id, post_id, order_id, issued_at, expires_at, status, document_ref)
SELECT t.employee_id,
       (SELECT id FROM personnel.permit_types WHERE code = 'SN'),
       t.post_id,
       (SELECT id FROM ord),
       DATE '2026-08-20',
       DATE '2027-08-20',
       'active',
       'приказ № 54 от 20.08.2026'
FROM targets t
WHERE t.rn <= 4;


-- То же для общих постов суточного наряда: дежурный по части и его помощник
-- имели по четыре допущенных на весь месяц, чего мало для непрерывного
-- графика с учетом отсутствующих.
WITH ord AS (
    SELECT id FROM personnel.permit_orders WHERE number = '54'
),
targets AS (
    SELECT p.id AS post_id,
           e.id AS employee_id,
           row_number() OVER (PARTITION BY p.id ORDER BY e.id) AS rn
    FROM duty.duty_posts p
    JOIN duty.duty_types dt ON dt.id = p.duty_type_id AND dt.code = 'SN'
    JOIN personnel.employees e ON e.is_active
    WHERE p.is_active
      AND p.unit_id IS NULL
      AND NOT EXISTS (
          SELECT 1 FROM personnel.employee_permits ep
          WHERE ep.employee_id = e.id AND ep.post_id = p.id
      )
)
INSERT INTO personnel.employee_permits
    (employee_id, permit_type_id, post_id, order_id, issued_at, expires_at, status, document_ref)
SELECT t.employee_id,
       (SELECT id FROM personnel.permit_types WHERE code = 'SN'),
       t.post_id,
       (SELECT id FROM ord),
       DATE '2026-08-20',
       DATE '2027-08-20',
       'active',
       'приказ № 54 от 20.08.2026'
FROM targets t
WHERE t.rn <= 6;
