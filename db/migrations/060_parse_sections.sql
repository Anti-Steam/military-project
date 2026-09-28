-- Разделы словаря разбора: стандартные (по одному на назначение) и свои —
-- с названием и назначением (например, «Сокращения ПВД» — иные написания
-- видов допуска). Слова раздела разбор учитывает по его назначению.

CREATE TABLE parse.sections (
  id         serial PRIMARY KEY,
  name       text NOT NULL CHECK (length(trim(name)) > 0),
  kind       text NOT NULL CHECK (kind IN ('order_permit', 'order_absence', 'permit', 'absence', 'mark_yes')),
  builtin    boolean NOT NULL DEFAULT false,
  sort_order int NOT NULL DEFAULT 0,
  created_by int REFERENCES core.users(id),
  created_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO parse.sections (name, kind, builtin, sort_order) VALUES
  ('Заголовок: приказ о допуске', 'order_permit', true, 10),
  ('Заголовок: приказ об отсутствии', 'order_absence', true, 20),
  ('Вид допуска — иное написание', 'permit', true, 30),
  ('Причина отсутствия — иное написание', 'absence', true, 40),
  ('Отметка «допущен» в таблице', 'mark_yes', true, 50);

ALTER TABLE parse.phrases ADD COLUMN section_id int REFERENCES parse.sections(id);
UPDATE parse.phrases p SET section_id = s.id FROM parse.sections s WHERE s.builtin AND s.kind = p.kind;
ALTER TABLE parse.phrases ALTER COLUMN section_id SET NOT NULL;

CREATE TRIGGER audit_changes AFTER INSERT OR UPDATE OR DELETE ON parse.sections
  FOR EACH ROW EXECUTE FUNCTION audit.log_change();
