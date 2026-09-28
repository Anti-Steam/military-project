-- 040. Отсыпной остается и там, где разрешено заступать подряд.
--
-- В 039 разрешение было выражено как «наряд не дает отсыпного». Это неверно
-- по существу: человек отдых ОТБЫВАЕТ — спит положенные часы — и в строевой
-- записке числится в отсыпном. Разрешение означает другое: такого человека
-- НЕ ОТФИЛЬТРОВЫВАЮТ при назначении на этот же пост (или вид наряда), и его
-- можно поставить снова.
--
-- Поэтому норма отдыха в представлении возвращается к прежней, а разрешение
-- действует там, где ему и место, — в отборе кандидатов и проверке состава.

BEGIN;

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
       -- Разрешение заступать подряд едет вместе с назначением: проверки
       -- состава должны знать, можно ли ставить этого человека снова.
       COALESCE(p.allow_consecutive, dt.allow_consecutive) AS allow_consecutive,
       CASE WHEN da.on_date IS NULL THEN dt.rest_excludes_weekends ELSE false END
           AS rest_excludes_weekends,
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

COMMIT;
