-- 027. Вход в систему и разграничение прав.
--
-- Модель принята гибридная: РОЛЬ задает набор прав по умолчанию, а отдельное
-- право можно выдать сверх роли либо отнять у конкретного человека. Чистые
-- роли заставляют заводить новую роль ради одного исключения, а чистый набор
-- прав на каждого превращает выдачу доступа в ручную работу.
--
-- Право названо по ДЕЙСТВИЮ, а не по роли: роль сотрудника меняется, смысл
-- действия — нет. Перечень прав уже был описан в коде (modules/access), здесь
-- он переносится в справочник, чтобы администратор мог раздавать права, не
-- трогая исходный текст.

CREATE TABLE core.permissions (
    code        text PRIMARY KEY,
    name        text NOT NULL,
    section     text NOT NULL,
    sort_order  int  NOT NULL DEFAULT 0
);

CREATE TABLE core.roles (
    code      text PRIMARY KEY,
    name      text NOT NULL,
    -- Уровень в иерархии раздела 6.1: 1 — администратор, 5 — пользователь.
    -- Нужен для будущего делегирования: передать права выше своего уровня
    -- нельзя.
    level     int  NOT NULL,
    is_system boolean NOT NULL DEFAULT true
);

CREATE TABLE core.role_permissions (
    role_code       text NOT NULL REFERENCES core.roles(code) ON DELETE CASCADE,
    permission_code text NOT NULL REFERENCES core.permissions(code) ON DELETE CASCADE,
    PRIMARY KEY (role_code, permission_code)
);

-- Точечные права поверх роли. granted = false — ЗАПРЕТ, он сильнее роли:
-- отнять право у одного человека нужно уметь так же, как и выдать.
CREATE TABLE core.user_permissions (
    user_id         int  NOT NULL REFERENCES core.users(id) ON DELETE CASCADE,
    permission_code text NOT NULL REFERENCES core.permissions(code) ON DELETE CASCADE,
    granted         boolean NOT NULL,
    note            text,
    granted_by      int REFERENCES core.users(id) ON DELETE SET NULL,
    granted_at      timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, permission_code)
);

-- Сессии хранятся на сервере: в браузер уходит только случайный
-- идентификатор, по нему ничего нельзя ни прочитать, ни подделать, а
-- завершить чужую сессию можно немедленно (OWASP Session Management).
CREATE TABLE core.sessions (
    id           text PRIMARY KEY,
    user_id      int  NOT NULL REFERENCES core.users(id) ON DELETE CASCADE,
    csrf_token   text NOT NULL,
    created_at   timestamptz NOT NULL DEFAULT now(),
    last_seen_at timestamptz NOT NULL DEFAULT now(),
    expires_at   timestamptz NOT NULL,
    ip           text,
    user_agent   text
);
CREATE INDEX idx_sessions_user    ON core.sessions(user_id);
CREATE INDEX idx_sessions_expires ON core.sessions(expires_at);

-- События безопасности: входы, отказы, блокировки, изменения прав. Это
-- начало сквозного аудита (МС-4) и единственная запись, по которой потом
-- можно разобрать, кто и когда получил доступ.
CREATE TABLE core.security_events (
    id       bigserial PRIMARY KEY,
    at       timestamptz NOT NULL DEFAULT now(),
    kind     text NOT NULL,
    user_id  int REFERENCES core.users(id) ON DELETE SET NULL,
    actor_id int REFERENCES core.users(id) ON DELETE SET NULL,
    login    text,
    detail   text,
    ip       text
);
CREATE INDEX idx_security_events_at ON core.security_events(at DESC);

ALTER TABLE core.users
    ADD COLUMN must_change_password boolean NOT NULL DEFAULT false,
    ADD COLUMN password_changed_at  timestamptz,
    ADD COLUMN last_login_at        timestamptz,
    ADD COLUMN created_by           int REFERENCES core.users(id) ON DELETE SET NULL;

INSERT INTO core.roles (code, name, level) VALUES
    ('admin',     'Администратор системы',  1),
    ('deputy',    'Заместитель',            2),
    ('chief',     'Начальник службы',       3),
    ('commander', 'Командир подразделения', 4),
    ('user',      'Пользователь',           5);

-- Прежний перечень ролей был записан условием прямо в таблице и уже разошелся
-- с кодом: в нем значилось 'service', а модуль access всегда проверял 'chief'.
-- Перечень переезжает в справочник, а условие заменяется ссылкой на него —
-- разойтись ссылке не с чем.
ALTER TABLE core.users
    DROP CONSTRAINT users_role_known,
    ADD CONSTRAINT users_role_known FOREIGN KEY (role_code) REFERENCES core.roles(code);

INSERT INTO core.permissions (code, name, section, sort_order) VALUES
    ('duty.view',       'Просмотр графика и нарядов',            'Наряды',        10),
    ('duty.create',     'Назначение и правка состава',           'Наряды',        20),
    ('duty.approve',    'Утверждение приказа',                   'Наряды',        30),
    ('duty.withdraw',   'Снятие человека с наряда',              'Наряды',        40),
    ('duty.override',   'Назначение вопреки правилам отбора',    'Наряды',        50),
    ('post.manage',     'Справочник постов',                     'Справочники',   60),
    ('calendar.manage', 'Празднично-выходные дни',               'Справочники',   70),
    ('personnel.view',  'Просмотр личного состава',              'Личный состав', 80),
    ('weapon.view',     'Просмотр учета оружия',                 'Оружие',        90),
    ('weapon.transfer', 'Передача оружия на период наряда',      'Оружие',       100),
    ('user.manage',     'Учетные записи и права доступа',        'Управление',   110);

-- Права ролей по разделу 6.1. Администратору — все.
INSERT INTO core.role_permissions (role_code, permission_code)
SELECT 'admin', code FROM core.permissions;

INSERT INTO core.role_permissions (role_code, permission_code) VALUES
    ('deputy', 'duty.view'), ('deputy', 'duty.create'), ('deputy', 'duty.approve'),
    ('deputy', 'duty.withdraw'), ('deputy', 'post.manage'), ('deputy', 'calendar.manage'),
    ('deputy', 'personnel.view'), ('deputy', 'weapon.view'),

    ('chief', 'duty.view'), ('chief', 'duty.create'), ('chief', 'duty.approve'),
    ('chief', 'duty.withdraw'), ('chief', 'personnel.view'), ('chief', 'weapon.view'),

    ('commander', 'duty.view'), ('commander', 'duty.create'),
    ('commander', 'personnel.view'), ('commander', 'weapon.view'),

    ('user', 'duty.view');

-- Прежний признак передачи оружия становится обычным точечным правом:
-- два источника правды об одном и том же расходятся при первой же правке.
INSERT INTO core.user_permissions (user_id, permission_code, granted, note)
SELECT u.id, 'weapon.transfer', true, 'перенесено из признака can_transfer_weapons'
FROM core.users u
WHERE u.can_transfer_weapons AND u.role_code <> 'admin';

ALTER TABLE core.users DROP COLUMN can_transfer_weapons;

-- Учетная запись стенда: пароль подлежит смене при первом входе.
-- Значение задается запускателем, здесь только требование смены.
UPDATE core.users SET must_change_password = true WHERE login = 'admin';
