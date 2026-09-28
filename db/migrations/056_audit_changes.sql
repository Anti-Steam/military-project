-- Журнал изменений (МС-4): каждое добавление, изменение и удаление данных —
-- кто, когда, где, что было и что стало. Пишется ТРИГГЕРАМИ базы, а не
-- кодом приложения: так в журнал попадает любое изменение, какой бы путь в
-- коде к нему ни вел. Кто изменил — приложение сообщает базе параметром
-- app.user_id; без него (миграции, служебные работы) — «система».
--
-- Журнал не правится и не удаляется. Пароли в него не попадают.

CREATE SCHEMA IF NOT EXISTS audit;

CREATE TABLE audit.changes (
  id          bigserial PRIMARY KEY,
  changed_at  timestamptz NOT NULL DEFAULT now(),
  user_id     int,                 -- core.users.id; NULL — система
  table_name  text NOT NULL,       -- схема.таблица
  row_id      text,                -- id записи (если у таблицы он есть)
  action      text NOT NULL CHECK (action IN ('insert', 'update', 'delete')),
  old_data    jsonb,               -- для изменения — только изменившиеся поля
  new_data    jsonb
);
CREATE INDEX ON audit.changes (changed_at DESC);
CREATE INDEX ON audit.changes (table_name, row_id);
CREATE INDEX ON audit.changes (user_id);
CREATE INDEX ON audit.changes ((coalesce(new_data->>'employee_id', old_data->>'employee_id')));

CREATE FUNCTION audit.log_change() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  o jsonb := CASE WHEN TG_OP <> 'INSERT' THEN to_jsonb(OLD) END;
  n jsonb := CASE WHEN TG_OP <> 'DELETE' THEN to_jsonb(NEW) END;
  od jsonb := '{}';
  nd jsonb := '{}';
  k text;
  uid int := nullif(current_setting('app.user_id', true), '')::int;
BEGIN
  -- Не журналируются: пароль, служебные отметки времени правки.
  o := o - 'password_hash' - 'updated_at';
  n := n - 'password_hash' - 'updated_at';

  IF TG_OP = 'UPDATE' THEN
    FOR k IN SELECT jsonb_object_keys(n) LOOP
      IF (o -> k) IS DISTINCT FROM (n -> k) THEN
        od := od || jsonb_build_object(k, o -> k);
        nd := nd || jsonb_build_object(k, n -> k);
      END IF;
    END LOOP;
    IF nd = '{}'::jsonb THEN RETURN NULL; END IF;   -- ничего не изменилось
    -- Для поиска по человеку и записи — опорные поля и при частичном снимке.
    IF n ? 'employee_id' THEN nd := nd || jsonb_build_object('employee_id', n -> 'employee_id'); END IF;
    IF n ? 'owner_id' AND NOT nd ? 'owner_id' THEN od := od || jsonb_build_object('owner_id', o -> 'owner_id'); END IF;
    o := od;
    n := nd;
  END IF;

  INSERT INTO audit.changes (user_id, table_name, row_id, action, old_data, new_data)
  VALUES (uid, TG_TABLE_SCHEMA || '.' || TG_TABLE_NAME,
          coalesce(to_jsonb(NEW) ->> 'id', to_jsonb(OLD) ->> 'id'),
          lower(TG_OP), o, n);
  RETURN NULL;
END $$;

-- Журнал неизменяем.
CREATE FUNCTION audit.forbid_change() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'Журнал изменений не правится и не удаляется';
END $$;
CREATE TRIGGER changes_immutable BEFORE UPDATE OR DELETE ON audit.changes
  FOR EACH ROW EXECUTE FUNCTION audit.forbid_change();
CREATE TRIGGER changes_no_truncate BEFORE TRUNCATE ON audit.changes
  FOR EACH STATEMENT EXECUTE FUNCTION audit.forbid_change();

-- Все таблицы данных. Не журналируются: сессии входа, журнал безопасности
-- (он сам журнал) и справочник прав (меняется только миграциями).
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'core.acting_commanders', 'core.calendar_days', 'core.positions', 'core.ranks',
    'core.role_permissions', 'core.roles', 'core.settings', 'core.units', 'core.user_permissions',
    'core.users',
    'duty.duties', 'duty.duty_assignments', 'duty.duty_posts', 'duty.duty_type_permits',
    'duty.duty_type_schedules', 'duty.duty_types', 'duty.order_template_versions',
    'duty.post_employees', 'duty.post_rank_weights', 'duty.post_responsibilities', 'duty.post_units',
    'personnel.absence_types', 'personnel.absences', 'personnel.employee_permits',
    'personnel.employee_post_weights', 'personnel.employees', 'personnel.permit_directions',
    'personnel.permit_orders', 'personnel.permit_types', 'personnel.weapons'
  ] LOOP
    EXECUTE format('CREATE TRIGGER audit_changes AFTER INSERT OR UPDATE OR DELETE ON %s
                    FOR EACH ROW EXECUTE FUNCTION audit.log_change()', t);
  END LOOP;
END $$;

INSERT INTO core.permissions (code, name, section, sort_order)
VALUES ('audit.view', 'Просмотр журнала изменений', 'Управление', 210)
ON CONFLICT (code) DO NOTHING;
INSERT INTO core.role_permissions (role_code, permission_code) VALUES ('admin', 'audit.view')
ON CONFLICT DO NOTHING;
