-- 028. Оргструктура, закрепление подразделения за пользователем и
-- ответственное подразделение наряда.
--
-- Ради чего это делается: начальник службы закрепляет за нарядом на
-- конкретные сутки ОТВЕТСТВЕННОЕ ПОДРАЗДЕЛЕНИЕ, а состав назначает уже
-- командир этого подразделения. Чтобы такой порядок работал, нужны три вещи:
-- вложенная структура подразделений, связь пользователя с подразделением и
-- сама запись об ответственности.

-- Командир подразделения — сотрудник, а не учетная запись: он может вообще
-- не работать в системе, но в строевой записке и в дереве значиться обязан.
ALTER TABLE core.units
    ADD COLUMN commander_employee_id int REFERENCES personnel.employees(id) ON DELETE SET NULL;

-- Закрепленное подразделение. NULL — вся часть: так работают администратор,
-- заместители и начальники служб, видящие все.
ALTER TABLE core.users
    ADD COLUMN scope_unit_id int REFERENCES core.units(id) ON DELETE RESTRICT;

COMMENT ON COLUMN core.users.scope_unit_id IS
    'Подразделение, закрепленное за пользователем. Видит и ведет его вместе '
    'со всеми вложенными. NULL — вся часть';

-- Ответственность за наряд на сутки.
--
-- Ключ — вид наряда и сутки заступления, а не запись наряда: закрепить
-- подразделение нужно ДО того, как состав назначен, иначе командиру неоткуда
-- узнать, что эти сутки его. Записи наряда на этот момент еще нет.
CREATE TABLE duty.responsibilities (
    duty_type_id int  NOT NULL REFERENCES duty.duty_types(id) ON DELETE CASCADE,
    on_date      date NOT NULL,
    unit_id      int  NOT NULL REFERENCES core.units(id) ON DELETE RESTRICT,
    note         text,
    assigned_by  int  REFERENCES core.users(id) ON DELETE SET NULL,
    assigned_at  timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (duty_type_id, on_date)
);
CREATE INDEX idx_responsibilities_unit ON duty.responsibilities(unit_id);

INSERT INTO core.permissions (code, name, section, sort_order) VALUES
    ('unit.manage',        'Структура подразделений',              'Личный состав',  75),
    ('personnel.assign',   'Распределение личного состава',        'Личный состав',  76),
    ('duty.responsibility','Закрепление подразделения за нарядом', 'Наряды',         35);

INSERT INTO core.role_permissions (role_code, permission_code) VALUES
    ('admin', 'unit.manage'), ('admin', 'personnel.assign'), ('admin', 'duty.responsibility'),
    ('deputy', 'unit.manage'), ('deputy', 'personnel.assign'), ('deputy', 'duty.responsibility'),
    -- Начальник службы распределяет наряды по подразделениям, но штат не ведет.
    ('chief', 'duty.responsibility'),
    -- Командир ведет структуру и людей ВНУТРИ своего подразделения.
    ('commander', 'unit.manage'), ('commander', 'personnel.assign');

-- ---------------------------------------------------------------------------
-- Синтетическая структура рот: взводы и отделения.
--
-- Без вложенности дерево подразделений показывать не на чем, а весь смысл
-- закрепления — в том, что командир взвода отвечает за свои отделения.
-- ---------------------------------------------------------------------------

INSERT INTO core.units (name, short_name, parent_id, sort_order)
SELECT concat(v.n, ' взвод ', r.short_name), concat(v.n, ' взвод ', r.short_name),
       r.id, v.n * 10
FROM core.units r
CROSS JOIN (VALUES (1), (2), (3)) AS v(n)
WHERE r.short_name IN ('1 рота', '2 рота');

INSERT INTO core.units (name, short_name, parent_id, sort_order)
SELECT concat(o.n, ' отделение ', p.short_name), concat(o.n, ' отд. ', p.short_name),
       p.id, o.n * 10
FROM core.units p
CROSS JOIN (VALUES (1), (2), (3)) AS o(n)
WHERE p.short_name LIKE '% взвод %';

-- Люди рот расходятся по отделениям; в роте остается управление, во взводе —
-- его командир. Распределение синтетическое и нужно только для показа.
CREATE TEMP TABLE distribution AS
WITH company AS (
    SELECT e.id AS employee_id, e.unit_id AS company_id, r.seniority,
           row_number() OVER (PARTITION BY e.unit_id ORDER BY r.seniority DESC, e.id) AS place
    FROM personnel.employees e
    JOIN core.ranks r ON r.id = e.rank_id
    JOIN core.units u ON u.id = e.unit_id
    WHERE u.short_name IN ('1 рота', '2 рота')
),
platoons AS (
    SELECT id, parent_id, row_number() OVER (PARTITION BY parent_id ORDER BY sort_order) AS n
    FROM core.units WHERE short_name LIKE '% взвод %'
),
squads AS (
    SELECT s.id, p.parent_id AS company_id, p.n AS platoon_n,
           row_number() OVER (PARTITION BY s.parent_id ORDER BY s.sort_order) AS n
    FROM core.units s JOIN platoons p ON p.id = s.parent_id
)
SELECT c.employee_id,
       CASE
           -- Двое старших остаются в управлении роты.
           WHEN c.place <= 2 THEN c.company_id
           -- Следующие трое — командиры взводов.
           WHEN c.place <= 5 THEN (SELECT id FROM platoons p
                                    WHERE p.parent_id = c.company_id AND p.n = c.place - 2)
           -- Остальные расходятся по отделениям по кругу.
           ELSE (SELECT s.id FROM squads s
                  WHERE s.company_id = c.company_id
                    AND s.platoon_n = ((c.place - 6) / 3) % 3 + 1
                    AND s.n = (c.place - 6) % 3 + 1)
       END AS unit_id
FROM company c;

UPDATE personnel.employees e
   SET unit_id = d.unit_id, updated_at = now()
FROM distribution d
WHERE e.id = d.employee_id AND d.unit_id IS NOT NULL;

-- Командир подразделения — старший по званию в нем.
UPDATE core.units u
   SET commander_employee_id = (
       SELECT e.id FROM personnel.employees e
       JOIN core.ranks r ON r.id = e.rank_id
       WHERE e.unit_id = u.id AND e.is_active
       ORDER BY r.seniority DESC, e.id
       LIMIT 1
   )
 WHERE EXISTS (SELECT 1 FROM personnel.employees e WHERE e.unit_id = u.id);
