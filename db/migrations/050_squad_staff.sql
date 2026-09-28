-- Штат отделений и командирская должность.
--
-- Все отделения рот — одинаковые, по восемь должностей, первая —
-- командирская. Командир подразделения теперь следует из штата: кто занимает
-- командирскую должность, тот и командир (units.commander_employee_id), а
-- его учетная запись получает доступ командира этого подразделения.

ALTER TABLE core.positions ADD COLUMN is_commander boolean NOT NULL DEFAULT false;
CREATE UNIQUE INDEX positions_one_commander ON core.positions (unit_id) WHERE is_commander;

-- Отделения: восемь одинаковых должностей. Нынешние люди рассаживаются:
-- командир отделения — на командирскую, остальные по старшинству. Лишних
-- (больше восьми) нет; окажись они — остались бы вне штата.
DO $$
DECLARE
  squad record;
  titles text[] := ARRAY['Командир отделения', 'Заместитель командира отделения',
    'Наводчик-оператор', 'Механик-водитель', 'Пулемётчик', 'Гранатомётчик',
    'Старший стрелок', 'Стрелок'];
  people int[];
BEGIN
  FOR squad IN
    SELECT u.id, u.commander_employee_id FROM core.units u
    WHERE u.name ILIKE '%отделение%'
      AND NOT EXISTS (SELECT 1 FROM core.units c WHERE c.parent_id = u.id)
  LOOP
    people := ARRAY(
      SELECT e.id FROM personnel.employees e
      LEFT JOIN core.positions p ON p.employee_id = e.id
      LEFT JOIN core.ranks r     ON r.id = e.rank_id
      WHERE e.unit_id = squad.id AND e.is_active
      ORDER BY (e.id = squad.commander_employee_id) DESC NULLS LAST,
               (p.title ILIKE 'командир%') DESC NULLS LAST,
               r.seniority DESC NULLS LAST, e.last_name, e.id);

    DELETE FROM core.positions WHERE unit_id = squad.id;
    FOR i IN 1..8 LOOP
      INSERT INTO core.positions (unit_id, title, sort_order, is_commander, employee_id)
      VALUES (squad.id, titles[i], i * 10, i = 1, people[i]);
    END LOOP;

    UPDATE personnel.employees e SET position = p.title, updated_at = now()
    FROM core.positions p WHERE p.unit_id = squad.id AND p.employee_id = e.id;
    UPDATE core.units SET commander_employee_id = people[1] WHERE id = squad.id;
  END LOOP;
END $$;

-- Остальные подразделения: командирская — должность нынешнего командира,
-- если он в штате этого подразделения; иначе первая «Командир …».
UPDATE core.positions p SET is_commander = true
FROM core.units u
WHERE u.id = p.unit_id AND p.employee_id = u.commander_employee_id
  AND NOT EXISTS (SELECT 1 FROM core.positions x WHERE x.unit_id = u.id AND x.is_commander);

UPDATE core.positions p SET is_commander = true
WHERE p.id IN (
  SELECT DISTINCT ON (x.unit_id) x.id FROM core.positions x
  WHERE x.title ILIKE 'командир%'
    AND NOT EXISTS (SELECT 1 FROM core.positions y WHERE y.unit_id = x.unit_id AND y.is_commander)
  ORDER BY x.unit_id, x.sort_order, x.id);

UPDATE core.units u SET commander_employee_id = p.employee_id
FROM core.positions p WHERE p.unit_id = u.id AND p.is_commander AND p.employee_id IS NOT NULL;

-- Учетные записи командиров — доступ командира своего подразделения.
-- Роли выше командира не понижаются.
UPDATE core.users us SET role_code = 'commander', scope_unit_id = p.unit_id, updated_at = now()
FROM core.positions p
WHERE p.is_commander AND p.employee_id = us.employee_id AND us.role_code IN ('user', 'commander');
