-- Оружие по подразделениям — как штат.
--
-- Оружие числится в подразделении (unit_id) и может быть закреплено за
-- человеком (owner_id). Незакрепленное оружие подразделения числится за его
-- командиром — это личное оружие командира. Оружие вне подразделений —
-- свободное (склад). Списанное — is_active = false.

ALTER TABLE personnel.weapons
  ADD COLUMN unit_id int REFERENCES core.units(id) ON DELETE SET NULL,
  ADD COLUMN sort_order int NOT NULL DEFAULT 0;

UPDATE personnel.weapons w SET unit_id = e.unit_id
FROM personnel.employees e WHERE e.id = w.owner_id;

UPDATE personnel.weapons w SET sort_order = x.n * 10
FROM (SELECT id, row_number() OVER (PARTITION BY unit_id ORDER BY kind, serial_number) AS n
      FROM personnel.weapons) x
WHERE x.id = w.id;

-- За кем числится оружие: за закрепленным, иначе — за командиром
-- подразделения. Этим пользуется подбор оружия на наряд.
CREATE VIEW personnel.v_weapons AS
SELECT w.*, coalesce(w.owner_id, u.commander_employee_id) AS holder_id
FROM personnel.weapons w
LEFT JOIN core.units u ON u.id = w.unit_id;

UPDATE core.permissions SET name = 'Оружие: полный доступ (заведение, списание, склад, любые подразделения)'
WHERE code = 'weapon.transfer';
INSERT INTO core.permissions (code, name, section, sort_order)
VALUES ('weapon.assign', 'Оружие: закрепление и перемещение в своем подразделении', 'Оружие', 95)
ON CONFLICT (code) DO NOTHING;

INSERT INTO core.roles (code, name, level, is_system)
VALUES ('armament', 'Начальник службы вооружения', 3, true)
ON CONFLICT (code) DO NOTHING;

INSERT INTO core.role_permissions (role_code, permission_code) VALUES
  ('admin', 'weapon.assign'), ('commander', 'weapon.assign'),
  ('armament', 'weapon.view'), ('armament', 'weapon.transfer'), ('armament', 'weapon.assign'),
  ('armament', 'personnel.view'), ('armament', 'duty.view')
ON CONFLICT DO NOTHING;
