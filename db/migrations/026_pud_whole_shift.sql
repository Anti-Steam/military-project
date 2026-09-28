-- 026. ПУД заступает на всю смену, ПТСО меняется каждые сутки.
--
-- Уточнение порядка: пост управления доступом заступает ВМЕСТЕ СО ВСЕЙ
-- СМЕНОЙ и несет службу все ее дни, просто в свои часы — с 08:00 до 18:00.
-- В приказе он поэтому идет отдельным пунктом с указанием часов, но
-- назначается один раз, как остальной постоянный состав. Посты технических
-- средств охраны, наоборот, сменяются каждые сутки.
--
-- Отсюда часы поста и посуточное замещение — РАЗНЫЕ свойства, и выводить
-- одно из другого больше нельзя: у ПУД часы есть, а сменяется он вместе со
-- всеми. Вводится отдельный признак per_day.

ALTER TABLE duty.duty_posts
    ADD COLUMN per_day boolean NOT NULL DEFAULT false,
    ADD CONSTRAINT posts_per_day_needs_schedule
        CHECK (NOT per_day OR start_time IS NOT NULL);

COMMENT ON COLUMN duty.duty_posts.per_day IS
    'Пост замещается на каждые сутки смены отдельно (ПТСО). '
    'Иначе — одним назначением на весь наряд, даже если у поста свои часы (ПУД)';

UPDATE duty.duty_posts SET per_day = true
 WHERE start_time IS NOT NULL AND short_name LIKE 'ПТСО%';

-- Отсыпной ПТСО 1 — до начала следующего рабочего дня. Он сдает пост в
-- 20:00, то есть остаток тех же суток занят: заступить в ночь на ПТСО 2
-- сразу после своей дневной смены нельзя. Прежний ноль этого не выражал.
UPDATE duty.duty_posts SET recovery_sleep_days = 1
 WHERE short_name = 'ПТСО 1';

-- Посуточные назначения ПУД, сделанные по прежнему порядку, снимаются:
-- теперь это одно назначение на всю смену, и оформить его нужно заново.
DELETE FROM duty.duty_assignments da
 USING duty.duty_posts p
 WHERE p.id = da.post_id AND da.on_date IS NOT NULL AND NOT p.per_day;

-- Представление пересоздается: часы поста больше не означают посуточное
-- замещение, и вес назначения считается по фактически отстоянным часам.
DROP VIEW duty.v_assignment_periods;

CREATE VIEW duty.v_assignment_periods AS
SELECT da.id,
       da.duty_id,
       da.employee_id,
       da.post_id,
       da.on_date,
       da.source,
       da.note,
       da.is_override,
       da.override_checks,
       d.duty_type_id,
       d.unit_id,
       d.status,
       dt.code AS duty_code,
       CASE WHEN da.on_date IS NULL
            THEN d.starts_at
            ELSE da.on_date + p.start_time END AS starts_at,
       CASE WHEN da.on_date IS NULL
            THEN d.ends_at
            ELSE da.on_date + p.start_time + make_interval(hours => p.duration_hours) END AS ends_at,
       COALESCE(da.on_date, d.start_date) AS start_date,
       COALESCE(p.recovery_sleep_days, dt.recovery_sleep_days) AS recovery_sleep_days,
       -- Растягивание отдыха через выходные — свойство многосуточной смены;
       -- к выходу на 10–12 часов оно не относится.
       CASE WHEN da.on_date IS NULL THEN dt.rest_excludes_weekends ELSE false END
           AS rest_excludes_weekends,
       -- Вес — доля суток, фактически отстоянных на посту. Смена ОО и
       -- двенадцатичасовой ПТСО не могут весить одинаково; ПУД, стоящий по
       -- десять часов все дни смены, — тоже (предварительно, вопрос 6).
       CASE
           WHEN p.duration_hours IS NULL THEN dt.base_weight
           WHEN da.on_date IS NOT NULL THEN round(p.duration_hours / 24.0, 2)
           ELSE round(p.duration_hours / 24.0
                      * GREATEST(1, extract(epoch FROM (d.ends_at - d.starts_at)) / 86400), 2)
       END AS base_weight
FROM duty.duty_assignments da
JOIN duty.duties d      ON d.id = da.duty_id
JOIN duty.duty_types dt ON dt.id = d.duty_type_id
JOIN duty.duty_posts p  ON p.id = da.post_id;
