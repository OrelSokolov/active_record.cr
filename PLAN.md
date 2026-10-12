# active_record.cr — план-таблица порта ActiveRecord

> ⚠️ EXPERIMENTAL FRAMEWORK, DO NOT USE IN PRODUCTION YET.
>
> Неймспейс `ActiveRecord`, API 1:1 с Rails 8. Статус меняем прямо в этой
> таблице. Легенда статусов:
>
> - ✅ готово (покрыто oracle-спеками, activerecord 8.1.4)
> - 🔶 частично / с отклонением (указано в «Примечании»)
> - ⬜ не начато
> - ❌ Crystal не позволит / осознанное отклонение (эквивалент указан)

**Статус (2026-10-05): 283/283 спеков зелёные (oracle: crud/dirty/callbacks/
validations/associations/transactions/relation §2/persistence §6/proxy §5/
P1-хвост/P2 (through, polymorphic, HABTM, counter_cache/touch/inverse_of,
includes/preload, eager_load/references, optimistic locking, STI, enum/store/
alias_attribute/attr_readonly/cache_key/has_secure_token, nested attributes,
serialize (JSON coder), autosave у ассоциаций)
+ migrations + schema.cr (дамп 1:1 с schema.rb-оракулом + schema:load
round-trip) + encryption (фаза G, ниже)). P0–P2 закрыты; остатки — см.
«Порядок оставшихся работ».**

## Encryption (фаза G, 2026-10-05) — ✅

