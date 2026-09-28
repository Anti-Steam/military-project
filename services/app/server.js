'use strict';

// Точка входа единого сервиса MVP.
//
// Здесь собирается приложение: подключаются модули, задаются общие настройки
// и обработчики ошибок. Прикладной логики в этом файле нет.

// Часовой пояс задается до первого обращения к датам. Время заступления
// в наряд — местное время части, и оно должно совпадать с поясом БД,
// иначе отчеты покажут сдвиг. Значение берется из .env.
process.env.TZ = process.env.TZ || 'Asia/Krasnoyarsk';

const path = require('node:path');
const express = require('express');

const config = require('./config');
const db = require('./db/pool');

const personnelService = require('./modules/personnel/service');
const dutyService = require('./modules/duty/service');

const app = express();
// Адрес компьютера пользователя (блокировка входа — по нему) за Nginx
// берется из X-Forwarded-For, но верится ему только от Nginx на этой же
// машине: с другого адреса заголовок подделать нельзя.
app.set('trust proxy', 'loopback');

app.set('view engine', 'ejs');
app.set('views', path.join(__dirname, 'views'));

app.use(require('./lib/compress').compress);
app.use(express.urlencoded({ extended: false, parameterLimit:10000 }));
app.locals.today = () => require('./modules/duty/calendar').dayKey(new Date());
app.use(express.static(path.join(__dirname, 'public')));

// ----------------------------------------------------------------------------
// Форматирование дат — доступно во всех шаблонах.
// ----------------------------------------------------------------------------
const dateFormat = new Intl.DateTimeFormat('ru-RU', {
  day: '2-digit', month: '2-digit', year: 'numeric',
});
const dateTimeFormat = new Intl.DateTimeFormat('ru-RU', {
  day: '2-digit', month: '2-digit', year: 'numeric', hour: '2-digit', minute: '2-digit',
});
const longDateFormat = new Intl.DateTimeFormat('ru-RU', {
  day: 'numeric', month: 'long', year: 'numeric',
});

app.locals.fmtDate = (value) => (value ? dateFormat.format(new Date(value)) : '—');
app.locals.fmtDateTime = (value) => (value ? dateTimeFormat.format(new Date(value)) : '—');
app.locals.fmtLongDate = (value) => (value ? longDateFormat.format(new Date(value)) : '—');

// Календарные дни приходят строкой YYYY-MM-DD и обозначают день, а не момент
// времени. Через new Date() такая строка разбирается как полночь UTC и при
// отрицательном смещении показывает предыдущие сутки, поэтому день собирается
// по частям.
app.locals.fmtDay = (value) => {
  if (!value) return '—';
  if (value === 'infinity') return 'без срока';
  const [y, m, d] = String(value).split('-').map(Number);
  return dateFormat.format(new Date(y, m - 1, d, 12));
};

// «по 12.10.2026» или «без срока» — окончание отсутствия.
app.locals.until = (value) => (value === 'infinity' ? 'без срока' : `по ${app.locals.fmtDay(value)}`);

const DUTY_STATUS_LABELS = {
  draft: 'проект',
  submitted: 'на утверждении',
  approved: 'утвержден',
  cancelled: 'отменен',
};
app.locals.dutyStatus = (code) => DUTY_STATUS_LABELS[code] || code;

// Вход, сессия и права действующего лица. Без сессии дальше проходят только
// страница входа и статические файлы — см. modules/access/service.js.
const access = require('./modules/access/service');
app.use(access.attach);
// Все, что меняется дальше в этом запросе, журнал изменений запишет за
// вошедшим пользователем.
app.use((req, res, next) => db.asUser(req.user && req.user.id, () => next()));
app.use(access.csrf);
app.use(require('./modules/access/routes'));

// ----------------------------------------------------------------------------
// Стартовая страница. Сводка собирается из обоих модулей — сборка приложения
// вправе обращаться к их публичным интерфейсам.
// ----------------------------------------------------------------------------
app.get('/', async (req, res, next) => {
  try {
    const [employeeCount, dutyTypes, duties] = await Promise.all([
      access.can(req.user, 'personnel.view')
        ? require('./modules/org/service').scopeIds(req.user).then(ids => personnelService.countActive(ids))
        : null,
      access.can(req.user, 'duty.view') ? dutyService.listDutyTypes() : [],
      access.can(req.user, 'duty.view') ? dutyService.listDuties() : [],
    ]);

    res.render('index', {
      title: 'АИС учета личного состава',
      employeeCount,
      dutyTypes,
      duties: duties.slice(0, 10),
    });
  } catch (err) {
    next(err);
  }
});

app.use(require('./modules/audit/routes'));
app.use(require('./modules/orderparse/routes'));
app.use(require('./modules/org/routes'));
app.use(require('./modules/personnel/routes'));
app.use(require('./modules/duty/routes'));
app.use(require('./modules/order/routes'));

// ----------------------------------------------------------------------------
// Обработка ошибок
// ----------------------------------------------------------------------------
app.use((req, res) => {
  res.status(404).render('error', {
    title: 'Страница не найдена',
    message: `Адрес ${req.path} не существует.`,
  });
});

app.use((err, req, res, next) => {
  console.error('Ошибка обработки запроса:', err);
  const status=err.status || (['23505','23503','23514','22P02','22007','22008'].includes(err.code) ? 400:500);
  res.status(status).render('error', {
    title: 'Внутренняя ошибка',
    message: err.userMessage ? err.message : status===400 ? 'Данные некорректны или запись уже существует. Обновите страницу и проверьте поля.' : config.env === 'development' ? err.message : 'Внутренняя ошибка сервера.',
  });
});

// ----------------------------------------------------------------------------
// Запуск
// ----------------------------------------------------------------------------
async function start() {
  try {
    await db.query('SELECT 1');
  } catch (err) {
    console.error('Нет соединения с базой данных:');
    console.error(`  ${config.db.user}@${config.db.host}:${config.db.port}/${config.db.database}`);
    console.error(`  ${err.message}`);
    console.error('Проверьте, что контейнер запущен: docker compose ps');
    process.exit(1);
  }

  const server=app.listen(config.port, () => {
    console.log(`Сервер запущен: http://localhost:${config.port}`);
  });
  server.on('error',async err=>{
    console.error(err.code==='EADDRINUSE' ? `Порт ${config.port} занят. Остановите прежний экземпляр приложения или измените APP_PORT в .env.` : err.message);
    await db.pool.end();process.exitCode=1;
  });
  const stop=()=>server.close(()=>db.pool.end());
  process.once('SIGINT',stop);process.once('SIGTERM',stop);
}

if(require.main===module) start();
module.exports={app,start};
