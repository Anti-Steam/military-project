-- ============================================================================
-- 013. Расширение синтетического личного состава до штата стенда.
--
-- Целевая численность по званиям: рядовой и ефрейтор — по 20, остальные
-- звания от младшего сержанта до полковника — по 10. Итого 170 человек.
-- Миграция ДОБАВЛЯЕТ недостающих к уже заведенным, а не заменяет их:
-- существующие сотрудники связаны с созданными нарядами.
--
-- ДАННЫЕ СИНТЕТИЧЕСКИЕ. Фамилии, имена и отчества собираются из наборов
-- распространенных вариантов. Реальные сведения о личном составе на стенд
-- не переносятся (раздел 2 ТЗ).
-- ============================================================================


-- Сколько человек каждого звания требуется добавить
CREATE TEMP TABLE target_counts ON COMMIT DROP AS
SELECT r.id AS rank_id,
       r.seniority,
       CASE WHEN r.seniority <= 20 THEN 20 ELSE 10 END AS target,
       count(e.id)::int AS present
FROM core.ranks r
LEFT JOIN personnel.employees e ON e.rank_id = r.id
GROUP BY r.id, r.seniority;


-- Наборы для сборки ФИО
CREATE TEMP TABLE name_parts ON COMMIT DROP AS
SELECT
    ARRAY['Абрамов','Беляев','Верещагин','Гурьев','Дементьев','Ершов',
          'Жуков','Зотов','Игнатов','Кузьмин','Лазарев','Мельников',
          'Нестеров','Овчинников','Панкратов','Родионов','Савельев',
          'Тимофеев','Ульянов','Фадеев','Харитонов','Цветков','Чернышов',
          'Шестаков','Щербаков','Юдин','Яковлев','Аникин','Бобров',
          'Воронин','Гуляев','Дроздов','Емельянов','Зуев','Киселёв'] AS surnames,
    ARRAY['Александр','Борис','Виктор','Геннадий','Дмитрий','Евгений',
          'Игорь','Кирилл','Леонид','Максим','Николай','Олег','Павел',
          'Роман','Сергей','Тимур','Фёдор','Юрий'] AS firsts,
    ARRAY['Александрович','Борисович','Викторович','Геннадьевич',
          'Дмитриевич','Евгеньевич','Игоревич','Кириллович','Леонидович',
          'Максимович','Николаевич','Олегович','Павлович','Романович',
          'Сергеевич','Тимурович','Фёдорович','Юрьевич'] AS middles;


-- Добавляемые сотрудники.
--
-- Подразделение назначается по званию: солдаты и сержанты — в роты,
-- прапорщики — в службы, офицеры — в управление части и службы. Это
-- определяет, к каким постам их вообще можно допустить: посты роты
-- замещаются своими.
WITH gaps AS (
    SELECT rank_id, seniority, generate_series(1, target - present) AS n
    FROM target_counts
    WHERE target > present
),
numbered AS (
    SELECT g.*, row_number() OVER (ORDER BY g.seniority, g.n) AS i
    FROM gaps g
)
INSERT INTO personnel.employees
    (last_name, first_name, middle_name, rank_id, position, unit_id, personnel_number, is_active)
SELECT
    np.surnames[1 + (n.i * 7)  % array_length(np.surnames, 1)],
    np.firsts  [1 + (n.i * 5)  % array_length(np.firsts,   1)],
    np.middles [1 + (n.i * 11) % array_length(np.middles,  1)],
    n.rank_id,
    CASE
        WHEN n.seniority >= 140 THEN 'заместитель командира части'
        WHEN n.seniority >= 120 THEN 'начальник службы'
        WHEN n.seniority >=  90 THEN 'командир взвода'
        WHEN n.seniority >=  70 THEN 'техник'
        WHEN n.seniority >=  30 THEN 'командир отделения'
        ELSE 'стрелок'
    END,
    CASE
        WHEN n.seniority >= 140 THEN 1                                  -- управление части
        WHEN n.seniority >= 120 THEN (ARRAY[1, 4, 5])[1 + n.i % 3]      -- управление, УС, ТС
        WHEN n.seniority >=  70 THEN (ARRAY[4, 5])[1 + n.i % 2]         -- УС, ТС
        ELSE (ARRAY[2, 3])[1 + n.i % 2]                                 -- роты
    END,
    'С-' || lpad((1000 + n.i)::text, 5, '0'),
    true
FROM numbered n, name_parts np;


-- ----------------------------------------------------------------------------
-- Общие допуски: медицинский (УМО/ВВК) и психологический (МПФО).
--
-- Сроки намеренно разные, часть допусков просрочена или истекает в ближайшее
-- время: без этого не проверить ни фильтрацию по действующим допускам, ни
-- будущие напоминания. Признак истечения нигде не хранится и вычисляется от
-- текущей даты (решение 13.1), поэтому достаточно расставить даты окончания.
-- ----------------------------------------------------------------------------

