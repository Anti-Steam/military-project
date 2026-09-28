-- Журнал изменений: служебные поля учетной записи, которые меняет сам вход
-- (время входа, счетчик неудачных попыток, блокировка, смена пароля), — не
-- журналируются: входы и пароли и так пишутся в журнал безопасности
-- (core.security_events), а здесь каждый вход был бы «изменением».

CREATE OR REPLACE FUNCTION audit.log_change() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  o jsonb := CASE WHEN TG_OP <> 'INSERT' THEN to_jsonb(OLD) END;
  n jsonb := CASE WHEN TG_OP <> 'DELETE' THEN to_jsonb(NEW) END;
  od jsonb := '{}';
  nd jsonb := '{}';
  k text;
  uid int := nullif(current_setting('app.user_id', true), '')::int;
  noise text[] := ARRAY['password_hash', 'updated_at', 'last_login_at', 'failed_attempts',
                        'locked_until', 'password_changed_at', 'must_change_password'];
BEGIN
  o := o - noise;
  n := n - noise;

  IF TG_OP = 'UPDATE' THEN
    FOR k IN SELECT jsonb_object_keys(n) LOOP
      IF (o -> k) IS DISTINCT FROM (n -> k) THEN
        od := od || jsonb_build_object(k, o -> k);
        nd := nd || jsonb_build_object(k, n -> k);
      END IF;
    END LOOP;
    IF nd = '{}'::jsonb THEN RETURN NULL; END IF;
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
