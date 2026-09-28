-- Штат: у подразделения — перечень должностей, каждую занимает не больше
-- одного человека; незанятая — вакантная и видна в дереве. Перевод человека —
-- это переход на вакантную должность другого (или того же) подразделения.
--
-- Должности ведет кадровик (и администратор): заводит, переименовывает,
-- удаляет вакантные, переводит любого на любую вакантную. Командир
-- переводит людей только внутри своего подразделения, должности не ведет.

CREATE TABLE core.positions (
  id          serial PRIMARY KEY,
  unit_id     int NOT NULL REFERENCES core.units(id) ON DELETE CASCADE,
  title       text NOT NULL CHECK (length(trim(title)) > 0),
  sort_order  int NOT NULL DEFAULT 0,
  employee_id int UNIQUE REFERENCES personnel.employees(id) ON DELETE SET NULL,
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON core.positions (unit_id, sort_order);

-- Штат из нынешнего состава: у каждого действующего — его должность.
INSERT INTO core.positions (unit_id, title, sort_order, employee_id)
SELECT e.unit_id,
       coalesce(nullif(trim(e.position), ''), 'Должность не указана'),
       10 * row_number() OVER (PARTITION BY e.unit_id ORDER BY r.seniority DESC NULLS LAST, e.last_name, e.id),
       e.id
FROM personnel.employees e
LEFT JOIN core.ranks r ON r.id = e.rank_id
WHERE e.is_active;

INSERT INTO core.permissions (code, name, section, sort_order)
VALUES ('staff.manage', 'Штат: должности и перевод любого сотрудника', 'Личный состав', 55)
ON CONFLICT (code) DO NOTHING;

INSERT INTO core.roles (code, name, level, is_system)
VALUES ('hr', 'Кадровик', 3, true)
ON CONFLICT (code) DO NOTHING;

INSERT INTO core.role_permissions (role_code, permission_code) VALUES
  ('admin', 'staff.manage'),
  ('hr', 'staff.manage'), ('hr', 'personnel.assign'), ('hr', 'personnel.view'),
  ('hr', 'unit.manage'), ('hr', 'duty.view')
ON CONFLICT DO NOTHING;
