-- ============================================================================
-- 011. Календарь нарядов: справочник празднично-выходных дней и признак
--      источника назначения.
--
-- Раздел 8.9 ТЗ. Календарь показывает не только созданные наряды, но и те,
-- которые ПОЛОЖЕНЫ по расписанию вида наряда и не созданы, — иначе пропуск
-- невидим. Чтобы отличить рабочий день от нерабочего, нужен справочник:
-- по календарю определяется срок выпуска приказа.
-- ============================================================================


-- Таблица core.calendar_days заведена в 001 с парой признаков is_holiday и
-- is_extra_off. Эта пара не выражает перенос рабочего дня на субботу: суббота
-- нерабочая по дню недели, а признака «рабочий вопреки дню недели» нет.
-- Заменяется одним полем kind. Таблица пуста и кодом не используется.
ALTER TABLE core.calendar_days DROP COLUMN is_holiday;
ALTER TABLE core.calendar_days DROP COLUMN is_extra_off;

ALTER TABLE core.calendar_days ADD COLUMN kind text NOT NULL DEFAULT 'holiday';
ALTER TABLE core.calendar_days ALTER COLUMN kind DROP DEFAULT;
ALTER TABLE core.calendar_days
    ADD CONSTRAINT calendar_kind_known CHECK (kind IN ('holiday', 'workday'));

ALTER TABLE core.calendar_days ADD COLUMN created_at timestamptz NOT NULL DEFAULT now();
ALTER TABLE core.calendar_days ADD COLUMN updated_at timestamptz NOT NULL DEFAULT now();

CREATE TRIGGER trg_calendar_touch BEFORE UPDATE ON core.calendar_days
    FOR EACH ROW EXECUTE FUNCTION core.touch_updated_at();

COMMENT ON TABLE core.calendar_days IS
    'Отклонения от обычной рабочей недели. Суббота и воскресенье нерабочие по '
    'умолчанию и здесь не хранятся. Ведется вручную: состав нерабочих дней '
    'меняется год от года, переносы объявляются отдельно.';

COMMENT ON COLUMN core.calendar_days.kind IS
    'holiday — нерабочий день (праздник либо объявленный выходной); '
    'workday — рабочий день вопреки дню недели (перенос).';


-- Кем назначен человек на пост. Автоматическая расстановка по весам (раздел
-- 8.6) появится позже, но признак нужен уже сейчас: календарь показывает
-- предложенный системой состав отдельным цветом, потому что такой наряд
-- начальник еще не смотрел, в отличие от назначенного вручную.
ALTER TABLE duty.duty_assignments
    ADD COLUMN source text NOT NULL DEFAULT 'manual';

ALTER TABLE duty.duty_assignments
    ADD CONSTRAINT assignments_source_known CHECK (source IN ('manual', 'auto'));

COMMENT ON COLUMN duty.duty_assignments.source IS
    'manual — назначил человек; auto — предложила система, требуется '
    'подтверждение начальника.';


-- Нерабочие праздничные дни по статье 112 ТК РФ, без переносов: переносы
-- устанавливаются отдельным постановлением на каждый год и здесь угаданы
-- быть не могут. Правится через справочник в интерфейсе.
INSERT INTO core.calendar_days (day, kind, name)
SELECT make_date(y.year, h.month, h.day), 'holiday', h.title
FROM generate_series(2026, 2027) AS y(year),
     (VALUES
         (1,  1, 'Новогодние каникулы'),
         (1,  2, 'Новогодние каникулы'),
         (1,  3, 'Новогодние каникулы'),
         (1,  4, 'Новогодние каникулы'),
         (1,  5, 'Новогодние каникулы'),
         (1,  6, 'Новогодние каникулы'),
         (1,  7, 'Рождество Христово'),
         (1,  8, 'Новогодние каникулы'),
         (2, 23, 'День защитника Отечества'),
         (3,  8, 'Международный женский день'),
         (5,  1, 'Праздник Весны и Труда'),
         (5,  9, 'День Победы'),
         (6, 12, 'День России'),
         (11, 4, 'День народного единства')
     ) AS h(month, day, title)
ON CONFLICT (day) DO NOTHING;
