-- ============================================================================
-- 001_schema.sql
-- АИС учета личного состава и нарядов. Базовая схема БД.
--
-- Соглашения:
--   * Перечисления реализованы как text + CHECK, а не как ENUM-типы PostgreSQL:
--     добавление значения в ENUM требует ALTER TYPE и плохо откатывается,
--     тогда как CHECK меняется обычной миграцией.
--   * Все отметки времени — timestamptz. Даты без времени — date.
--   * Вычисляемые состояния (истечение допуска, отсыпной, выходной) в БД
--     НЕ хранятся. См. пояснения у соответствующих таблиц.
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- Схемы. Границы совпадают с будущими микросервисами (раздел 3.2 ТЗ).
-- ----------------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS core;       -- общие справочники и учетные записи
CREATE SCHEMA IF NOT EXISTS personnel;  -- МС-1: личный состав, допуски, отсутствия
CREATE SCHEMA IF NOT EXISTS duty;       -- МС-2: наряды и назначения
CREATE SCHEMA IF NOT EXISTS audit;      -- МС-4: журнал изменений


-- ----------------------------------------------------------------------------
-- Общая функция поддержки updated_at
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION core.touch_updated_at()
RETURNS trigger AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;


-- ============================================================================
-- CORE
-- ============================================================================

-- Подразделения. Иерархия через parent_id (adjacency list): при неглубокой
-- структуре рекурсивный CTE по поддереву работает быстро.
CREATE TABLE core.units (
    id          serial PRIMARY KEY,
    name        text        NOT NULL,
    short_name  text        NOT NULL,
    parent_id   int         REFERENCES core.units(id) ON DELETE RESTRICT,
    sort_order  int         NOT NULL DEFAULT 0,  -- порядок в строевой записке
    is_active   boolean     NOT NULL DEFAULT true,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT units_not_self_parent CHECK (parent_id IS DISTINCT FROM id)
);

CREATE INDEX idx_units_parent ON core.units(parent_id);

CREATE TRIGGER trg_units_touch BEFORE UPDATE ON core.units
    FOR EACH ROW EXECUTE FUNCTION core.touch_updated_at();


-- Воинские звания. seniority задает старшинство: по нему сортируется состав
-- в приказах и строевой записке.
CREATE TABLE core.ranks (
    id          serial PRIMARY KEY,
    name        text    NOT NULL UNIQUE,
    short_name  text    NOT NULL,
    seniority   int     NOT NULL UNIQUE,
    is_active   boolean NOT NULL DEFAULT true
);


-- Праздники и дополнительные выходные. Нужны для расчета веса наряда
-- (раздел 8.4 ТЗ). В MVP не используются.
CREATE TABLE core.calendar_days (
    day          date PRIMARY KEY,
    name         text,
    is_holiday   boolean NOT NULL DEFAULT false,
    is_extra_off boolean NOT NULL DEFAULT false  -- дополнительный выходной
);


-- ============================================================================
-- PERSONNEL — МС-1
-- ============================================================================

