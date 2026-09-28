-- Оружие на наряд выбирается прямо при назначении, а не отдельной передачей.
--
-- Наличие своего оружия больше не условие назначения: человеку без него при
-- назначении выбирают оружие другого, не занятого в эти и следующие сутки.
-- Выбор хранится в самом назначении (duty_assignments.weapon_id) — при
-- замене человека строка назначения пересоздается, и временное закрепление
-- уходит вместе с ней без отдельного учета.

ALTER TABLE duty.duty_assignments
  ADD COLUMN weapon_id int REFERENCES personnel.weapons(id);
CREATE INDEX ON duty.duty_assignments (weapon_id) WHERE weapon_id IS NOT NULL;

-- Прежние ручные передачи (если были) переносятся в назначения.
UPDATE duty.duty_assignments da SET weapon_id = l.weapon_id
FROM personnel.weapon_loans l
WHERE l.cancelled_at IS NULL AND l.duty_id = da.duty_id AND l.employee_id = da.employee_id;

DROP FUNCTION personnel.available_weapons(int, text, timestamptz, timestamptz);
DROP TABLE personnel.weapon_loans;

-- Временные закрепления оружия — в прежнем виде, для учета оружия и
-- карточки человека: кто, с какого по какое время, в каком наряде.
CREATE VIEW personnel.v_weapon_loans AS
SELECT a.id, da.weapon_id, a.employee_id, a.duty_id, a.post_id,
       a.starts_at, a.ends_at,
       'на время наряда: ' || p.name AS reason
FROM duty.v_assignment_periods a
JOIN duty.duty_assignments da ON da.id = a.id
JOIN duty.duty_posts p        ON p.id = a.post_id
WHERE da.weapon_id IS NOT NULL AND a.status <> 'cancelled';

-- Право прежней ручной передачи теперь означает ведение учета оружия:
-- заведение и постоянное закрепление. Временное закрепление делает
-- назначение наряда.
UPDATE core.permissions SET name = 'Ведение учета оружия' WHERE code = 'weapon.transfer';