Oracle-first: `oracle/encryption_cases.rb` → `oracle/encryption_expected.yml`
(26 кейсов, activerecord 8.1.4 standalone с pinned-ключами; каждая стадия
гема — отдельный ruby-скрипт), реверс `oracle/verify_encryption.rb` (гем
расшифровывает порт-ciphertext'ы: nd/det/custom-key). Зеркало
`spec/encryption_oracle_spec.cr` — 20/20 (реплей + реверс + postgres:
таблица secret_notes, геттер/сеттер/byte-exact/where_encrypted/nil/
unencrypted-raise).

- `src/encryption.cr`: порт ActiveRecord::Encryption — Cipher::Aes256Gcm
  (EVP aes-256-gcm; deterministic iv = HMAC-SHA256(secret, text)[0,12]),
  Message + MessageSerializer (JSON `{"p":b64,"h":{"iv":b64,"at":b64
  [,"c":true]}}`, insertion-порядок как Ruby JSON.dump — побайтово),
  Properties (короткие ключи iv/at/c), DerivedSecretKeyProvider/
  DeterministicKeyProvider (PBKDF2-HMAC-SHA1 2**16 от
  primary_key/deterministic_key c key_derivation_salt — AS::KeyGenerator),
  Encryptor (zlib-компрессия >140 байт, порог как гем), Scheme
  (deterministic/downcase/support_unencrypted_data/key),
  `ActiveRecord::Encryption.configure`
- Ключи: configure || ENV ACTIVE_RECORD_ENCRYPTION_{PRIMARY_KEY,
  DETERMINISTIC_KEY,KEY_DERIVATION_SALT} (расширение) || Configuration
- `encrypts`-макрос (base.cr): геттер расшифровывает (nil-safe, голая
  строка → Decryption без support_unencrypted_data), сеттер шифрует;
  initialize/assign_attributes идут через сеттер, загрузка строк из БД —
  напрямую в ivar (без перешифровки); `Model.encrypted_attributes`,
  `#ciphertext_for`, `Model.where_encrypted(attr, value)` (детерминированный
  лукап — аналог ExtendedDeterministicQueries)
- Отклонения: envelope encryption/key references (k/i-заголовки),
  previous:-схемы, ignore_case-колонки original_*, NullEncryptor-контексты
  не портированы; шифрующий сеттер (в Rails — type-слой на границе SQL)

## Ключевой механизм

Rails генерит методы атрибутов в рантайме (`define_method`). Crystal-эквивалент
— compile-time кодоген `{{ run("codegen/from_schema.cr", table) }}` из
`db/schema.yml`.

Универсальные Crystal-ограничения (влияют на строки с ❌):

- нет `method_missing` → никакой рантайм-магии методов;
- Symbol существует только compile-time → нет `constantize`/"to_sym" в рантайме;
- статическая типизация → нет неявных строково-числовых приведений.

**Ловушки, найденные при реализации (не наступать снова):**

1. Класс-переменные (`@@db`, `@@tx_stack`) НЕ шарятся с подклассами — доступ
   только через явные `Base.`-ресиверы (`src/transactions.cr`).
2. Захваченный блок без аннотации типа (`&block; block.call`) возвращает Nil —
   транзакции используют голый `&` + прямой `yield` в теле метода.
3. `yield` нельзя использовать внутри блок/proc-литерала; `r.@ivar = ...`
   запрещено — Relation использует `rebuild(...)`-конструктор.
4. `{scope: :x}` в макро-kwargs — это `NamedTupleLiteral` (не HashLiteral),
   итерируется только `{% for k, v in x %}` (named_args/entries у него нет).
5. `.stringify` у SymbolLiteral даёт `":name"` (с двоеточием) — всегда
   `name.id.stringify`; сплайс `{{x}}` строкового литерала добавляет свои
   кавычки — не закавычивать повторно.
6. `as`, `out`, `enum` — ключевые слова Crystal: параметры/методы называть
   `as_name`, `result`, `ar_enum`.
7. `DB::Any` (crystal-db) НЕ включает `JSON::Any` — параметры записей с
   jsonb идут через `__db_param` (jsonb → JSON-строка, Numeric → Float).
8. Многострочные операторы внутри одного `{% ... %}` не парсятся — писать
   построчными тегами `{% for %} … {% end %}`.
9. `Enumerable` в Crystal — `find`, не `detect`; `.equal?` → `.same?`.
10. `Model.new({"k" => v})` биндит хэш в первый позиционный аргумент
    (`for_load`) — именованные аргументы только: `Model.new(name: "x")`.

## 1. Подключение и схема

| API (Rails) | Статус | Примечание |
|---|---|---|
| `establish_connection` (URL / config / database.yml) | ✅ | unix-сокеты, `schema_search_path`, пул |
| Кодоген атрибутов `name / name= / name? / name_was / name_changed?` | ✅ | `{{ run }}` из schema.yml (fallback-формат дампа; primary — db/schema.cr, но кодоген читает YAML) |
| `table_name=`, `primary_key=` | ✅ | `set_table_name` / `set_primary_key`; кастомный pk живёт в `@id` (`w.uid` → `w.id`) |
| `attribute :x, default:` | ✅ | `attribute :nickname, default: "anon"`; применяется только к NEW-записям (NULL из БД остаётся nil — oracle-проверено); type-аргумент принимается, но игнорируется (типы из схемы) |
| Рантайм-методы после смены схемы БЕЗ рекомпиляции | ❌ | эквивалент: `crails watch` = rebuild |

## 2. Relation / запросы

| API (Rails) | Статус | Примечание |
|---|---|---|
| `where/not/order/limit/offset/reverse_order` | ✅ | |
| `each, empty?, count(+group), size, pluck, pick, ids` | ✅ | count c GROUP BY → Hash |
| `take, first, first!, last, sole, to_sql` | ✅ | |
| `exists?` | ✅ | без аргументов, `exists?(id)` и `exists?(attr: value)` |
| `find_each, find_in_batches, in_batches(of:)` | ✅ | |
| `find, find?, find_by, find_by!, first_or_create, find_or_create_by` | ✅ | |
| `sum / average / minimum / maximum` | ✅ | average → PG::Numeric(2 знака) |
| `or, merge` | ✅ | `or` проверяет структурную совместимость |
| `group, having, distinct` | ✅ | |
| `select, reselect` | 🔶 | простые колонки (append/reselect); отклонения: незагруженный атрибут → nil (Rails: MissingAttributeError), raw-SQL фрагменты нельзя материализовать в записи |
| `joins, left_outer_joins` | ✅ | конвенция has_many/has_one FK |
| `includes, preload, eager_load, references` | ✅ | includes/preload: IN-запросы, прелоад из памяти, счётчик запросов оракул-сверен; eager_load: один LEFT OUTER JOIN-запрос (has_many с дедупликацией владельцев + belongs_to), columns алиасятся `AS c_<col>`; `references(:table)` переключает `includes` на eager_load-стратегию (Rails-семантика); полиморфные/through-ассоциации — лениво |
| `reorder, in_order_of` | ✅ | ARRAY_POSITION |
| `update_all, delete_all, destroy_all, touch_all` | ✅ | на уровне Relation и класса |
| `none, except/only, annotate, explain` | ✅ | explain → String (в Rails ExplainProxy) |
| `lock, readonly, strict_loading` | ✅ | `lock`/"FOR UPDATE", readonly-записи: save/destroy/update_columns/touch → ReadOnlyRecord; strict_loading: доступ к ассоциации → StrictLoadingViolationError |
| `scope :name do ... end` (с параметрами) | ✅ | сплайс тела блока |
| `default_scope, unscoped` | 🔶 | default_scope — только одиночный `where(...)` (макро-ограничение, иначе рекурсия через класс-уровень API) |
| Dynamic finders `find_by_email` | ❌ | нет `method_missing` → `find_by(email:)` |

## 3. Валидации

| API (Rails) | Статус | Примечание |
|---|---|---|
| presence / length / numericality / format / uniqueness(+scope:) | ✅ | |
| inclusion, exclusion, acceptance, confirmation, comparison | ✅ | Rails 8 acceptance пропускает nil |
| `validate` (метод/блок), `valid?(context)` / `invalid?` | ✅ | контекст :create/:update по умолчанию |
| `on:, allow_blank:, allow_nil:, strict:` | ✅ | strict → StrictValidationFailed |
| `if: / unless:` | 🔶 | Ruby-ключевые слова → `condition:` / `unless_condition:` |
| `errors: add/full_messages/where(attr[, type])/details/group_by_attribute` | ✅ | details-ключи String (в Ruby — Symbol; рантайм-символов нет) |
| `around_validation` | ❌ | в Rails 8 НЕ существует — не портируем |
| numericality на строке в Int-колонку | ❌ | не скомпилируется (задокументировано) |

## 4. Коллбэки

| API (Rails) | Статус | Примечание |
|---|---|---|
| before/after `_validation/_save/_create/_update/_destroy` | ✅ | порядок сверен с оракулом |
| `around_save/create/update/destroy` | ✅ | блок-форма или `around_save :m`; порядок 1:1 (around_save обёртывает before_save; around_create выходит ДО after_create) |
| `after_initialize, after_find, after_touch` | ✅ | on load after_find срабатывает ДО after_initialize (1:1) |
| `after_commit, after_rollback` (+ `on:`-фильтр) | ✅ | реальный COMMIT/ROLLBACK, включая savepoints; вне транзакции — на каждую операцию |

## 5. Ассоциации

| API (Rails) | Статус | Примечание |
|---|---|---|
| `belongs_to` (+ `build_/create_`), `has_many`, `has_one` (+dependent) | ✅ | опции `foreign_key, class_name, optional` |
| CollectionProxy `each/count/size/empty?/ids/pluck/build/create/create!/destroy_all/delete_all/order?/where?` | ✅ | |
| CollectionProxy `<<, concat, include?, destroy, delete, replace` | 🔶 | `delete`/`replace` (nullify) реализованы, но oracle-НЕзакреплены: в scratch-схеме FK NOT NULL |
| `post_ids` | ✅ | `<assoc>_ids` кодогеном |
| `through / source` | ✅ | subquery `mid_fk IN (SELECT …)`; `source` по конвенции |
| polymorphic (`as:`) | ✅ | параметр `as_name:` (as — ключевое слово); compile-time реестр `POLY_OWNERS/POLY_USERS`; геттер/сеттер эмитится в `macro finished` |
| `has_and_belongs_to_many` | ✅ | join-имена от table_name обеих сторон; при нестандартных классах Ruby-стороне нужны явные `foreign_key:`/`association_foreign_key:` |
| `counter_cache` (опция + конвенции) | ✅ | хуки after_create/before_destroy; без ребаланса при смене FK |
| `inverse_of, autosave, touch, primary_key, validate` (опции) | 🔶 | inverse_of ✅ (кэш на build/<<, авто-подбор по FK), touch ✅ (after_save/after_destroy), autosave ✅ (has_many: target в памяти @loaded_assocs — первый доступ грузит, мутации «липнут»; дети new/dirty валидируются с родителем — ошибки как `<assoc>.<attr>` ("Auto comments body can't be blank"), сохраняются в after_create/after_update c validate: false; belongs_to: кэш записи при чтении/присваивании, сохранение в before_save + проставление FK, abort save при неудаче; port хранит детей в @loaded_assocs, а не в прокси-таргете Rails — семантика 1:1 на oracle-кейсах); `primary_key:`/`validate:` опции ⬜ |
| Рантайм `class_name: "Foo"` по любой строке | ❌ | только классы, известные на компиляции |

## 6. Persistence + dirty

| API (Rails) | Статус | Примечание |
|---|---|---|
| `new, create(_!), save(_!), update(_!), assign_attributes, attributes` | ✅ | |
| `destroy, persisted?, new_record?, frozen?` | ✅ | |
| dirty: `changed?/changed/changes/saved_changes/will_save_change_to_x?` | ✅ | |
| `update_columns, touch(*cols), insert_all(_!), upsert_all` | ✅ | |
| `reload` | ✅ | + сгенерированный `reload!` |
| `update_attribute` (без валидаций, → Bool) | ✅ | 1:1: возвращает результат save, не self |
| `increment/decrement(+!), toggle(+!)` | ✅ | 1:1: toggle → self, toggle! → Bool |
| `restore_attributes, previous_changes` | ✅ | restore восстанавливает значения |
| инстансный `delete` (без коллбэков) | ✅ | |
| `becomes(OtherClass)` | ✅ | generic-метод, копия атрибутов |

## 7. Транзакции и локи

| API (Rails) | Статус | Примечание |
|---|---|---|
| `transaction` (`requires_new:, isolation:`) | ✅ | пиннинг коннекта на fiber; Joined-nested Rollback НЕ откатывает (1:1 с 8.1.4 — сверено на живом Rails!) |
| `with_lock, lock!` | ✅ | SELECT FOR UPDATE на пинненном коннекте |
| optimistic locking (`lock_version`) | ✅ | UPDATE `AND lock_version = $N` + инкремент; 0 строк → StaleObjectError |

## 8. Миграции

| API (Rails) | Статус | Примечание |
|---|---|---|
| `create_table` (все типы, `timestamps, references, index`), `id: false` | ✅ | |
| `drop_table, add/remove/rename/change_column, change_column_default/null` | ✅ | |
| `add_index (unique:, name:, where:)`, `remove_index` | ✅ | партиальные индексы `WHERE (...)` — в add_index, `t.index` (create_table и change_table), oracle-сверено по дампам |
| `add_reference / add_belongs_to, add/remove_foreign_key` | ✅ | |
| `execute`, реверс `change` (command recorder), up/down | ✅ | |
| `change_table` (column/remove/rename/change_default/change_null/index) | ✅ | прокси поверх обратимых операций |
| `create_join_table` | ✅ | сортированная пара, singular-колонки, без PK, БЕЗ индекса (1:1 с 8.1.4) |
| `add_check_constraint` / `remove_check_constraint` | ✅ | входит в дамп как `t.check_constraint "expr", name:` (oracle-сверено) |
| `reversible`-блоки | ✅ | `dir.up { ... } / dir.down { ... }`; down-блок пишется в recorder как обратная операция |
| `crails db:migrate / rollback / schema:dump` | ✅ | дампит `db/schema.cr` (primary) + `db/schema.yml` (fallback: вход кодогена моделей) |
| `db/schema.cr` — аналог Rails `schema.rb` | ✅ | синтаксис 1:1 с 8.1.4 (oracle/schema.rb → oracle/schema_expected.cr, байт-в-байт): `ActiveRecord::Schema[8.1].define(version:)`, `create_table ... force: :cascade`, `t.index/t.check_constraint`, `enable_extension`, `add_foreign_key`; отличия от Ruby: `require "active_record_cr"` в шапке, `default: [] of Int64` (типизированный пустой литерал); expression-дефолты (`now()`) в дамп не попадают |
| `crails db:schema:load` | ✅ | пересоздаёт БД из `db/schema.cr` через `crystal run`-раннер (компиляция ~сек, осознанное отклонение от мгновенного `ruby db/schema.rb`); `assume_migrated_upto` проставляет версии в `schema_migrations` |

## 9. Прочее (P2)

| API (Rails) | Статус | Примечание |
|---|---|---|
| `enum status: [...]` → `draft?/draft!` + скопы | ✅ | макрос `ar_enum` (enum — ключевое слово); геттер возвращает String (8.1, oracle-сверено); `active?/active!/Model.active/Model.statuses` |
| `serialize`, `store/store_accessor`, `alias_attribute` | 🔶 | store ✅ (jsonb из коробки, `StoreProxy`-контейнер, `store :settings, accessors: [:theme]`), alias_attribute ✅ (геттер/сеттер + резолв в `where`), serialize ✅ (`serialize :settings, coder: :json` — text-колонка ↔ JSON roundtrip: ридер `JSON::Any?`, сеттер JSON::Any/Hash; `type: Array` — `Array(JSON::Any)` + Rails-дефолт `type.new` ([] для NULL/new). Отклонения: YAML-кодер (дефолт Rails) не портирован — только JSON; ivar хранит сырую JSON-строку → `attributes`/`_was` выдают её, мутация прочитанного контейнера не отслеживается — присваивай новый контейнер) |
| `accepts_nested_attributes_for` | ✅ | has_many: отложенная запись (autosave-семантика), `allow_destroy:`, `reject_if: :all_blank`; ошибки детей всплывают как `"N posts <message>"`; belongs_to-форма ⬜. Отклонение: kwargs-значение-массив не типизируется — сеттер `model.n_posts_attributes = [...]` вызывается явно |
| `cache_key / to_param`, `signed_id`, `has_secure_token`, `attr_readonly` | 🔶 | cache_key ✅ (`table/new`, `table/id[-ts]`), has_secure_token ✅ (24 hex), attr_readonly ✅ (молча игнорируется — oracle-сверено); to_param ⬜; signed_id ❌ (MessageVerifier вне Rails-приложения недоступен) |
| STI (колонка `type`) | ✅ | один уровень наследования: `__read_row`-диспатч + `becomes`; таблица наследуется от родителя |
| Рантайм-`constantize` по строке | ❌ | только compile-time registry |

## Порядок оставшихся работ

1. **Хвост P2** (опционально): опции `primary_key:`/`validate:` у ассоциаций,
   belongs_to-форма nested attributes, `to_param`,
   полиморфные/through в includes/eager_load, YAML-кодер для serialize.

## Готово, когда

Рельс-учебниковская модель (`Post` с `belongs_to :user`,
`validates :title, presence: true`, `scope :published`) и контроллер CRUD
работают кодом 1:1 с Rails-туториалом.

## Тестирование (правило AGENTS.md)

Каждая фича начинается с интеграционных кейсов: `oracle/cases.rb` +
`oracle/migrations.rb` / `oracle/schema.rb` снимаются с настоящего
activerecord 8.1.4; зеркала в `spec/oracle_spec.cr` /
`spec/migrations_spec.cr` / `spec/schema_spec.cr` воспроизводят
expected-файлы без правки тестов. Кейс-модели добавляются пачками
(`TxPost`, `ScopedPost`, `IncAuthor`, `AroundPost`, `LegacyPost`, …).

## Зависимости

active_support.cr, crystal-pg.
