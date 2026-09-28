'use strict';

// Перетаскивание в списках с ручным порядком — одно на все страницы.
//
// Разметка (собирается partials/drag-handle и атрибутами):
//   <… data-sortable="/адрес/сохранения" data-csrf="…">   — список
//   (data-sortable="" — порядок сохраняется вместе с формой, без запроса;
//    data-sort-whole — ручка весь элемент, без «⠿»)
//     <… data-sort-id="12"> … <span class="drag-handle" draggable="true">⠿</span> … </…>
//
// Элемент тянется за ручку и только среди соседей по своему списку: во
// вложенных списках (дерево подразделений) родитель и дети переставляются
// каждый у себя. После броска полный перечень уходит на сервер; при отказе
// страница перезагружается и показывает сохраненный порядок.

(function () {
  let dragged = null;
  let before = null;

  // Прямой элемент списка, внутри которого событие, — вложенные списки не в счет.
  const itemOf = (list, node) => {
    while (node && node.parentNode !== list) node = node.parentNode;
    return node && node.dataset && node.dataset.sortId ? node : null;
  };
  const ids = (list) => [...list.children].filter((x) => x.dataset.sortId)
    .map((x) => x.dataset.sortId);

  // Ручка в заголовке раскрывающегося блока не должна его сворачивать.
  document.addEventListener('click', (event) => {
    if (event.target.closest('.drag-handle')) event.preventDefault();
  });

  document.querySelectorAll('[data-sortable]').forEach((list) => {
    list.addEventListener('dragstart', (event) => {
      // data-sort-whole у списка — ручка весь элемент (вкладки графика: тянут
      // за само название, щелчок по-прежнему открывает).
      const whole = list.dataset.sortWhole !== undefined;
      if (dragged || !event.target.closest || (!whole && !event.target.closest('.drag-handle'))) return;
      // Ручка со своим перетаскиванием (человек в штате) — не перестановка списка.
      if (event.target.closest('[data-own-drag]')) return;
      const item = itemOf(list, event.target);
      if (!item) return;
      event.stopPropagation();
      dragged = item;
      before = ids(list).join(',');
      item.classList.add('dragging');
      event.dataTransfer.effectAllowed = 'move';
      event.dataTransfer.setData('text/plain', item.dataset.sortId);
      event.dataTransfer.setDragImage(item, 20, 10);
    });

    list.addEventListener('dragover', (event) => {
      if (!dragged || dragged.parentNode !== list) return;
      const over = itemOf(list, event.target);
      if (!over) return;
      event.preventDefault();
      event.stopPropagation();
      if (over === dragged) return;

      const box = over.getBoundingClientRect();
      const after = event.clientY > box.top + box.height / 2;
      list.insertBefore(dragged, after ? over.nextSibling : over);
    });

    list.addEventListener('drop', (event) => {
      if (dragged && dragged.parentNode === list) event.preventDefault();
    });

    list.addEventListener('dragend', async (event) => {
      if (!dragged || dragged.parentNode !== list) return;
      event.stopPropagation();
      dragged.classList.remove('dragging');
      dragged = null;

      const order = ids(list);
      if (order.join(',') === before) return;
      // Список без адреса (data-sortable="") — часть формы: порядок уйдет
      // вместе с ней по кнопке «Сохранить», отдельно ничего не шлется.
      if (!list.dataset.sortable) return;

      const form = new URLSearchParams();
      form.append('_csrf', list.dataset.csrf);
      order.forEach((id) => form.append('ids', id));

      try {
        const response = await fetch(list.dataset.sortable, {
          method: 'POST', body: form, credentials: 'same-origin',
        });
        const answer = await response.json().catch(() => ({}));
        if (!response.ok || !answer.ok) throw new Error(answer.message || 'Порядок не сохранен.');
        list.dispatchEvent(new CustomEvent('sorted', { bubbles: true }));
      } catch (err) {
        alert(err.message + ' Страница будет обновлена.');
        location.reload();
      }
    });
  });
})();
