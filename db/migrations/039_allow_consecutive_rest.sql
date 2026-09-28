-- 039. Разрешение заступать подряд означает, что наряд НЕ ДАЕТ ОТСЫПНОГО.
--
-- Разрешение вводилось в 038 как снятие двух ограничений: запрета по отдыху и
-- порога очереди. Запрет по отдыху проверяется в четырех местах — при отборе
-- кандидатов назад и вперед, при сохранении блока и при проверке состава, — и
-- обходить его в каждом значило бы четыре раза повторить одно правило.
--
-- Правило записывается там, где отдых определяется: в представлении
-- v_assignment_periods. У поста (или вида наряда), где заступление подряд
-- разрешено, норма отдыха равна нулю. Отсюда само собой следует все
-- остальное: человек не числится в отсыпном, не отсекается проверками и
-- сразу доступен — как и положено посту, который несут ежедневно.
--
-- Порог очереди снимается отдельно, в коде отбора: он не про отдых, а про
-- очередность, и к представлению отношения не имеет.

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
       -- Заступление подряд разрешено — отдыха этот наряд не дает.
       CASE WHEN COALESCE(p.allow_consecutive, dt.allow_consecutive)
            THEN 0
            ELSE COALESCE(p.recovery_sleep_days, dt.recovery_sleep_days)
       END AS recovery_sleep_days,
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

COMMIT;
