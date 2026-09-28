-- За штатом — вне всех подразделений: человек без должности не числится ни
-- в одном подразделении и показывается только списком «За штатом» внизу
-- вкладки «Подразделения». Подразделение у сотрудника становится
-- необязательным; нынешние люди без должности — за штатом.

ALTER TABLE personnel.employees ALTER COLUMN unit_id DROP NOT NULL;

UPDATE personnel.employees e SET unit_id = NULL, updated_at = now()
WHERE e.is_active AND NOT EXISTS (SELECT 1 FROM core.positions p WHERE p.employee_id = e.id);
