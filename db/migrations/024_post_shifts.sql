-- 024. Посты со своим графиком внутри многодневной смены.
--
-- Дежурная смена ОО заступает во вторник в 17:30 и сдает в пятницу в 17:30,
-- но не весь ее состав стоит все эти сутки. Посты ПТСО и ПУД сменяются
-- КАЖДЫЙ ДЕНЬ и по своим часам:
--     ПТСО 1 — 08:00, 12 часов;
--     ПТСО 2 — 20:00, 12 часов (ночь, сдает утром следующих суток);
--     ПУД 1 и ПУД 2 — 08:00, 10 часов.
--
-- Поэтому у поста появляется собственное время заступления и
-- продолжительность. Пост без них замещается на весь наряд, как прежде, —
-- существующие посты остаются такими и ничего не теряют.
--
-- Отсыпной тоже свой: после ночного ПТСО 2 человек занят сутками сдачи,
-- после вечерних ПТСО 1 и ПУД отдых не положен (обычный рабочий день).
-- NULL означает «как у вида наряда».

ALTER TABLE duty.duty_posts
    ADD COLUMN start_time          time,
    ADD COLUMN duration_hours      int CHECK (duration_hours > 0 AND duration_hours <= 24),
    ADD COLUMN recovery_sleep_days int CHECK (recovery_sleep_days >= 0),
    ADD CONSTRAINT posts_own_schedule_complete
        CHECK ((start_time IS NULL) = (duration_hours IS NULL));

COMMENT ON COLUMN duty.duty_posts.start_time IS
    'Свой час заступления. NULL — пост замещается на весь период наряда';

-- Сутки выхода. NULL — назначение на весь наряд (постоянный состав смены).
ALTER TABLE duty.duty_assignments ADD COLUMN on_date date;

-- Один человек на посту в одни сутки и один пост у человека в одни сутки.
-- Прежние ограничения запрещали повторное появление человека в наряде
-- вообще, а теперь он может стоять на ПТСО во вторник и в четверг одной и
-- той же смены — это разные выходы.
DROP INDEX duty.uq_assignment_post;
ALTER TABLE duty.duty_assignments DROP CONSTRAINT assignments_unique_employee;
CREATE UNIQUE INDEX uq_assignment_post
    ON duty.duty_assignments (duty_id, post_id, COALESCE(on_date, '-infinity'::date));
CREATE UNIQUE INDEX uq_assignment_employee
    ON duty.duty_assignments (duty_id, employee_id, COALESCE(on_date, '-infinity'::date));

-- Единственное определение интервала назначения и нормы отдыха после него.
-- Занятость, отсыпной, нагрузка и повторная проверка состава считают одно и
-- то же: у постоянного состава — период наряда, у посменного поста — его
-- собственный выход.
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
       -- Вес выхода — доля суток: смена ОО и двенадцатичасовой ПТСО не могут
       -- весить для балансировки одинаково (предварительно, вопрос 6).
       CASE WHEN da.on_date IS NULL
            THEN dt.base_weight
            ELSE round(p.duration_hours / 24.0, 2) END AS base_weight
FROM duty.duty_assignments da
JOIN duty.duties d      ON d.id = da.duty_id
JOIN duty.duty_types dt ON dt.id = d.duty_type_id
JOIN duty.duty_posts p  ON p.id = da.post_id;

-- Допуск к должности общий для обоих ПТСО и обоих ПУД: должность одна,
-- номер поста лишь различает выходы (решение 22 миграции 022).
INSERT INTO personnel.permit_types (code, name, is_post_specific, default_validity_months)
VALUES ('ROLE_PTSO', 'Пост технических средств охраны', false, 12),
       ('ROLE_PUD',  'Пост управления доступом',        false, 12);

INSERT INTO duty.duty_posts
       (duty_type_id, unit_id, short_name, name, sort_order, is_active,
        required_permit_type_id, required_weapon_kind,
        start_time, duration_hours, recovery_sleep_days)
SELECT dt.id, NULL, v.short_name, v.name, v.sort_order, true,
       (SELECT id FROM personnel.permit_types WHERE code = v.permit_code),
       NULL, v.start_time, v.duration_hours, v.sleep_days
FROM duty.duty_types dt,
     (VALUES ('ПТСО 1', 'Пост технических средств охраны 1', 50, 'ROLE_PTSO', time '08:00', 12, 0),
             ('ПТСО 2', 'Пост технических средств охраны 2', 51, 'ROLE_PTSO', time '20:00', 12, 1),
             ('ПУД 1',  'Пост управления доступом 1',        52, 'ROLE_PUD',  time '08:00', 10, 0),
             ('ПУД 2',  'Пост управления доступом 2',        53, 'ROLE_PUD',  time '08:00', 10, 0))
     AS v(short_name, name, sort_order, permit_code, start_time, duration_hours, sleep_days)
WHERE dt.code = 'OO';

-- Синтетические допуски к новым должностям: без них кандидатов не будет.
-- Выдаются рядовому и сержантскому составу вместе с прапорщиками.
INSERT INTO personnel.employee_permits (employee_id, permit_type_id, issued_at, expires_at, status)
SELECT e.id, t.id, DATE '2025-01-15', DATE '2027-12-31', 'active'
FROM personnel.employees e
JOIN core.ranks r ON r.id = e.rank_id
CROSS JOIN personnel.permit_types t
WHERE e.is_active AND r.seniority <= 80 AND t.code IN ('ROLE_PTSO', 'ROLE_PUD');
