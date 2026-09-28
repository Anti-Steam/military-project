-- 037. Подразделение поста — следствие очереди заступающих.
--
-- У поста было ДВА мнения о том, кому он принадлежит: поле
-- duty_posts.unit_id, задававшееся в карточке поста, и перечень заступающих
-- подразделений duty.post_units. Правились они по отдельности и расходились:
-- на стенде нашелся пост с подразделением, но без очереди.
--
-- Принято одно правило: очередь задает принадлежность.
--     одно заступающее подразделение  → оно и есть подразделение поста;
--     несколько или ни одного         → пост общий, unit_id пуст.
-- Карточка поста показывает подразделение только для чтения, править его
-- можно лишь через перечень заступающих (см. setPostUnits).
--
-- Здесь данные приводятся к этому правилу.

BEGIN;

-- Подразделение задано, очереди нет: очередь заводится из него. Это ротные
-- посты — свою роту на них и выставляют.
INSERT INTO duty.post_units (post_id, turn, unit_id)
SELECT p.id, 1, p.unit_id
FROM duty.duty_posts p
WHERE p.unit_id IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM duty.post_units q WHERE q.post_id = p.id);

-- Очередь из нескольких подразделений: пост общий, и подразделение у него
-- пустое — иначе непонятно, кто отвечает в свою смену.
UPDATE duty.duty_posts p
   SET unit_id = NULL
 WHERE (SELECT count(*) FROM duty.post_units q WHERE q.post_id = p.id) > 1
   AND p.unit_id IS NOT NULL;

-- Очередь из одного подразделения: оно и записывается постом.
WITH single AS (
    SELECT post_id, min(unit_id) AS unit_id
    FROM duty.post_units
    GROUP BY post_id
    HAVING count(*) = 1
)
UPDATE duty.duty_posts p
   SET unit_id = s.unit_id
  FROM single s
 WHERE s.post_id = p.id AND p.unit_id IS DISTINCT FROM s.unit_id;

COMMIT;
