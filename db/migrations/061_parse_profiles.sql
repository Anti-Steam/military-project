-- Свои виды приказов для разбора (например, «Приказ на караул»): как узнать
-- приказ (слова заголовка) и что делать с каждым найденным человеком —
-- отметить отсутствующим с выбранной причиной, занять указанное оружие на
-- срок, выдать допуск. Приказы таких видов — в реестре «прочие» (kind =
-- 'other') со ссылкой на вид.
--
-- Занятость оружия на срок (караул, стрельбы…) — personnel.weapon_reservations:
-- на эти даты оружие не выдается на наряд; видно во вкладке «Оружие».

CREATE TABLE parse.profiles (
  id              serial PRIMARY KEY,
  name            text NOT NULL CHECK (length(trim(name)) > 0),
  header_phrases  text[] NOT NULL DEFAULT '{}',   -- слова заголовка, по которым приказ узнается
  absence_code    text,                           -- отметить отсутствующим с этой причиной (NULL — нет)
  permit_type_id  int REFERENCES personnel.permit_types(id),  -- выдать допуск (NULL — нет)
  reserve_weapons boolean NOT NULL DEFAULT false, -- занять указанное оружие на срок
  default_days    int CHECK (default_days IS NULL OR default_days BETWEEN 1 AND 366),
  is_active       boolean NOT NULL DEFAULT true,
  sort_order      int NOT NULL DEFAULT 0,
  created_by      int REFERENCES core.users(id),
  created_at      timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE personnel.permit_orders DROP CONSTRAINT permit_orders_kind_check;
ALTER TABLE personnel.permit_orders ADD CONSTRAINT permit_orders_kind_check CHECK (kind IN ('permit', 'absence', 'other'));
ALTER TABLE personnel.permit_orders ADD COLUMN profile_id int REFERENCES parse.profiles(id);
ALTER TABLE personnel.permit_orders
  ADD CONSTRAINT permit_orders_profile_by_kind CHECK ((kind = 'other') = (profile_id IS NOT NULL));

CREATE TABLE personnel.weapon_reservations (
  id           serial PRIMARY KEY,
  weapon_id    int  NOT NULL REFERENCES personnel.weapons(id),
  employee_id  int  REFERENCES personnel.employees(id),
  date_from    date NOT NULL,
  date_to      date NOT NULL CHECK (date_to >= date_from),
  reason       text,
  order_id     int REFERENCES personnel.permit_orders(id) ON DELETE SET NULL,
  created_by   int REFERENCES core.users(id),
  created_at   timestamptz NOT NULL DEFAULT now(),
  cancelled_at timestamptz
);
CREATE INDEX ON personnel.weapon_reservations (weapon_id, date_from, date_to) WHERE cancelled_at IS NULL;

-- Свои разделы словаря не нужны: новые виды приказов — профилями.
UPDATE parse.phrases p SET section_id = b.id
FROM parse.sections s, parse.sections b
WHERE p.section_id = s.id AND NOT s.builtin AND b.builtin AND b.kind = s.kind;
DELETE FROM parse.sections WHERE NOT builtin;

CREATE TRIGGER audit_changes AFTER INSERT OR UPDATE OR DELETE ON parse.profiles
  FOR EACH ROW EXECUTE FUNCTION audit.log_change();
CREATE TRIGGER audit_changes AFTER INSERT OR UPDATE OR DELETE ON personnel.weapon_reservations
  FOR EACH ROW EXECUTE FUNCTION audit.log_change();
