-- Фиксируем доступное состояние старых нарядов перед дальнейшей правкой
-- справочников. Это снимок на момент обновления, не восстановление утраченного аудита.
CREATE FUNCTION pg_temp.order_deadline(day date) RETURNS date LANGUAGE plpgsql AS $$
DECLARE cursor_day date=day-1; kind_day text;
BEGIN
 FOR i IN 1..740 LOOP
  SELECT kind INTO kind_day FROM core.calendar_days WHERE core.calendar_days.day=cursor_day;
  IF kind_day='workday' OR (kind_day IS DISTINCT FROM 'holiday' AND extract(isodow FROM cursor_day)<6) THEN RETURN cursor_day; END IF;
  cursor_day=cursor_day-1;
 END LOOP;
 RETURN NULL;
END $$;
UPDATE duty.duties d SET approved_snapshot=jsonb_build_object(
 'duty',jsonb_build_object('id',d.id,'starts_at',d.starts_at,'ends_at',d.ends_at,'status',d.status,
  'note',d.note,'duty_type_id',d.duty_type_id,'unit_id',d.unit_id,
  'duty_code',dt.code,'duty_name',dt.name,'unit_name',u.name,'unit_short',u.short_name),
 'roster',coalesce((SELECT jsonb_agg(jsonb_build_object(
   'post',jsonb_build_object('id',p.id,'name',p.name,'short_name',p.short_name),
   'employee',jsonb_build_object('id',e.id,'full_name',concat_ws(' ',e.last_name,e.first_name,e.middle_name),
      'rank_name',r.name,'unit_short',eu.short_name),
   'isOverride',a.is_override,'overrideReason',a.override_reason,'note',a.note,'broken',NULL,'weapons','[]'::jsonb
 ) ORDER BY p.sort_order,p.name)
 FROM duty.duty_assignments a JOIN duty.duty_posts p ON p.id=a.post_id
 JOIN personnel.employees e ON e.id=a.employee_id LEFT JOIN core.ranks r ON r.id=e.rank_id
 JOIN core.units eu ON eu.id=e.unit_id WHERE a.duty_id=d.id),'[]'::jsonb),
 'postCount',(SELECT count(*) FROM duty.duty_posts p WHERE p.duty_type_id=d.duty_type_id AND p.is_active),
 'brokenCount',0),order_deadline=pg_temp.order_deadline(d.start_date)
FROM duty.duty_types dt,core.units u WHERE dt.id=d.duty_type_id AND u.id=d.unit_id
AND d.start_date<=CURRENT_DATE AND d.approved_snapshot IS NULL;
-- Исторические утверждённые блоки сохраняются вместе. Неполные печатать нельзя.
WITH groups AS (
 SELECT duty_type_id,order_deadline,jsonb_agg(approved_snapshot ORDER BY starts_at) sections,
 sum(jsonb_array_length(approved_snapshot->'roster')) assigned,
 bool_and(jsonb_array_length(approved_snapshot->'roster')=(approved_snapshot->>'postCount')::int) complete
 FROM duty.duties WHERE status='approved' AND start_date<=CURRENT_DATE
 GROUP BY duty_type_id,order_deadline
)
UPDATE duty.duties d SET order_snapshot=jsonb_build_object(
 'dutyType',jsonb_build_object('code',dt.code,'name',dt.name),
 'unitName',u.name,'sections',g.sections,'orderDate',g.order_deadline,'totalAssigned',g.assigned,
 'historicalImport',true)
FROM groups g,duty.duty_types dt,core.units u
WHERE d.duty_type_id=g.duty_type_id AND d.order_deadline=g.order_deadline
 AND dt.id=d.duty_type_id AND u.id=d.unit_id AND d.status='approved'
 AND d.start_date<=CURRENT_DATE AND g.complete;
