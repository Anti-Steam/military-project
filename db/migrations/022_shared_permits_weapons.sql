-- Согласованные правила: общий допуск к должности, один наряд на часть,
-- оружие и временная передача. Старые миграции остаются неизменными.
ALTER TABLE duty.duty_posts
  ADD COLUMN required_permit_type_id int REFERENCES personnel.permit_types(id),
  ADD COLUMN required_weapon_kind text CHECK (required_weapon_kind IN ('rifle','pistol'));

CREATE TEMP TABLE post_roles AS
SELECT id, duty_type_id,
 CASE WHEN name LIKE 'Дневальный по %' THEN 'Дневальный по роте'
      WHEN name LIKE 'Дежурный по %роте%' OR name LIKE 'Дежурный по %рота%' THEN 'Дежурный по роте'
      WHEN name LIKE 'Номер расчета %' THEN 'Номер расчета'
      ELSE name END AS role_name
FROM duty.duty_posts;
INSERT INTO personnel.permit_types(code,name,is_post_specific,default_validity_months)
SELECT 'ROLE_' || min(id), role_name, false, 12 FROM post_roles GROUP BY duty_type_id,role_name;
UPDATE duty.duty_posts p SET required_permit_type_id=t.id
FROM post_roles r, personnel.permit_types t
WHERE r.id=p.id AND t.code=(SELECT 'ROLE_' || min(x.id) FROM post_roles x
 WHERE x.duty_type_id=r.duty_type_id AND x.role_name=r.role_name);
DROP TRIGGER trg_permits_check_post ON personnel.employee_permits;
UPDATE personnel.employee_permits ep SET permit_type_id=p.required_permit_type_id, post_id=NULL
FROM duty.duty_posts p WHERE ep.post_id=p.id;
CREATE TRIGGER trg_permits_check_post BEFORE INSERT OR UPDATE ON personnel.employee_permits
 FOR EACH ROW EXECUTE FUNCTION personnel.check_permit_post();
UPDATE duty.duty_posts SET required_weapon_kind='rifle'
WHERE duty_type_id=(SELECT id FROM duty.duty_types WHERE code='OO');

ALTER TABLE core.users ADD COLUMN can_transfer_weapons boolean NOT NULL DEFAULT false;
CREATE TABLE personnel.weapons (
 id serial PRIMARY KEY,
 name text NOT NULL CHECK (length(trim(name))>0),
 serial_number text NOT NULL UNIQUE CHECK (length(trim(serial_number))>0),
 manufactured_on date NOT NULL,
 kind text NOT NULL CHECK (kind IN ('rifle','pistol')),
 owner_id int REFERENCES personnel.employees(id),
 is_active boolean NOT NULL DEFAULT true
);
CREATE TABLE personnel.weapon_loans (
 id serial PRIMARY KEY,
 weapon_id int NOT NULL REFERENCES personnel.weapons(id),
 employee_id int NOT NULL REFERENCES personnel.employees(id),
 duty_id int NOT NULL REFERENCES duty.duties(id),
 starts_at timestamptz NOT NULL,
 ends_at timestamptz NOT NULL CHECK (ends_at>starts_at),
 reason text NOT NULL CHECK (length(trim(reason))>0),
 created_by int NOT NULL REFERENCES core.users(id),
 created_at timestamptz NOT NULL DEFAULT now(),
 cancelled_at timestamptz
);
CREATE INDEX ON personnel.weapon_loans(weapon_id,starts_at,ends_at) WHERE cancelled_at IS NULL;
-- Единственное правило доступности оружия на весь период наряда.
CREATE FUNCTION personnel.available_weapons(emp int, kind_needed text, from_at timestamptz, to_at timestamptz)
RETURNS SETOF personnel.weapons LANGUAGE sql STABLE AS $$
 SELECT w.* FROM personnel.weapons w
 WHERE w.is_active AND (kind_needed IS NULL OR w.kind=kind_needed)
 AND (
   (w.owner_id=emp AND NOT EXISTS(SELECT 1 FROM personnel.weapon_loans l
     WHERE l.weapon_id=w.id AND l.cancelled_at IS NULL AND l.starts_at<to_at AND l.ends_at>from_at))
   OR EXISTS(SELECT 1 FROM personnel.weapon_loans l WHERE l.weapon_id=w.id
     AND l.employee_id=emp AND l.cancelled_at IS NULL AND l.starts_at<=from_at AND l.ends_at>=to_at)
 )
$$;

-- Только синтетическое наполнение стенда: два рядовых без оружия.
INSERT INTO personnel.weapons(name,serial_number,manufactured_on,kind,owner_id)
SELECT CASE WHEN r.seniority>=90 THEN 'Учебный пистолет' ELSE 'Учебный автомат' END,
 'TEST-' || e.id, DATE '2024-01-01', CASE WHEN r.seniority>=90 THEN 'pistol' ELSE 'rifle' END,e.id
FROM personnel.employees e JOIN core.ranks r ON r.id=e.rank_id
WHERE e.is_active AND e.id NOT IN (SELECT e2.id FROM personnel.employees e2
 JOIN core.ranks r2 ON r2.id=e2.rank_id WHERE r2.name='рядовой' ORDER BY e2.id LIMIT 2);

ALTER TABLE duty.duties ADD COLUMN approved_snapshot jsonb, ADD COLUMN order_snapshot jsonb,
 ADD COLUMN order_deadline date;
ALTER TABLE duty.duty_assignments ADD COLUMN override_checks text[] NOT NULL DEFAULT '{}';
-- У старых дублей сохраняются записи и состав; лишние активные записи отменяются.
WITH duplicates AS (SELECT id,row_number() OVER (
 PARTITION BY duty_type_id,(starts_at AT TIME ZONE current_setting('TimeZone'))::date
 ORDER BY (status='approved') DESC,id) AS n FROM duty.duties WHERE status<>'cancelled')
UPDATE duty.duties d SET status='cancelled',approved_at=NULL,approved_by=NULL,
 note=concat_ws(E'\n',note,'Миграция 022: дублирующий наряд сохранён как отменённый')
FROM duplicates x WHERE d.id=x.id AND x.n>1;
-- Абсолютное время заступления уже определено расписанием; дата хранится явно
-- для уникальности независимо от часового пояса сеанса PostgreSQL.
ALTER TABLE duty.duties ADD COLUMN start_date date;
UPDATE duty.duties SET start_date=starts_at::date;
ALTER TABLE duty.duties ALTER COLUMN start_date SET NOT NULL;
CREATE FUNCTION duty.set_start_date() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN NEW.start_date=NEW.starts_at::date; RETURN NEW; END $$;
CREATE TRIGGER duties_start_date BEFORE INSERT OR UPDATE OF starts_at ON duty.duties
 FOR EACH ROW EXECUTE FUNCTION duty.set_start_date();
CREATE UNIQUE INDEX duties_one_per_day ON duty.duties(duty_type_id,start_date) WHERE status<>'cancelled';
-- Ранее утвержденные будущие составы требуют проверки новых требований.
UPDATE duty.duties SET status='draft',approved_at=NULL,approved_by=NULL,unapproved_at=now()
WHERE status='approved' AND start_date>CURRENT_DATE;
