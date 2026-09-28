-- 031. Согласование закреплений с допусками на стенде.
--
-- В миграции 029 закрепления расставлялись «по смыслу названий», без оглядки
-- на то, у кого есть допуски. Вышло, что за постом дежурного по части
-- закреплены роты, а допущенных к нему в ротах по три человека: пост
-- ежедневный, отсыпной сутки, и тремя людьми месяц не закрыть.
--
-- Система вела себя правильно — честно показывала нехватку, — но проверить
-- на таком стенде подбор нельзя. Закрепления приводятся в соответствие с
-- допусками, а допуски внутри рот расширяются до потребности.
--
-- Расчет потребности: ежедневный пост при отсыпном в сутки требует примерно
-- вдвое больше людей, чем выходов подряд; на месяц с запасом берется 12–15
-- человек на место.

-- Посты части (дежурный по части и его помощник) закрепления не имеют:
-- их несут офицеры и прапорщики управления, узла связи и технической службы.
DELETE FROM duty.post_units pu
 USING duty.duty_posts p
 WHERE p.id = pu.post_id
   AND p.name IN ('Дежурный по части', 'Помощник дежурного по части');

-- Ротные посты закрепляются за своими ротами: это их собственный наряд.
INSERT INTO duty.post_units (post_id, turn, unit_id)
SELECT p.id, 1, u.id
FROM duty.duty_posts p
JOIN core.units u ON u.short_name = CASE
        WHEN p.name LIKE '%1-й роте%' THEN '1 рота'
        WHEN p.name LIKE '%2-й роте%' THEN '2 рота'
    END
WHERE (p.name LIKE 'Дежурный по %-й роте%' OR p.name LIKE 'Дневальный по %-й роте%')
  AND NOT EXISTS (SELECT 1 FROM duty.post_units x WHERE x.post_id = p.id);

-- КПП и парк остаются сменными: роты ходят туда по очереди.
DELETE FROM duty.post_units pu
 USING duty.duty_posts p
 WHERE p.id = pu.post_id AND (p.name LIKE '%КПП%' OR p.name LIKE '%парку%');

INSERT INTO duty.post_units (post_id, turn, unit_id)
SELECT p.id, v.turn, u.id
FROM duty.duty_posts p
CROSS JOIN (VALUES (1, '1 рота'), (2, '2 рота')) AS v(turn, unit)
JOIN core.units u ON u.short_name = v.unit
WHERE p.name LIKE '%КПП%';

INSERT INTO duty.post_units (post_id, turn, unit_id)
SELECT p.id, v.turn, u.id
FROM duty.duty_posts p
CROSS JOIN (VALUES (1, '2 рота'), (2, '1 рота')) AS v(turn, unit)
JOIN core.units u ON u.short_name = v.unit
WHERE p.name LIKE '%парку%';

UPDATE duty.duty_posts SET rotation_since = DATE '2026-09-01'
 WHERE EXISTS (SELECT 1 FROM duty.post_units pu WHERE pu.post_id = duty_posts.id);

-- ---------------------------------------------------------------------------
-- Допуски внутри рот: столько, сколько нужно на месяц.
--
-- Выдаются сержантам и рядовым рот (вместе со всеми вложенными взводами и
-- отделениями) по старшинству, чтобы состав выглядел правдоподобно.
-- ---------------------------------------------------------------------------

CREATE TEMP TABLE company_members AS
WITH RECURSIVE tree AS (
    SELECT id, short_name AS company FROM core.units WHERE short_name IN ('1 рота', '2 рота')
    UNION ALL
    SELECT u.id, t.company FROM core.units u JOIN tree t ON u.parent_id = t.id
)
SELECT e.id AS employee_id, t.company, r.seniority,
       row_number() OVER (PARTITION BY t.company ORDER BY r.seniority DESC, e.id) AS place
FROM tree t
JOIN personnel.employees e ON e.unit_id = t.id AND e.is_active
JOIN core.ranks r          ON r.id = e.rank_id;

-- Дежурный по роте и по КПП, дежурный по парку — сержантский состав роты.
INSERT INTO personnel.employee_permits (employee_id, permit_type_id, issued_at, expires_at, status)
SELECT m.employee_id, t.id, DATE '2025-01-15', DATE '2028-06-30', 'active'
FROM company_members m
CROSS JOIN personnel.permit_types t
WHERE t.code IN ('ROLE_12', 'ROLE_8', 'ROLE_10')
  AND m.place BETWEEN 3 AND 20
  AND NOT EXISTS (
      SELECT 1 FROM personnel.employee_permits ep
      WHERE ep.employee_id = m.employee_id AND ep.permit_type_id = t.id
  );

-- Дневальный и помощники — рядовой состав роты.
INSERT INTO personnel.employee_permits (employee_id, permit_type_id, issued_at, expires_at, status)
SELECT m.employee_id, t.id, DATE '2025-01-15', DATE '2028-06-30', 'active'
FROM company_members m
CROSS JOIN personnel.permit_types t
WHERE t.code IN ('ROLE_14', 'ROLE_9', 'ROLE_11')
  AND m.place >= 6
  AND NOT EXISTS (
      SELECT 1 FROM personnel.employee_permits ep
      WHERE ep.employee_id = m.employee_id AND ep.permit_type_id = t.id
  );
