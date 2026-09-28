-- Разбор приказов (МС-3): извлечение из приказа, кто допущен или убыл, —
-- по настраиваемым словарям, без образцов и без внешних сервисов.
--
-- Словарь (parse.phrases): какими словами в приказе обозначается то или иное.
--   order_permit / order_absence — заголовок относит приказ к виду;
--   permit  — вариант написания вида допуска (target = id вида допуска);
--   absence — вариант написания причины отсутствия (target = код причины);
--   mark_yes — отметка «допущен» в ячейке таблицы.
-- Названия видов допуска система узнает и сама (во всех падежах); словарь —
-- для сокращений и иных формулировок. Пополняется прямо при проверке
-- разбора («научить»).
--
-- Извлеченная структура документа (parse.documents) хранится, чтобы не
-- пересохранять файл при каждом открытии; разбор по ней повторяется с
-- текущим словарем.

CREATE SCHEMA IF NOT EXISTS parse;

CREATE TABLE parse.phrases (
  id         serial PRIMARY KEY,
  kind       text NOT NULL CHECK (kind IN ('order_permit', 'order_absence', 'permit', 'absence', 'mark_yes')),
  target     text,
  phrase     text NOT NULL CHECK (length(trim(phrase)) > 0),
  created_by int REFERENCES core.users(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (kind, target, phrase)
);

CREATE TABLE parse.documents (
  order_id     int PRIMARY KEY REFERENCES personnel.permit_orders(id) ON DELETE CASCADE,
  blocks       jsonb,
  error        text,
  extracted_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO parse.phrases (kind, target, phrase) VALUES
  ('order_permit', NULL, 'о допуске'),
  ('order_permit', NULL, 'допустить'),
  ('order_permit', NULL, 'допуск к'),
  ('order_absence', NULL, 'об убытии'),
  ('order_absence', NULL, 'убывшим'),
  ('order_absence', NULL, 'убывшими'),
  ('order_absence', NULL, 'полагать убывш'),
  ('order_absence', NULL, 'об отпуске'),
  ('order_absence', NULL, 'о командировании'),
  ('absence', 'VACATION', 'отпуск'),
  ('absence', 'TRIP', 'командировк'),
  ('absence', 'TRIP', 'учеб'),
  ('absence', 'TRIP', 'на сборы'),
  ('absence', 'SICK', 'больнич'),
  ('absence', 'SICK', 'госпитал'),
  ('absence', 'SICK', 'на лечени'),
  ('absence', 'DAY_OFF', 'отгул'),
  ('mark_yes', NULL, 'допущен'),
  ('mark_yes', NULL, 'допущена'),
  ('mark_yes', NULL, 'да'),
  ('mark_yes', NULL, '+'),
  ('mark_yes', NULL, 'v'),
  ('mark_yes', NULL, '✓')
ON CONFLICT DO NOTHING;

-- Журнал изменений — и на словарь.
CREATE TRIGGER audit_changes AFTER INSERT OR UPDATE OR DELETE ON parse.phrases
  FOR EACH ROW EXECUTE FUNCTION audit.log_change();
