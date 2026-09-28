-- 043. Реестр приказов на допуск: направления и приложенные файлы.
--
-- Приказы как записи (номер, дата, название) и ссылка на них у допуска есть с
-- миграции 007 — 1108 допусков уже заведены со ссылкой на приказ. Не хватало
-- двух вещей: КАТАЛОГА, в котором приказы ищут, и САМОГО ПРИКАЗА — файла,
-- который можно открыть.
--
-- Отсюда же растет будущая автоматизация (МС-3): разбор загруженного приказа
-- должен будет завести допуски всем перечисленным в нем людям. Поле source
-- и parsed_at заводятся сейчас, по тому же правилу, что у отсутствий
-- (раздел 9.2.1): разбор не должен молча затирать внесенное человеком.

BEGIN;

-- ---------------------------------------------------------------------------
-- Направления допуска
--
-- Дерево, как оргструктура: направление делится настолько подробно, насколько
-- в части принято. ГОДЫ В ДЕРЕВЕ НЕ ЗАВОДЯТСЯ — они выводятся из даты
-- издания: год, заведенный руками, рано или поздно разойдется с датой в
-- самом приказе.
-- ---------------------------------------------------------------------------
CREATE TABLE personnel.permit_directions (
    id         serial PRIMARY KEY,
    parent_id  int REFERENCES personnel.permit_directions(id) ON DELETE RESTRICT,
    name       text NOT NULL,
    sort_order int  NOT NULL DEFAULT 0,
    is_active  boolean NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT permit_directions_name_not_empty CHECK (btrim(name) <> '')
);

COMMENT ON TABLE personnel.permit_directions IS
    'Направления допуска: дерево каталогов, в которых лежат приказы';

CREATE INDEX idx_permit_directions_parent ON personnel.permit_directions(parent_id);

INSERT INTO personnel.permit_directions (name, sort_order) VALUES
    ('Суточный наряд', 10),
    ('Оперативное дежурство', 20),
    ('Охрана и оборона', 30),
    ('Медицинские и психологические допуски', 40),
    ('Прочие приказы', 90);

-- ---------------------------------------------------------------------------
-- Файл приказа
--
-- Хранится на диске, в БД — путь: многомегабайтные сканы в строках раздули бы
-- каждое резервное копирование базы. PDF лежит рядом с оригиналом — приказ
-- приходит и в DOC, и сканом, а читать его должны одинаково. Оригинал не
-- выбрасывается: он и есть присланный документ.
-- ---------------------------------------------------------------------------
ALTER TABLE personnel.permit_orders
    ADD COLUMN direction_id int REFERENCES personnel.permit_directions(id) ON DELETE RESTRICT,
    ADD COLUMN file_name    text,
    ADD COLUMN file_path    text,
    ADD COLUMN file_mime    text,
    ADD COLUMN file_size    int,
    ADD COLUMN pdf_path     text,
    ADD COLUMN pdf_error    text,
    ADD COLUMN source       text NOT NULL DEFAULT 'manual',
    ADD COLUMN parsed_at    timestamptz,
    ADD COLUMN created_by   int REFERENCES core.users(id) ON DELETE SET NULL,
    ADD CONSTRAINT permit_orders_source_known CHECK (source IN ('manual', 'import'));

COMMENT ON COLUMN personnel.permit_orders.pdf_path IS
    'Приказ для чтения: PDF. Для DOC/DOCX получен пересохранением, для PDF — он сам';
COMMENT ON COLUMN personnel.permit_orders.pdf_error IS
    'Почему PDF не построен: показывается вместо приказа, чтобы отказ не выглядел пустой страницей';

CREATE INDEX idx_permit_orders_direction ON personnel.permit_orders(direction_id, issued_on DESC);

-- Приказы стенда раскладываются по направлениям, чтобы каталог не открывался
-- пустым. Разбор по названию: других сведений о них нет.
UPDATE personnel.permit_orders o
   SET direction_id = d.id
  FROM personnel.permit_directions d
 WHERE d.name = CASE
        WHEN o.title ILIKE '%УМО%' OR o.title ILIKE '%МПФО%' THEN 'Медицинские и психологические допуски'
        WHEN o.title ILIKE '%дежурной смене%' OR o.title ILIKE '%ДСОО%' THEN 'Охрана и оборона'
        WHEN o.title ILIKE '%оперативн%' THEN 'Оперативное дежурство'
        WHEN o.title ILIKE '%наряд%' THEN 'Суточный наряд'
        ELSE 'Прочие приказы'
       END;

UPDATE personnel.permit_orders
   SET direction_id = (SELECT id FROM personnel.permit_directions WHERE name = 'Прочие приказы')
 WHERE direction_id IS NULL;

ALTER TABLE personnel.permit_orders ALTER COLUMN direction_id SET NOT NULL;

-- ---------------------------------------------------------------------------
-- Право вести приказы и допуски личного состава
-- ---------------------------------------------------------------------------
INSERT INTO core.permissions (code, name, section, sort_order) VALUES
    ('permit.manage', 'Приказы на допуск и допуски личного состава', 'Личный состав', 86);

INSERT INTO core.role_permissions (role_code, permission_code) VALUES
    ('admin', 'permit.manage'), ('deputy', 'permit.manage'), ('chief', 'permit.manage');

COMMIT;
