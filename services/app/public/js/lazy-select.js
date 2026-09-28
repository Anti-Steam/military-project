'use strict';

// Выпадающие списки с длинным повторяющимся перечнем (подразделения в каждой
// строке поста, «Входит в» в каждой форме правки) приходят в разметке
// только с выбранным вариантом. Полный перечень страница получает ОДИН раз —
// window.OPTION_LISTS[имя], — и он подставляется в список при первом
// нажатии или переходе на него с клавиатуры. Тысяча одинаковых <option>
// на странице — это и вес, и время разбора.
//
// Разметка: <select data-options="units" data-exclude="12"> — имя перечня и
// (необязательно) значение, которое в этом списке не предлагается.

(function () {
  function fill(select) {
    if (select.dataset.filled) return;
    select.dataset.filled = '1';

    var list = (window.OPTION_LISTS || {})[select.dataset.options] || [];
    var current = select.value;
    var exclude = select.dataset.exclude || '';

    // Пустой вариант («— нет —») остается первым, дальше — весь перечень
    // в своем порядке, с прежним выбором.
    var empty = Array.prototype.filter.call(select.options, function (o) { return o.value === ''; });
    select.innerHTML = '';
    empty.forEach(function (o) { select.add(o); });
    list.forEach(function (item) {
      if (String(item.id) === exclude) return;
      select.add(new Option(item.label, item.id, false, String(item.id) === current));
    });
    select.value = current;
  }

  function onEvent(event) {
    var select = event.target.closest && event.target.closest('select[data-options]');
    if (select) fill(select);
  }

  document.addEventListener('mousedown', onEvent, true);
  document.addEventListener('touchstart', onEvent, true);
  document.addEventListener('focusin', onEvent, true);
})();
