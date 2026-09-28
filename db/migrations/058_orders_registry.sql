-- Вкладка «Приказы»: единое хранилище приказов по назначению. Реестр приказов
-- на допуск становится общим — у приказа вид: допуск или отсутствие.
-- Направления (каталог) — только у приказов на допуск. Отметка отсутствия
-- может ссылаться на приказ реестра. Приказы на наряды хранятся в самих
-- нарядах (сохраняемая форма приказа при утверждении) — их вкладка
-- собирается из них.

ALTER TABLE personnel.permit_orders
  ADD COLUMN kind text NOT NULL DEFAULT 'permit' CHECK (kind IN ('permit', 'absence'));
ALTER TABLE personnel.permit_orders ALTER COLUMN direction_id DROP NOT NULL;
ALTER TABLE personnel.permit_orders
  ADD CONSTRAINT permit_orders_direction_by_kind CHECK ((kind = 'permit') = (direction_id IS NOT NULL));

ALTER TABLE personnel.absences
  ADD COLUMN order_id int REFERENCES personnel.permit_orders(id) ON DELETE SET NULL;
CREATE INDEX ON personnel.absences (order_id) WHERE order_id IS NOT NULL;
