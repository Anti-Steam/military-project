-- 035. Строевая записка.
--
-- Форма взята из приложения № 10 к Уставу внутренней службы ВС РФ
-- («Развернутая строевая записка»). Ее графы: по штату, по списку, налицо,
-- наряд, командировка, отпуск, увольнение, прочее. Оборотная сторона —
-- прикомандированные и поименный перечень отсутствующих.
--
-- Из этих граф в системе не было ДВУХ вещей: штатной численности
-- подразделения и самого ручного ввода отсутствий. Все остальное уже
-- считается: наряд и отсыпной выводятся из назначений, категории отсутствия
-- заведены справочником.

BEGIN;

-- ---------------------------------------------------------------------------
-- «По штату»
--
-- Хранится у подразделения, а не считается: штат задается штатным
-- расписанием и с фактическим списком не совпадает — в этом и смысл графы.
-- ---------------------------------------------------------------------------
ALTER TABLE core.units ADD COLUMN staff_count int;

COMMENT ON COLUMN core.units.staff_count IS
    'Численность по штату для графы «По штату» строевой записки; NULL — не задана';

ALTER TABLE core.units
    ADD CONSTRAINT units_staff_count_sane CHECK (staff_count IS NULL OR staff_count >= 0);

-- ---------------------------------------------------------------------------
-- Ручной ввод отсутствий с заделом под загрузку приказов
--
-- Отсутствия вносятся руками, но МС-3 «DocProcessor» будет заводить их из
-- приказа. Чтобы эти два источника не затирали друг друга, у записи с самого
-- начала есть ПРОИСХОЖДЕНИЕ: разбор приказа вправе обновлять только свои
-- записи, а внесенное человеком остается за человеком. Признак заводится
-- сейчас, когда записей мало, а не тогда, когда их станут тысячи.
--
-- Снятие — пометкой, а не удалением: запись об отсутствии есть основание
-- (приказ, рапорт), и бесследно исчезать оно не должно. Снятая запись к тому
-- же удерживает импорт от повторного заведения того же отпуска.
-- ---------------------------------------------------------------------------
ALTER TABLE personnel.absences
    ADD COLUMN source       text NOT NULL DEFAULT 'manual',
    ADD COLUMN cancelled_at timestamptz,
    ADD COLUMN cancelled_by int REFERENCES core.users(id) ON DELETE SET NULL,
    ADD CONSTRAINT absences_source_known CHECK (source IN ('manual', 'import'));

COMMENT ON COLUMN personnel.absences.source IS
    'Происхождение записи: manual — внесена человеком, import — разобрана из приказа (МС-3)';
COMMENT ON COLUMN personnel.absences.cancelled_at IS
    'Момент снятия записи; снятая запись в расчет наличия не входит, но сохраняется';

CREATE INDEX idx_absences_active ON personnel.absences(employee_id, date_from, date_to)
    WHERE cancelled_at IS NULL;

-- ---------------------------------------------------------------------------
-- Право вносить отсутствия
--
-- Отдельно от personnel.view: смотреть записку положено многим, а ставить
-- человека в отпуск — тем, кто за это отвечает.
-- ---------------------------------------------------------------------------
INSERT INTO core.permissions (code, name, section, sort_order) VALUES
    ('absence.manage', 'Ввод отсутствий личного состава', 'Личный состав', 85);

INSERT INTO core.role_permissions (role_code, permission_code) VALUES
    ('admin', 'absence.manage'), ('deputy', 'absence.manage'),
    ('chief', 'absence.manage'), ('commander', 'absence.manage');

-- ---------------------------------------------------------------------------
-- Синтетический штат стенда
--
-- Списочная численность плюс небольшой некомплект: строевая записка, в
-- которой «по штату» равно «по списку», не показывает того, ради чего графа
-- заведена. Значения вымышленные, как и весь стенд.
-- ---------------------------------------------------------------------------
WITH counted AS (
    SELECT u.id,
           (WITH RECURSIVE sub AS (
                SELECT u.id
                UNION ALL
                SELECT c.id FROM core.units c JOIN sub ON c.parent_id = sub.id
            )
            SELECT count(*)::int
            FROM personnel.employees e
            WHERE e.is_active AND e.unit_id IN (SELECT id FROM sub)) AS listed
    FROM core.units u
)
UPDATE core.units u
   SET staff_count = c.listed + 1 + (u.id % 3)
  FROM counted c
 WHERE c.id = u.id AND c.listed > 0;

COMMIT;
