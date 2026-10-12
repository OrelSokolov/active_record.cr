# active_record.cr

> ⚠️ EXPERIMENTAL FRAMEWORK, DO NOT USE IN PRODUCTION YET.

ActiveRecord-порт на Crystal (PostgreSQL). Текущий срез: **чтение 1:1**
(кодоген атрибутов, Relation, типизированные чтения). Запись/валидации/
мирации — по фазам из `PLAN.md`.

## Быстрый старт (datalake, read-only)

```sh
shards install

# 1) снять схему БД в db/schema.yml (нужно для compile-time кодогена)
DATABASE_URL='postgres://root@/data_lake_development?host=/var/run/postgresql' \
  bin/ar_schema_dump

# 2) демо-чтение
crystal run examples/datalake_read.cr
```

## Как это работает

1. `bin/ar_schema_dump` пишет `db/schema.yml` (колонки/типы/nullability).
2. Класс-модель `< ActiveRecord::Base` регистрируется на этапе компиляции
   (`macro inherited`), в конце программы `{{ run(...) }}`-раннер читает
   `db/schema.yml` (env `CRAILS_SCHEMA`) и генерит атрибуты, маппер строк,
   `initialize(**attrs)`, `attributes`/`[]`/`inspect`/`reload!`.
3. SQL-типы PostgreSQL → Crystal: int*→Int64, float8→Float64,
   numeric→PG::Numeric, timestamp*→Time, json/jsonb→JSON::Any,
   bytea→Bytes, массивы→Array(...). Осторожно: колонки с именами-ключевыми
   словами Crystal (`until` в `player_injuries`) получают getter/setter,
   но не участвуют в `new(**kwargs)`.

## API (реализован)

- Подключение: `establish_connection(url)`, `establish_connection(**config)`,
  `establish_connection_from_yaml(path, env)` (Rails database.yml-подмножество),
  `DATABASE_URL`, unix-сокеты (`host: "/var/run/postgresql"`),
  `schema_search_path=`, пул коннектов Rails-семантикой `pool:`
  (дефолт 5, держит до N соединений открытыми).
- Отличия семантики и типов от Rails AR (nilable-файндеры нельзя
  разворачивать в цепочку, persistence-методы принимают Hash, а не
  кейворды, виртуальные атрибуты — только прямым сеттером):
  `../SEMANTICS.md`.
- Модели: `find/find?/find_by/find_by!`, `where` (String+args, hash,
  Range→BETWEEN, Array→IN, nil→IS NULL), `not`, `order` (Symbol/String/hash),
  `limit/offset/reverse_order`, `first/first!/last/take/sole`,
  `count/exists?/empty?`, `pluck/pick/ids`, `find_each(batch_size:)`,
  `to_sql`, `table_name`, `attributes`, `[]`, `inspect`, `reload!`,
  `new_record?/persisted?`, `==`.

## Спеки

```sh
# fixtures (БД crails_ar_test, создаётся скриптом ниже) + datalake read-only
psql -h /var/run/postgresql -U root -d postgres -c 'create database crails_ar_test owner root'
psql -h /var/run/postgresql -U root -d crails_ar_test -f spec/fixtures/seed.sql
crystal spec
```

datalake-база читается read-only: спеки проверяют кодоген по реальной
схеме пользователя и пусто-таблицевую семантику Rails.
