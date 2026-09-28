'use strict';

// Сохранение порядка списка после перетаскивания — общий обработчик для всех
// списков с ручным порядком (виды нарядов, посты, подразделения,
// направления допусков). Страница шлет полный перечень ids без
// перезагрузки и ждет короткий ответ: { ok } или { ok: false, message }.
//
// Парная часть на странице — public/js/sortable.js и partials/drag-handle.

/**
 * @param access     модуль доступа (передается, чтобы lib не зависел от модулей)
 * @param permission право, при котором список можно переставлять
 * @param apply      (req, ids) => Promise — проверка и запись порядка сервисом
 */
function orderHandler(access, permission, apply) {
  return async (req, res, next) => {
    try {
      if (!access.require(req, res, permission)) return;
      await apply(req, req.body.ids);
      res.json({ ok: true });
    } catch (err) {
      if (err.userMessage) {
        return res.status(err.status || 400).json({ ok: false, message: err.message });
      }
      next(err);
    }
  };
}

module.exports = { orderHandler };
