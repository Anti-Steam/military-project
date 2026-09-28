-- ============================================================================
-- 020. Действие допуска НА ДАТУ.
--
-- Представление v_valid_permits привязано к CURRENT_DATE и отвечает на вопрос
-- «действует ли допуск сегодня». Подбор кандидатов опирался на него, а наряды
-- назначаются на месяц вперед — и человек, у которого допуск истекает через
-- неделю, предлагался кандидатом на конец месяца. Ошибка обнаружилась бы в
-- день заступления, когда заменять уже некем.
--
-- Условие действия вынесено в функцию с параметром даты. Представление
-- переопределяется через нее же, поэтому определение действующего допуска
-- остается ОДНО (раздел 7.1), а «сегодня» становится его частным случаем.
-- ============================================================================

CREATE FUNCTION personnel.permit_is_valid(p personnel.employee_permits, on_date date)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT p.status = 'active'
       AND p.issued_at <= on_date
       AND (p.expires_at IS NULL OR p.expires_at >= on_date)
       AND NOT (
           p.suspended_from IS NOT NULL
           AND p.suspended_from <= on_date
           AND (p.suspended_to IS NULL OR p.suspended_to >= on_date)
       )
$$;

COMMENT ON FUNCTION personnel.permit_is_valid(personnel.employee_permits, date) IS
    'Единственное определение действующего допуска. Дата — параметр: наряды '
    'назначаются вперед, и проверять допуск нужно на день заступления, а не '
    'на сегодня.';


-- Представление сохраняется для случаев «на сегодня»: справочники, карточки,
-- сводки. Теперь оно частный случай функции.
DROP VIEW personnel.v_valid_permits;

CREATE VIEW personnel.v_valid_permits AS
SELECT p.id,
       p.employee_id,
       p.permit_type_id,
       p.post_id,
       p.issued_at,
       p.expires_at
FROM personnel.employee_permits p
WHERE personnel.permit_is_valid(p, CURRENT_DATE);

COMMENT ON VIEW personnel.v_valid_permits IS
    'Допуски, действующие СЕГОДНЯ. Для проверки на дату заступления '
    'используется personnel.permit_is_valid(p, дата).';
