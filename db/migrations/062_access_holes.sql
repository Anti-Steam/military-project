-- Закрытие дыр разграничения доступа (решение 155).
--
-- 1. Неверные попытки входа считаются по паре «учетная запись + адрес
--    компьютера»: трижды ошибиться с чужого компьютера — заблокировать вход
--    только с него, а не запереть человека (или администратора) целиком.
CREATE TABLE core.login_failures (
  user_id         int  NOT NULL REFERENCES core.users(id) ON DELETE CASCADE,
  ip              text NOT NULL,
  failed_attempts int  NOT NULL DEFAULT 0,
  locked_until    timestamptz,
  updated_at      timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, ip)
);

-- Прежние счетчики учетной записи больше не действуют.
UPDATE core.users SET failed_attempts = 0, locked_until = NULL
WHERE failed_attempts <> 0 OR locked_until IS NOT NULL;

-- 2. Командир без подразделения видел и вел бы всю часть. Такие записи
--    становятся «Пользователем»; впредь роль «Командир» — только с
--    подразделением.
UPDATE core.users SET role_code = 'user', updated_at = now()
WHERE role_code = 'commander' AND scope_unit_id IS NULL;
ALTER TABLE core.users
  ADD CONSTRAINT users_commander_has_unit CHECK (role_code <> 'commander' OR scope_unit_id IS NOT NULL);

-- 3. Исключенный со службы не входит: его учетные записи отключаются, сеансы
--    завершаются.
UPDATE core.users u SET is_active = false, updated_at = now()
FROM personnel.employees e
WHERE e.id = u.employee_id AND NOT e.is_active AND u.is_active
  AND u.role_code <> 'admin';   -- администратора не отключаем молча: без него некому исправить
DELETE FROM core.sessions s USING core.users u WHERE u.id = s.user_id AND NOT u.is_active;
