-- ВРИО командира и штаб части.
--
-- ВРИО назначается на период (обычно — отсутствие командира): на эти даты он
-- подписывает приказы вместо командира и получает права командира этого
-- подразделения. Штаб — подразделение с признаком is_headquarters; его
-- командир (начальник штаба) — вторая подпись приказа, под командиром.

CREATE TABLE core.acting_commanders (
  id           serial PRIMARY KEY,
  unit_id      int  NOT NULL REFERENCES core.units(id) ON DELETE CASCADE,
  employee_id  int  NOT NULL REFERENCES personnel.employees(id),
  date_from    date NOT NULL,
  date_to      date NOT NULL CHECK (date_to >= date_from),
  reason       text,
  created_by   int REFERENCES core.users(id),
  created_at   timestamptz NOT NULL DEFAULT now(),
  cancelled_at timestamptz
);
CREATE INDEX ON core.acting_commanders (unit_id, date_from, date_to) WHERE cancelled_at IS NULL;
CREATE INDEX ON core.acting_commanders (employee_id) WHERE cancelled_at IS NULL;

ALTER TABLE core.units ADD COLUMN is_headquarters boolean NOT NULL DEFAULT false;
CREATE UNIQUE INDEX units_one_headquarters ON core.units ((true)) WHERE is_headquarters;

-- Штаб: подразделение части, начальник штаба — командирская должность.
-- Люди — синтетические, как и весь стенд.
DO $$
DECLARE
  root int := (SELECT id FROM core.units WHERE parent_id IS NULL ORDER BY id LIMIT 1);
  hq int;
  chief int; deputy int; clerk int;
BEGIN
  IF root IS NULL OR EXISTS (SELECT 1 FROM core.units WHERE is_headquarters) THEN RETURN; END IF;

  INSERT INTO core.units (parent_id, name, short_name, sort_order, is_headquarters)
  VALUES (root, 'Штаб', 'Штаб', 5, true) RETURNING id INTO hq;

  INSERT INTO personnel.employees (last_name, first_name, middle_name, rank_id, unit_id, position)
  VALUES ('Кравцов', 'Олег', 'Николаевич', (SELECT id FROM core.ranks WHERE name = 'подполковник'), hq, 'Начальник штаба')
  RETURNING id INTO chief;
  INSERT INTO personnel.employees (last_name, first_name, middle_name, rank_id, unit_id, position)
  VALUES ('Белов', 'Андрей', 'Викторович', (SELECT id FROM core.ranks WHERE name = 'майор'), hq, 'Заместитель начальника штаба')
  RETURNING id INTO deputy;
  INSERT INTO personnel.employees (last_name, first_name, middle_name, rank_id, unit_id, position)
  VALUES ('Соколова', 'Ирина', 'Петровна', (SELECT id FROM core.ranks WHERE name = 'прапорщик'), hq, 'Делопроизводитель')
  RETURNING id INTO clerk;

  INSERT INTO core.positions (unit_id, title, sort_order, is_commander, employee_id) VALUES
    (hq, 'Начальник штаба', 10, true, chief),
    (hq, 'Заместитель начальника штаба', 20, false, deputy),
    (hq, 'Помощник начальника штаба', 30, false, NULL),
    (hq, 'Делопроизводитель', 40, false, clerk),
    (hq, 'Писарь', 50, false, NULL);

  UPDATE core.units SET commander_employee_id = chief WHERE id = hq;
END $$;

-- Сохраненные шаблоны приказов: подпись командира — с должностью и
-- званием подписанта (ВРИО подписывает «Врио командира …»), под ней —
-- подпись начальника штаба. Изменение — версией шаблона, как положено.
WITH changed AS (
  SELECT t.id,
         jsonb_set(t.order_template, '{blocks}', (
           SELECT jsonb_agg(CASE
                    WHEN b->>'kind' = 'signature' AND b->>'right' = '{{командир}}'
                    THEN b || '{"text": "{{командир_должность}}\n{{командир_звание}}"}'::jsonb
                    ELSE b END ORDER BY n)
           FROM jsonb_array_elements(t.order_template->'blocks') WITH ORDINALITY AS x(b, n)
         ) || '[{"kind": "signature", "text": "{{начальник_штаба_должность}}\n{{начальник_штаба_звание}}",
                 "right": "{{начальник_штаба}}", "align": "left", "indent": 0, "spaceBefore": 18,
                 "bold": false, "numbered": false, "format": "list", "posts": []}]'::jsonb) AS template
  FROM duty.duty_types t
  WHERE t.order_template IS NOT NULL
    AND NOT (t.order_template::text LIKE '%{{начальник_штаба}}%')
),
versions AS (
  INSERT INTO duty.order_template_versions (duty_type_id, version, template, reason)
  SELECT c.id, coalesce((SELECT max(version) FROM duty.order_template_versions v WHERE v.duty_type_id = c.id), 0) + 1,
         c.template, 'Системой: подпись начальника штаба под командиром; должность подписанта (ВРИО)'
  FROM changed c
  RETURNING duty_type_id
)
UPDATE duty.duty_types t SET order_template = c.template
FROM changed c WHERE c.id = t.id;
