-- Шаблон приказа — документ под контролем: каждое изменение хранится
-- отдельной версией с автором, временем и основанием. Текущий шаблон вида
-- (duty_types.order_template) — копия последней версии; утвержденный приказ
-- помнит номер версии, по которой составлен.

CREATE TABLE duty.order_template_versions (
  id           serial PRIMARY KEY,
  duty_type_id int NOT NULL REFERENCES duty.duty_types(id) ON DELETE CASCADE,
  version      int NOT NULL,
  template     jsonb,                 -- NULL — возврат к шаблону по умолчанию
  reason       text NOT NULL CHECK (length(trim(reason)) > 0),
  created_by   int REFERENCES core.users(id),
  created_at   timestamptz NOT NULL DEFAULT now(),
  UNIQUE (duty_type_id, version)
);