-- ФИО хранится тремя полями: это требуется для сопоставления людей при
-- парсинге приказов (МС-3) и для печатных форм, где нужен то формат
-- «Иванов И.И.», то полное написание.
CREATE TABLE personnel.employees (
    id                serial PRIMARY KEY,
    last_name         text        NOT NULL,
    first_name        text        NOT NULL,
    middle_name       text,
    rank_id           int         REFERENCES core.ranks(id) ON DELETE RESTRICT,
    position          text,
    unit_id           int         NOT NULL REFERENCES core.units(id) ON DELETE RESTRICT,
    personnel_number  text        UNIQUE,
    phone             text,
    email             text,
    is_active         boolean     NOT NULL DEFAULT true,  -- состоит в списках
    created_at        timestamptz NOT NULL DEFAULT now(),
    updated_at        timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_employees_unit   ON personnel.employees(unit_id);
CREATE INDEX idx_employees_active ON personnel.employees(is_active) WHERE is_active;
CREATE INDEX idx_employees_fio    ON personnel.employees(last_name, first_name, middle_name);

CREATE TRIGGER trg_employees_touch BEFORE UPDATE ON personnel.employees
    FOR EACH ROW EXECUTE FUNCTION core.touch_updated_at();


-- Учетные записи. В MVP используется одна запись, но таблица создается сразу:
-- на нее ссылаются поля created_by / approved_by в нарядах.
CREATE TABLE core.users (
    id              serial PRIMARY KEY,
    employee_id     int         UNIQUE REFERENCES personnel.employees(id) ON DELETE RESTRICT,
    login           text        NOT NULL UNIQUE,
    password_hash   text        NOT NULL,
    role_code       text        NOT NULL DEFAULT 'admin',
    failed_attempts int         NOT NULL DEFAULT 0,
    locked_until    timestamptz,                 -- 3 попытки → блок 10 минут (раздел 6.4)
    is_active       boolean     NOT NULL DEFAULT true,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT users_role_known CHECK (role_code IN (
        'admin',      -- администратор системы
        'deputy',     -- заместитель
        'service',    -- начальник службы
        'commander',  -- командир подразделения
        'user'        -- пользователь
    ))
);

CREATE TRIGGER trg_users_touch BEFORE UPDATE ON core.users
    FOR EACH ROW EXECUTE FUNCTION core.touch_updated_at();


-- Справочник видов допусков (раздел 7.1 ТЗ).
CREATE TABLE personnel.permit_types (
    id                      serial PRIMARY KEY,
    code                    text    NOT NULL UNIQUE,
    name                    text    NOT NULL,
    default_validity_months int,     -- 12, 60; NULL — срок задается «от даты к дате»
    is_duty_specific        boolean NOT NULL DEFAULT false,  -- оформляется к конкретному виду наряда
    notify_days_before      int     NOT NULL DEFAULT 30,
    is_active               boolean NOT NULL DEFAULT true
);


-- ============================================================================
-- DUTY — МС-2 (создается до employee_permits: на duty_types есть внешний ключ)
-- ============================================================================

CREATE TABLE duty.duty_types (
    id                     serial PRIMARY KEY,
    code                   text    NOT NULL UNIQUE,
    name                   text    NOT NULL,
    kind                   text    NOT NULL DEFAULT 'daily',
    start_time             time,            -- время заступления
    duration_hours         int,             -- для суточных — 24
    -- Правила отдыха (раздел 8.2 ТЗ):
    recovery_sleep_days    int     NOT NULL DEFAULT 0,  -- отсыпной: привлечение ЗАПРЕЩЕНО
    recovery_off_days      int     NOT NULL DEFAULT 0,  -- выходной: привлечение ДОПУСКАЕТСЯ
    rest_excludes_weekends boolean NOT NULL DEFAULT false,
    base_weight            numeric(6,2) NOT NULL DEFAULT 1.0,  -- база для балансировки
    is_active              boolean NOT NULL DEFAULT true,

    CONSTRAINT duty_types_kind_known CHECK (kind IN ('daily', 'multiday')),
    CONSTRAINT duty_types_rest_nonneg CHECK (
        recovery_sleep_days >= 0 AND recovery_off_days >= 0
    )
);


-- Допуски, обязательные для заступления в данный вид наряда.
CREATE TABLE duty.duty_type_permits (
    duty_type_id   int NOT NULL REFERENCES duty.duty_types(id) ON DELETE CASCADE,
    permit_type_id int NOT NULL REFERENCES personnel.permit_types(id) ON DELETE RESTRICT,

    PRIMARY KEY (duty_type_id, permit_type_id)
);


-- Состав смены: сколько человек и какой квалификации требуется.
-- В MVP не используется, заполняется на этапе 8.
CREATE TABLE duty.duty_type_slots (
    id                      serial PRIMARY KEY,
    duty_type_id            int  NOT NULL REFERENCES duty.duty_types(id) ON DELETE CASCADE,
    slot_name               text NOT NULL,      -- «Дежурный», «Помощник дежурного»
    headcount               int  NOT NULL DEFAULT 1,
    required_permit_type_id int  REFERENCES personnel.permit_types(id) ON DELETE RESTRICT,
    sort_order              int  NOT NULL DEFAULT 0,

    CONSTRAINT slots_headcount_positive CHECK (headcount > 0)
);

CREATE INDEX idx_slots_duty_type ON duty.duty_type_slots(duty_type_id);


-- Варианты многодневных смен. Для ОО: пятница→вторник и вторник→пятница.
-- Нумерация дней недели по ISO: 1 = понедельник … 7 = воскресенье.
-- В MVP не используется: наряд создается с явно указанными датами.
CREATE TABLE duty.duty_type_schedules (
    id            serial PRIMARY KEY,
    duty_type_id  int  NOT NULL REFERENCES duty.duty_types(id) ON DELETE CASCADE,
    start_weekday int  NOT NULL,
    end_weekday   int  NOT NULL,
    start_time    time,

    CONSTRAINT schedules_weekday_range CHECK (
        start_weekday BETWEEN 1 AND 7 AND end_weekday BETWEEN 1 AND 7
    )
);

CREATE INDEX idx_schedules_duty_type ON duty.duty_type_schedules(duty_type_id);


-- ============================================================================
-- PERSONNEL — допуски сотрудников (зависит от duty.duty_types)
-- ============================================================================

-- История допусков сохраняется: продление создает НОВУЮ строку, старая
-- остается. Поэтому уникального ограничения на пару (сотрудник, вид допуска)
-- здесь нет — действующий допуск определяется запросом (см. представление
-- personnel.v_valid_permits ниже).
--
-- ВАЖНО: значения «истек» в поле status нет. Истечение вычисляется как
-- expires_at < current_date. Хранение потребовало бы ночного пересчета
-- статусов, сбой которого оставил бы сотруднику просроченный допуск.
CREATE TABLE personnel.employee_permits (
    id             serial PRIMARY KEY,
    employee_id    int         NOT NULL REFERENCES personnel.employees(id) ON DELETE CASCADE,
    permit_type_id int         NOT NULL REFERENCES personnel.permit_types(id) ON DELETE RESTRICT,
    -- Заполняется только для допусков с is_duty_specific = true («Суточный наряд»),
    -- который оформляется отдельно к каждому виду наряда.
    duty_type_id   int         REFERENCES duty.duty_types(id) ON DELETE RESTRICT,
    issued_at      date        NOT NULL,
    expires_at     date,                        -- NULL — бессрочный
    status         text        NOT NULL DEFAULT 'active',
    suspended_from date,                        -- приостановка без отзыва (раздел 7.2)
    suspended_to   date,
    suspend_reason text,
    document_ref   text,                        -- номер и дата приказа
    note           text,
    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT permits_status_known CHECK (status IN ('active', 'suspended', 'revoked')),
    CONSTRAINT permits_dates_ordered CHECK (expires_at IS NULL OR expires_at >= issued_at),
    CONSTRAINT permits_suspend_ordered CHECK (
        suspended_to IS NULL OR suspended_from IS NULL OR suspended_to >= suspended_from
    )
);

CREATE INDEX idx_permits_employee ON personnel.employee_permits(employee_id);
CREATE INDEX idx_permits_lookup   ON personnel.employee_permits(employee_id, permit_type_id, duty_type_id);
CREATE INDEX idx_permits_expiry   ON personnel.employee_permits(expires_at) WHERE status = 'active';

CREATE TRIGGER trg_permits_touch BEFORE UPDATE ON personnel.employee_permits
    FOR EACH ROW EXECUTE FUNCTION core.touch_updated_at();


-- Единое определение «действующего допуска». Вся система обязана проверять
-- допуск только через это представление: правило описано один раз и не может
-- разойтись между модулями.
CREATE VIEW personnel.v_valid_permits AS
SELECT
    p.id,
    p.employee_id,
    p.permit_type_id,
    p.duty_type_id,
    p.issued_at,
    p.expires_at
FROM personnel.employee_permits p
WHERE p.status = 'active'
  AND (p.expires_at IS NULL OR p.expires_at >= current_date)
  AND NOT (
        p.suspended_from IS NOT NULL
    AND p.suspended_from <= current_date
    AND (p.suspended_to IS NULL OR p.suspended_to >= current_date)
  );


-- ============================================================================
-- PERSONNEL — отсутствия
-- ============================================================================

-- Закрытый справочник (раздел 9.1 ТЗ). Наряд сюда НЕ входит: сотрудник
-- в наряде виден через duty.duty_assignments, дублирование дало бы расхождение.
CREATE TABLE personnel.absence_types (
    id             serial PRIMARY KEY,
    code           text    NOT NULL UNIQUE,
    name           text    NOT NULL,
    blocks_duty    boolean NOT NULL DEFAULT true,  -- исключает из кандидатов
    sort_order     int     NOT NULL DEFAULT 0
);


CREATE TABLE personnel.absences (
    id              serial PRIMARY KEY,
    employee_id     int         NOT NULL REFERENCES personnel.employees(id) ON DELETE CASCADE,
    absence_type_id int         NOT NULL REFERENCES personnel.absence_types(id) ON DELETE RESTRICT,
    date_from       date        NOT NULL,
    date_to         date        NOT NULL,
    document_ref    text,                        -- приказ на убытие
    note            text,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT absences_dates_ordered CHECK (date_to >= date_from)
);

CREATE INDEX idx_absences_employee ON personnel.absences(employee_id);
CREATE INDEX idx_absences_period   ON personnel.absences(date_from, date_to);

CREATE TRIGGER trg_absences_touch BEFORE UPDATE ON personnel.absences
    FOR EACH ROW EXECUTE FUNCTION core.touch_updated_at();


-- ============================================================================
-- DUTY — наряды и назначения
-- ============================================================================

-- Маршрут согласования (раздел 6.3): командир формирует проект (draft →
-- submitted), начальник службы утверждает (approved).
CREATE TABLE duty.duties (
    id            serial PRIMARY KEY,
    duty_type_id  int         NOT NULL REFERENCES duty.duty_types(id) ON DELETE RESTRICT,
    unit_id       int         NOT NULL REFERENCES core.units(id) ON DELETE RESTRICT,
    starts_at     timestamptz NOT NULL,
    ends_at       timestamptz NOT NULL,
    status        text        NOT NULL DEFAULT 'draft',
    created_by    int         REFERENCES core.users(id) ON DELETE SET NULL,
    approved_by   int         REFERENCES core.users(id) ON DELETE SET NULL,
    approved_at   timestamptz,
    note          text,
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT duties_status_known CHECK (status IN ('draft', 'submitted', 'approved', 'cancelled')),
    CONSTRAINT duties_period_ordered CHECK (ends_at > starts_at),
    CONSTRAINT duties_approval_consistent CHECK (
        (status = 'approved') = (approved_at IS NOT NULL)
    )
);

CREATE INDEX idx_duties_type   ON duty.duties(duty_type_id);
CREATE INDEX idx_duties_unit   ON duty.duties(unit_id);
CREATE INDEX idx_duties_period ON duty.duties(starts_at, ends_at);

CREATE TRIGGER trg_duties_touch BEFORE UPDATE ON duty.duties
    FOR EACH ROW EXECUTE FUNCTION core.touch_updated_at();


-- Состав наряда. Поля is_override фиксируют назначение с нарушением правил
-- отбора: право начальника службы при нехватке кандидатов (раздел 8.5),
-- факт нарушения отображается вышестоящим и администратору.
CREATE TABLE duty.duty_assignments (
    id              serial PRIMARY KEY,
    duty_id         int         NOT NULL REFERENCES duty.duties(id) ON DELETE CASCADE,
    employee_id     int         NOT NULL REFERENCES personnel.employees(id) ON DELETE RESTRICT,
    slot_id         int         REFERENCES duty.duty_type_slots(id) ON DELETE SET NULL,
    is_override     boolean     NOT NULL DEFAULT false,
    override_reason text,
    override_by     int         REFERENCES core.users(id) ON DELETE SET NULL,
    created_at      timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT assignments_unique_employee UNIQUE (duty_id, employee_id),
    CONSTRAINT assignments_override_has_reason CHECK (
        NOT is_override OR override_reason IS NOT NULL
    )
);

CREATE INDEX idx_assignments_duty     ON duty.duty_assignments(duty_id);
CREATE INDEX idx_assignments_employee ON duty.duty_assignments(employee_id);


-- ============================================================================
-- AUDIT — МС-4. В MVP не заполняется.
-- ============================================================================

CREATE TABLE audit.change_log (
    id          bigserial PRIMARY KEY,
    schema_name text        NOT NULL,
    table_name  text        NOT NULL,
    record_id   text        NOT NULL,
    action      text        NOT NULL,
    source      text        NOT NULL DEFAULT 'manual',  -- ручной ввод или импорт из документа
    document_ref text,                                  -- первоисточник при импорте
    changed_by  int         REFERENCES core.users(id) ON DELETE SET NULL,
    changed_at  timestamptz NOT NULL DEFAULT now(),
    old_values  jsonb,
    new_values  jsonb,

    CONSTRAINT audit_action_known CHECK (action IN ('insert', 'update', 'delete')),
    CONSTRAINT audit_source_known CHECK (source IN ('manual', 'import'))
);

CREATE INDEX idx_audit_record ON audit.change_log(schema_name, table_name, record_id);
CREATE INDEX idx_audit_time   ON audit.change_log(changed_at DESC);

COMMIT;