WITH ord AS (
    INSERT INTO personnel.permit_orders (number, issued_on, title)
    VALUES ('61', DATE '2026-02-10', 'О допуске личного состава по результатам УМО и МПФО')
    RETURNING id
),
targets AS (
    SELECT e.id AS employee_id,
           pt.id AS permit_type_id,
           row_number() OVER (ORDER BY e.id, pt.id) AS i
    FROM personnel.employees e
    CROSS JOIN personnel.permit_types pt
    WHERE e.is_active
      AND pt.code IN ('MED', 'PSY')
      AND NOT EXISTS (
          SELECT 1 FROM personnel.employee_permits ep
          WHERE ep.employee_id = e.id AND ep.permit_type_id = pt.id
      )
)
INSERT INTO personnel.employee_permits
    (employee_id, permit_type_id, issued_at, expires_at, status, document_ref)
SELECT t.employee_id,
       t.permit_type_id,
       DATE '2026-02-10',
       CASE t.i % 10
           WHEN 0 THEN DATE '2026-08-01'   -- просрочен
           WHEN 1 THEN DATE '2026-09-20'   -- истекает в ближайшие недели
           WHEN 2 THEN DATE '2026-10-15'
           ELSE DATE '2027-02-10'
       END,
       CASE WHEN t.i % 37 = 0 THEN 'suspended' ELSE 'active' END,
       'приказ № 61 от 10.02.2026'
FROM targets t;


-- ----------------------------------------------------------------------------
-- Постовые допуски.
--
-- Допуск выдается по соответствию поста и звания: пост дежурного по части
-- замещается офицерами и прапорщиками, пост дневального — солдатами. Без
-- такого соответствия синтетика допускает полковника дневальным, и проверить
-- на ней осмысленность подбора нельзя.
-- ----------------------------------------------------------------------------

WITH ord AS (
    INSERT INTO personnel.permit_orders (number, issued_on, title)
    VALUES ('62', DATE '2026-03-05', 'О допуске к постам суточного наряда, ОД и ДСОО')
    RETURNING id
),
-- Диапазон званий, замещающих пост
post_ranks AS (
    SELECT p.id AS post_id,
           p.unit_id,
           dt.code AS duty_code,
           CASE
               -- Старшие посты: оперативный дежурный, ДЧ, КДС и заместители
               WHEN p.sort_order <= 20 AND dt.code IN ('OD', 'OO') THEN 90
               WHEN p.name LIKE 'Дежурный по части%'      THEN 70
               WHEN p.name LIKE 'Помощник дежурного по части%' THEN 70
               WHEN p.name LIKE 'Начальник ПНР%'          THEN 70
               WHEN p.name LIKE 'Дежурный по %роте%'      THEN 30
               WHEN p.name LIKE 'Дневальный%'             THEN 10
               ELSE 20
           END AS min_seniority,
           CASE
               WHEN p.name LIKE 'Дневальный%'        THEN 20
               WHEN p.name LIKE 'Дежурный по %роте%' THEN 60
               ELSE 150
           END AS max_seniority
    FROM duty.duty_posts p
    JOIN duty.duty_types dt ON dt.id = p.duty_type_id
    WHERE p.is_active
),
candidates AS (
    SELECT pr.post_id,
           pr.duty_code,
           e.id AS employee_id,
           row_number() OVER (PARTITION BY pr.post_id ORDER BY e.id) AS rn
    FROM post_ranks pr
    JOIN personnel.employees e ON e.is_active
    JOIN core.ranks r ON r.id = e.rank_id
    WHERE r.seniority BETWEEN pr.min_seniority AND pr.max_seniority
      -- Пост подразделения замещается только своими
      AND (pr.unit_id IS NULL OR e.unit_id = pr.unit_id)
      AND NOT EXISTS (
          SELECT 1 FROM personnel.employee_permits ep
          WHERE ep.employee_id = e.id AND ep.post_id = pr.post_id
      )
)
INSERT INTO personnel.employee_permits
    (employee_id, permit_type_id, post_id, order_id, issued_at, expires_at, status, document_ref)
SELECT c.employee_id,
       (SELECT id FROM personnel.permit_types
         WHERE code = CASE WHEN c.duty_code = 'OO' THEN 'OO' ELSE 'SN' END),
       c.post_id,
       (SELECT id FROM ord),
       DATE '2026-03-05',
       CASE c.rn % 8
           WHEN 0 THEN DATE '2026-08-25'   -- просрочен
           WHEN 1 THEN DATE '2026-10-01'
           ELSE DATE '2027-03-05'
       END,
       'active',
       'приказ № 62 от 05.03.2026'
FROM candidates c
WHERE c.rn <= 12;
