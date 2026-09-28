-- Командирская должность, не отмеченная вручную: у подразделения без
-- командирской отмечается первая должность, чье наименование начинается с
-- «Командир» (так ее и заводят: «Командир части», «Командир взвода»).
-- Командир подразделения и доступ учетных записей — по ней, как в 050.

UPDATE core.positions p SET is_commander = true
WHERE p.id IN (
  SELECT DISTINCT ON (x.unit_id) x.id FROM core.positions x
  WHERE x.title ILIKE 'командир%'
    AND NOT EXISTS (SELECT 1 FROM core.positions y WHERE y.unit_id = x.unit_id AND y.is_commander)
  ORDER BY x.unit_id, x.sort_order, x.id);

-- Прежний командир, получивший доступ командира этим подразделением, его теряет.
UPDATE core.users us SET role_code = 'user', updated_at = now()
FROM core.units u
JOIN core.positions p ON p.unit_id = u.id AND p.is_commander
WHERE us.employee_id = u.commander_employee_id AND us.role_code = 'commander'
  AND us.scope_unit_id = u.id AND u.commander_employee_id IS DISTINCT FROM p.employee_id;

UPDATE core.units u SET commander_employee_id = p.employee_id, updated_at = now()
FROM core.positions p
WHERE p.unit_id = u.id AND p.is_commander AND u.commander_employee_id IS DISTINCT FROM p.employee_id;

UPDATE core.users us SET role_code = 'commander', scope_unit_id = p.unit_id, updated_at = now()
FROM core.positions p
WHERE p.is_commander AND p.employee_id = us.employee_id AND us.role_code IN ('user', 'commander');
