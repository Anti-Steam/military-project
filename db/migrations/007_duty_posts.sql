-- ============================================================================
-- 007_duty_posts.sql
-- Введение постов (дежурных должностей) и перевод допусков на посты.
--
-- Согласовано (разделы 8.2, 8.3, 7.3 ТЗ):
--   • Наряд состоит из постов; перечень постов свой у каждого вида наряда.
--   • Допуск оформляется К ПОСТУ, а не к виду наряда.
--   • На каждый пост назначается ОДИН человек. Если на должности несколько
--     человек, они заводятся отдельными нумерованными постами. Отдельного
--     поля штатной численности нет: оно давало бы второй способ выразить
--     то же самое и допускало бы расхождение между двумя записями.
--   • Пост может относиться к конкретному подразделению (дежурный по роте —
--     отдельный пост в каждой роте) либо быть общим (дежурный по части).
--   • Один приказ оформляет допуски нескольким людям к разным постам.
--
-- Данные нарядов и постовых допусков в этой миграции удаляются: они
-- синтетические и не могут быть автоматически сопоставлены с постами.
-- Заново заполняются миграциями 008 и 009.
-- ============================================================================

BEGIN;

-- Представление ссылается на удаляемую колонку — пересоздается в конце.
DROP VIEW IF EXISTS personnel.v_valid_permits;


