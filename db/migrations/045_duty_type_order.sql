-- Порядок видов нарядов задается перетаскиванием, как у постов и
-- подразделений. Начальный порядок — прежний, по коду вида, с шагом 10.

ALTER TABLE duty.duty_types ADD COLUMN sort_order int NOT NULL DEFAULT 0;

UPDATE duty.duty_types t SET sort_order = o.n * 10
FROM (SELECT id, row_number() OVER (ORDER BY code) AS n FROM duty.duty_types) o
WHERE o.id = t.id;
