-- 030. Веса личного состава: очередь заступления.
--
-- До сих пор кандидаты упорядочивались по НАГРУЗКЕ — сколько человек уже
-- отстоял за тридцать суток. Этого мало: нагрузка отвечает на вопрос «кого
-- жалко», но не отвечает на вопросы «чья очередь» и «кто сюда годится лучше».
--
-- Вводится ОЧЕРЕДЬ — единый показатель, по которому кандидаты сортируются и
-- по которому система подбирает состав сама:
--
--     очередь = готовность − нагрузка × коэффициент
--             + вес звания на посту + личная поправка к посту
--
--   • ГОТОВНОСТЬ растет каждые сутки простоя до потолка и падает до нуля
--     после заступления. Потолок нужен: без него вернувшийся из отпуска
--     месяцами вытеснял бы всех остальных.
--   • НАГРУЗКА за тридцать суток уже считается и остается как есть.
--   • ВЕС ЗВАНИЯ — массовое правило поста: сержант на «дежурного по роте»
--     предпочтительнее рядового.
--   • ЛИЧНАЯ ПОПРАВКА — исключение для одного человека на одном посту.
--
-- Жесткие правила — допуск, отсутствие, отсыпной, занятость, оружие — весами
-- НЕ выражаются. Это запреты, а не предпочтения, и подбор не должен уметь их
-- обойти: иначе однажды система «взвесит» и поставит человека без допуска.

-- Настройки подбора. Хранятся в БД, а не в коде: коэффициенты подбираются
-- опытом, и менять их правкой исходного текста пришлось бы каждую неделю.
CREATE TABLE core.settings (
    key         text PRIMARY KEY,
    value       numeric NOT NULL,
    name        text NOT NULL,
    description text,
    updated_by  int REFERENCES core.users(id) ON DELETE SET NULL,
    updated_at  timestamptz NOT NULL DEFAULT now()
);

INSERT INTO core.settings (key, value, name, description) VALUES
    ('queue.ready_max_days', 30, 'Потолок готовности, суток',
     'Дольше этого срока простоя очередь не растет. Иначе вернувшийся из отпуска месяцами вытесняет остальных'),
    ('queue.workload_factor', 1.0, 'Вес накопленной нагрузки',
     'На сколько каждая единица нагрузки за 30 суток понижает очередь'),
    ('queue.threshold', 1, 'Порог предложения',
     'Кандидат с очередью ниже порога не предлагается вовсе. Сразу после смены человек ниже порога'),
    ('queue.unassigned_bonus', 0, 'Надбавка ни разу не заступавшим',
     'Прибавляется тем, у кого за расчетный период нет ни одного наряда');

-- Вес звания на посту: массовое правило.
CREATE TABLE duty.post_rank_weights (
    post_id int NOT NULL REFERENCES duty.duty_posts(id) ON DELETE CASCADE,
    rank_id int NOT NULL REFERENCES core.ranks(id) ON DELETE CASCADE,
    weight  numeric NOT NULL,
    PRIMARY KEY (post_id, rank_id)
);

-- Личная поправка к посту: исключение для одного человека.
CREATE TABLE personnel.employee_post_weights (
    employee_id int NOT NULL REFERENCES personnel.employees(id) ON DELETE CASCADE,
    post_id     int NOT NULL REFERENCES duty.duty_posts(id) ON DELETE CASCADE,
    weight      numeric NOT NULL,
    note        text,
    updated_by  int REFERENCES core.users(id) ON DELETE SET NULL,
    updated_at  timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (employee_id, post_id)
);

INSERT INTO core.permissions (code, name, section, sort_order) VALUES
    ('queue.manage', 'Настройка весов и подбора', 'Управление', 115);

INSERT INTO core.role_permissions (role_code, permission_code) VALUES
    ('admin', 'queue.manage'), ('deputy', 'queue.manage');

-- ---------------------------------------------------------------------------
-- Начальное наполнение: старшие посты предпочтительны сержантскому составу,
-- рядовые — дневальным. Значения синтетические и подлежат уточнению опытом.
-- ---------------------------------------------------------------------------

-- Дежурный по роте, по КПП, по парку — сержантский состав.
INSERT INTO duty.post_rank_weights (post_id, rank_id, weight)
SELECT p.id, r.id,
       CASE
           WHEN r.seniority BETWEEN 30 AND 60 THEN  5   -- сержанты и старшина
           WHEN r.seniority BETWEEN 10 AND 20 THEN -5   -- рядовой, ефрейтор
           ELSE 0
       END
FROM duty.duty_posts p
CROSS JOIN core.ranks r
WHERE p.name LIKE 'Дежурный по %'
  AND r.seniority <= 60;

-- Дневальный — наоборот, рядовой состав.
INSERT INTO duty.post_rank_weights (post_id, rank_id, weight)
SELECT p.id, r.id,
       CASE
           WHEN r.seniority BETWEEN 10 AND 20 THEN  5
           WHEN r.seniority BETWEEN 30 AND 60 THEN -3
           ELSE 0
       END
FROM duty.duty_posts p
CROSS JOIN core.ranks r
WHERE p.name LIKE 'Дневальный по %'
  AND r.seniority <= 60;
