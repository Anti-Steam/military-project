-- 029. Закрепление ПОСТА за подразделением: постоянное, цикличное, точечное.
--
-- Прежнее закрепление (миграция 028) действовало на весь наряд сразу. Этого
-- мало: по КПП ходит только первая рота, а на остальные посты подразделения
-- заступают по очереди. Поэтому закрепление опускается до ПОСТА.
--
-- Три уровня, от сильного к слабому:
--   1. точечное — пост на конкретные сутки (ручное решение начальника службы);
--   2. очередь поста — постоянное закрепление либо цикл подразделений;
--   3. закрепление всего наряда на сутки (028) — запасной уровень.
-- Ни один из них не отменяется другим: более сильный просто отвечает первым.

-- Опорные сутки очереди: от них считается, чья очередь заступать. Без них
-- цикл не определен — «первая, вторая, третья» нужно от чего-то отсчитывать.
ALTER TABLE duty.duty_posts ADD COLUMN rotation_since date;

COMMENT ON COLUMN duty.duty_posts.rotation_since IS
    'Сутки, с которых отсчитывается очередь подразделений на посту';

-- Очередь подразделений на посту.
--
-- ОДНА строка — постоянное закрепление, несколько — цикл. Отдельной сущности
-- для постоянного закрепления не заводится: цикл из одного подразделения и
-- есть постоянное закрепление, и второе правило для того же самого
-- разошлось бы с первым при первой же правке.
CREATE TABLE duty.post_units (
    post_id int NOT NULL REFERENCES duty.duty_posts(id) ON DELETE CASCADE,
    turn    int NOT NULL CHECK (turn >= 1),
    unit_id int NOT NULL REFERENCES core.units(id) ON DELETE RESTRICT,
    PRIMARY KEY (post_id, turn),
    -- Одно подразделение не может стоять в очереди дважды: это означало бы
    -- либо опечатку, либо желание ходить чаще, которое выражается весом.
    UNIQUE (post_id, unit_id)
);

-- Точечное закрепление: пост на конкретные сутки. Сильнее очереди — им
-- начальник службы правит порядок, не ломая сам порядок.
CREATE TABLE duty.post_responsibilities (
    post_id     int  NOT NULL REFERENCES duty.duty_posts(id) ON DELETE CASCADE,
    on_date     date NOT NULL,
    unit_id     int  NOT NULL REFERENCES core.units(id) ON DELETE RESTRICT,
    note        text,
    assigned_by int  REFERENCES core.users(id) ON DELETE SET NULL,
    assigned_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (post_id, on_date)
);
CREATE INDEX idx_post_responsibilities_unit ON duty.post_responsibilities(unit_id);

-- ---------------------------------------------------------------------------
-- Начальное наполнение стенда: по КПП ходит первая рота, дежурный и дневальный
-- по роте закреплены за своими ротами, остальные посты суточного наряда
-- достаются ротам по очереди.
-- ---------------------------------------------------------------------------

-- Посты КПП — постоянно за первой ротой.
INSERT INTO duty.post_units (post_id, turn, unit_id)
SELECT p.id, 1, (SELECT id FROM core.units WHERE short_name = '1 рота')
FROM duty.duty_posts p
WHERE p.name LIKE '%КПП%';

-- Дежурный по парку и его помощник — постоянно за второй ротой.
INSERT INTO duty.post_units (post_id, turn, unit_id)
SELECT p.id, 1, (SELECT id FROM core.units WHERE short_name = '2 рота')
FROM duty.duty_posts p
WHERE p.name LIKE '%парку%';

-- Дежурный по части и его помощник — по очереди между ротами.
INSERT INTO duty.post_units (post_id, turn, unit_id)
SELECT p.id, v.turn, (SELECT id FROM core.units WHERE short_name = v.unit)
FROM duty.duty_posts p
CROSS JOIN (VALUES (1, '1 рота'), (2, '2 рота')) AS v(turn, unit)
WHERE p.name IN ('Дежурный по части', 'Помощник дежурного по части');

UPDATE duty.duty_posts SET rotation_since = DATE '2026-09-01'
 WHERE EXISTS (SELECT 1 FROM duty.post_units pu WHERE pu.post_id = duty_posts.id);