-- ----------------------------------------------------------------------------
-- Посты (дежурные должности)
-- ----------------------------------------------------------------------------
CREATE TABLE duty.duty_posts (
    id           serial PRIMARY KEY,
    duty_type_id int         NOT NULL REFERENCES duty.duty_types(id) ON DELETE RESTRICT,
    -- NULL — пост общий для части (дежурный по части).
    -- Заполнено — пост относится к подразделению (дежурный по 1 роте).
    unit_id      int         REFERENCES core.units(id) ON DELETE RESTRICT,
    short_name   text,                       -- КДС, ЗКДС, НПНР — для печатных форм
    name         text        NOT NULL,
    sort_order   int         NOT NULL DEFAULT 0,  -- порядок вывода в приказе
    -- Вывод поста из применения выполняется признаком, а НЕ удалением строки:
    -- наряды прошлых периодов обязаны сохранять ссылку на пост, по которому
    -- личный состав фактически нес службу.
    is_active    boolean     NOT NULL DEFAULT true,
    created_at   timestamptz NOT NULL DEFAULT now(),
    updated_at   timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_posts_duty_type ON duty.duty_posts(duty_type_id);
CREATE INDEX idx_posts_unit      ON duty.duty_posts(unit_id);

-- Наименование поста уникально в пределах вида наряда и подразделения.
-- COALESCE нужен потому, что NULL в PostgreSQL не равен другому NULL и
-- без него общие посты могли бы дублироваться.
CREATE UNIQUE INDEX uq_posts_name
    ON duty.duty_posts (duty_type_id, COALESCE(unit_id, 0), name);

CREATE TRIGGER trg_posts_touch BEFORE UPDATE ON duty.duty_posts
    FOR EACH ROW EXECUTE FUNCTION core.touch_updated_at();


-- ----------------------------------------------------------------------------
-- Приказы о допуске (раздел 7.3 ТЗ)
-- ----------------------------------------------------------------------------
CREATE TABLE personnel.permit_orders (
    id         serial PRIMARY KEY,
    number     text        NOT NULL,
    issued_on  date        NOT NULL,
    title      text,
    note       text,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX uq_permit_orders ON personnel.permit_orders (number, issued_on);

CREATE TRIGGER trg_permit_orders_touch BEFORE UPDATE ON personnel.permit_orders
    FOR EACH ROW EXECUTE FUNCTION core.touch_updated_at();


-- ----------------------------------------------------------------------------
-- Назначения: вместо позиции смены — пост.
--
-- Существующие наряды удаляются: они созданы до введения постов, и назначение
-- без поста в новой модели смысла не имеет. Данные синтетические.
-- ----------------------------------------------------------------------------
DELETE FROM duty.duty_assignments;
DELETE FROM duty.duties;

ALTER TABLE duty.duty_assignments DROP COLUMN slot_id;
ALTER TABLE duty.duty_assignments
    ADD COLUMN post_id int NOT NULL REFERENCES duty.duty_posts(id) ON DELETE RESTRICT;

CREATE INDEX idx_assignments_post ON duty.duty_assignments(post_id);

-- На пост назначается один человек, поэтому в пределах наряда пост занят
-- не более одного раза.
CREATE UNIQUE INDEX uq_assignment_post ON duty.duty_assignments (duty_id, post_id);

-- Таблица позиций смены заменена постами.
DROP TABLE duty.duty_type_slots;


-- ----------------------------------------------------------------------------
-- Виды допусков: признак «оформляется к посту»
-- ----------------------------------------------------------------------------
ALTER TABLE personnel.permit_types RENAME COLUMN is_duty_specific TO is_post_specific;

-- «Охрана и оборона» также оформляется к посту дежурной смены.
UPDATE personnel.permit_types SET is_post_specific = true WHERE code IN ('SN', 'OO');

-- Постовые допуски, оформленные по прежней модели, сопоставить с постами
-- автоматически невозможно. Удаляются и заводятся заново миграцией 009.
DELETE FROM personnel.employee_permits
 WHERE permit_type_id IN (SELECT id FROM personnel.permit_types WHERE is_post_specific);


-- ----------------------------------------------------------------------------
-- Допуски сотрудников: привязка к посту и к приказу
-- ----------------------------------------------------------------------------
DROP INDEX personnel.idx_permits_lookup;

ALTER TABLE personnel.employee_permits DROP COLUMN duty_type_id;

ALTER TABLE personnel.employee_permits
    ADD COLUMN post_id  int REFERENCES duty.duty_posts(id) ON DELETE RESTRICT,
    ADD COLUMN order_id int REFERENCES personnel.permit_orders(id) ON DELETE SET NULL;

CREATE INDEX idx_permits_lookup ON personnel.employee_permits(employee_id, permit_type_id, post_id);
CREATE INDEX idx_permits_post   ON personnel.employee_permits(post_id);
CREATE INDEX idx_permits_order  ON personnel.employee_permits(order_id);


-- ----------------------------------------------------------------------------
-- Согласованность допуска и поста.
--
-- Правило «постовой допуск обязан указывать пост, общий — не должен»
-- затрагивает две таблицы, поэтому ограничением CHECK не выражается.
-- Триггер закрывает целый класс ошибок: постовой допуск без поста не допустил
-- бы никого либо, при неаккуратном запросе, всех сразу.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION personnel.check_permit_post()
RETURNS trigger AS $$
DECLARE
    post_specific boolean;
BEGIN
    SELECT is_post_specific INTO post_specific
      FROM personnel.permit_types WHERE id = NEW.permit_type_id;

    IF post_specific AND NEW.post_id IS NULL THEN
        RAISE EXCEPTION 'Допуск этого вида оформляется к посту: поле post_id обязательно';
    END IF;

    IF NOT post_specific AND NEW.post_id IS NOT NULL THEN
        RAISE EXCEPTION 'Допуск этого вида является общим и к посту не привязывается';
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_permits_check_post
    BEFORE INSERT OR UPDATE ON personnel.employee_permits
    FOR EACH ROW EXECUTE FUNCTION personnel.check_permit_post();


-- ----------------------------------------------------------------------------
-- Единое определение действующего допуска (с постом)
-- ----------------------------------------------------------------------------
CREATE VIEW personnel.v_valid_permits AS
SELECT
    p.id,
    p.employee_id,
    p.permit_type_id,
    p.post_id,
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

COMMIT;
