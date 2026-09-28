-- ============================================================================
-- 015. Общие допуски для расширенного личного состава.
--
-- В миграции 013 выборка ссылалась на коды видов допуска 'MED' и 'PSY',
-- которых в справочнике нет: медицинский и психологический допуски заведены
-- под кодами UMO_VVK и MPFO. Выборка не нашла ни одной строки, и добавленные
-- сотрудники остались без общих допусков — а без них заступление невозможно
-- ни в один вид наряда.
--
-- Миграция 013 применена и неизменяема, поэтому исправление вносится
-- отдельным файлом.
--
-- Сроки окончания намеренно разные, часть допусков просрочена либо истекает
-- в ближайшие недели: без этого не проверяются ни фильтрация по действующим
-- допускам, ни будущие напоминания об истечении.
--
-- ДАННЫЕ СИНТЕТИЧЕСКИЕ (раздел 2 ТЗ).
-- ============================================================================

WITH ord AS (
    INSERT INTO personnel.permit_orders (number, issued_on, title)
    VALUES ('61-1', DATE '2026-02-10',
            'О допуске личного состава по результатам УМО/ВВК и МПФО')
    RETURNING id
),
targets AS (
    SELECT e.id AS employee_id,
           pt.id AS permit_type_id,
           row_number() OVER (ORDER BY e.id, pt.id) AS i
    FROM personnel.employees e
    CROSS JOIN personnel.permit_types pt
    WHERE e.is_active
      AND pt.code IN ('UMO_VVK', 'MPFO')
      AND NOT EXISTS (
          SELECT 1 FROM personnel.employee_permits ep
          WHERE ep.employee_id = e.id AND ep.permit_type_id = pt.id
      )
)
INSERT INTO personnel.employee_permits
    (employee_id, permit_type_id, order_id, issued_at, expires_at, status, document_ref)
SELECT t.employee_id,
       t.permit_type_id,
       (SELECT id FROM ord),
       DATE '2026-02-10',
       CASE t.i % 12
           WHEN 0 THEN DATE '2026-08-01'   -- просрочен
           WHEN 1 THEN DATE '2026-09-25'   -- истекает в ближайшие недели
           WHEN 2 THEN DATE '2026-10-30'
           ELSE DATE '2027-02-10'
       END,
       CASE WHEN t.i % 41 = 0 THEN 'suspended' ELSE 'active' END,
       'приказ № 61 от 10.02.2026'
FROM targets t;
