-- 032. Доведение допусков рот до потребности стенда.
--
-- После 031 подбор закрывал месяц не полностью: во второй роте к посту
-- помощника дежурного по КПП оказалось два-три допущенных, а пост ежедневный
-- и рота ходит на него через сутки. С отсыпным двумя людьми такой пост не
-- закрыть.
--
-- Допуски к ротным и пропускным постам выдаются всему сержантскому и рядовому
-- составу рот. Это синтетические данные стенда: на настоящем объекте перечень
-- допущенных задается приказом.

WITH RECURSIVE tree AS (
    SELECT id FROM core.units WHERE short_name IN ('1 рота', '2 рота')
    UNION ALL
    SELECT u.id FROM core.units u JOIN tree t ON u.parent_id = t.id
)
INSERT INTO personnel.employee_permits (employee_id, permit_type_id, issued_at, expires_at, status)
SELECT e.id, t.id, DATE '2025-01-15', DATE '2028-06-30', 'active'
FROM tree
JOIN personnel.employees e ON e.unit_id = tree.id AND e.is_active
JOIN core.ranks r          ON r.id = e.rank_id AND r.seniority <= 60
CROSS JOIN personnel.permit_types t
WHERE t.code IN ('ROLE_8', 'ROLE_9', 'ROLE_10', 'ROLE_11', 'ROLE_12', 'ROLE_14')
  AND NOT EXISTS (
      SELECT 1 FROM personnel.employee_permits ep
      WHERE ep.employee_id = e.id AND ep.permit_type_id = t.id
  );
