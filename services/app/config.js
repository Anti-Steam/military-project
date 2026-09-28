'use strict';

// Конфигурация читается только из переменных окружения (файл .env в корне
// репозитория). Пароли в коде не хранятся.

module.exports = {
  port: Number(process.env.APP_PORT || 3000),
  env: process.env.NODE_ENV || 'development',

  db: {
    host: process.env.DB_HOST || 'localhost',
    port: Number(process.env.DB_PORT || 5433),
    database: process.env.DB_NAME || 'military',
    user: process.env.DB_USER || 'military',
    password: process.env.DB_PASSWORD || '',
    options: `-c timezone=${process.env.TZ || 'Asia/Krasnoyarsk'}`,
  },
};
