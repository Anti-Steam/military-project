-- Исключение из списков части: человек не удаляется (история нарядов,
-- допусков и оружия ссылается на него), а становится недействующим с датой
-- и причиной. Возврат — снова действующий, за штатом.

ALTER TABLE personnel.employees
  ADD COLUMN excluded_on date,
  ADD COLUMN exclusion_reason text;
