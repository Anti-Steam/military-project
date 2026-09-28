-- 041. Закрепление личного состава за постом.
--
-- Допущенных к посту бывает вдвое больше, чем тех, кто на него реально
-- ходит: допуск говорит «этому можно», а ходят четверо, которых знают. До сих
-- пор система предлагала всех допущенных, и лишних приходилось обходить
-- глазами при каждом назначении.
--
-- Закрепление сужает круг: если у поста есть закрепленные люди, кандидатами
-- считаются ТОЛЬКО они. Пустой перечень означает прежнее поведение — все
-- допущенные из ответственного подразделения.
--
-- Это СУЖЕНИЕ, а не разрешение: допуск, отсутствие, отдых, занятость и оружие
-- проверяются по-прежнему. Закрепленный человек без допуска в наряд не
-- попадет — он просто не пройдет отбор, как и раньше.

BEGIN;

CREATE TABLE duty.post_employees (
    post_id     int NOT NULL REFERENCES duty.duty_posts(id)      ON DELETE CASCADE,
    employee_id int NOT NULL REFERENCES personnel.employees(id)  ON DELETE CASCADE,
    note        text,
    created_at  timestamptz NOT NULL DEFAULT now(),
    created_by  int REFERENCES core.users(id) ON DELETE SET NULL,

    PRIMARY KEY (post_id, employee_id)
);

COMMENT ON TABLE duty.post_employees IS
    'Кто ходит на пост. Непустой перечень сужает кандидатов до перечисленных';

CREATE INDEX idx_post_employees_employee ON duty.post_employees(employee_id);

COMMIT;
