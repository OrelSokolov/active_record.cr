# active_record.cr

A Crystal port of Rails **ActiveRecord 8.1.4** for PostgreSQL — models,
Relation querying, validations, callbacks, associations, transactions,
migrations, schema dumping, STI, enums/stores and ActiveRecord::Encryption.
Namespace `ActiveRecord` mirrors the original 1:1. Status: **283/283
oracle specs green** (crud/dirty/callbacks/validations/associations/
transactions/persistence/proxy, through + polymorphic + HABTM +
counter_cache/touch/inverse_of, includes/preload/eager_load, optimistic
locking, STI, enum/store/alias_attribute/attr_readonly/cache_key/
has_secure_token, nested attributes, serialize, autosave), plus
migrations, `db/schema.cr` dump (byte-identical to the `schema.rb`
oracle) and encryption.

> ⚠️ EXPERIMENTAL FRAMEWORK, DO NOT USE IN PRODUCTION YET.

## How it works

1. `bin/ar_schema_dump` dumps the DB schema to `db/schema.yml`
   (columns/types/nullability) — input for compile-time codegen.
2. A model class `< ActiveRecord::Base` registers itself at compile time
   (`macro inherited`); at the end of the program a `{{ run(...) }}`
   runner reads `db/schema.yml` (env `CRAILS_SCHEMA`) and generates
   attributes, the row mapper, `initialize(**attrs)`,
   `attributes`/`[]`/`inspect`/`reload!`. Ruby's runtime `define_method`
   becomes compile-time code generation — this is the key mechanism of
   the whole port.
3. PostgreSQL → Crystal type mapping: `int*` → `Int64`, `float8` →
   `Float64`, `numeric` → `PG::Numeric`, `timestamp*` → `Time`,
   `json/jsonb` → `JSON::Any`, `bytea` → `Bytes`, arrays → `Array(...)`.
   Caveat: columns named after Crystal keywords (`until`) get getters/
   setters but are excluded from `new(**kwargs)`.

## Quick start

```sh
shards install

# 1) dump the DB schema to db/schema.yml (needed for codegen)
DATABASE_URL='postgres://root@/data_lake_development?host=/var/run/postgresql' \
  bin/ar_schema_dump

# 2) demo read
crystal run examples/datalake_read.cr
```

## Feature comparison vs activerecord 8.1.4

### Connections & schema

| Feature | Original (activerecord) | Port (active_record.cr) | Status |
|---|---|---|---|
| `establish_connection` (URL / config / database.yml subset), `DATABASE_URL`, unix sockets, `schema_search_path`, connection pool (`pool:` Rails semantics, default 5) | ✅ | Same | ✅ |
| Attribute codegen `name / name= / name? / name_was / name_changed?` | ✅ | `{{ run }}` from schema.yml | ✅ |
| `table_name=`, `primary_key=` | ✅ | Custom PK lives in `@id` (`w.uid` → `w.id`) | 🔶 |
| `attribute :x, default:` | ✅ | Applies to new records only (NULL from DB stays nil, oracle-verified); type argument accepted but ignored (types come from the schema) | 🔶 |
| Runtime attribute methods without recompilation | ✅ | Not possible — equivalent: `crails watch` (rebuild) | ❌ |

### Relation / querying

| Feature | Original | Port | Status |
|---|---|---|---|
| `where/not/order/limit/offset/reverse_order` (String+args, hash, Range→BETWEEN, Array→IN, nil→IS NULL) | ✅ | Same | ✅ |
| `each, empty?, count(+group), size, pluck, pick, ids` | ✅ | `count` with GROUP BY → Hash | ✅ |
| `take, first, first!, last, sole, to_sql` | ✅ | Same | ✅ |
| `exists?` (no args / id / conditions) | ✅ | Same | ✅ |
| `find_each, find_in_batches, in_batches(of:)` | ✅ | Same | ✅ |
| `find, find?, find_by, find_by!, first_or_create, find_or_create_by` | ✅ | Nilable finders cannot be chained (types) | 🔶 |
| `sum / average / minimum / maximum` | ✅ | average → `PG::Numeric` (2 digits) | ✅ |
| `or, merge, group, having, distinct` | ✅ | `or` checks structural compatibility | ✅ |
| `joins, left_outer_joins` | ✅ | has_many/has_one FK convention | ✅ |
| `includes, preload, eager_load, references` | ✅ | IN-queries + memory preload; eager_load as one LEFT OUTER JOIN with `AS c_<col>` aliases and owner dedup; `references` switches strategy (Rails semantics); polymorphic/through load lazily | ✅ |
| `select, reselect` | ✅ | Simple columns; unloaded attribute → nil (Rails: MissingAttributeError); raw SQL fragments cannot be materialized into records | 🔶 |
| `reorder, in_order_of` | ✅ | ARRAY_POSITION | ✅ |
| `update_all, delete_all, destroy_all, touch_all` | ✅ | Relation and class level | ✅ |
| `none, except/only, annotate, explain` | ✅ | explain → String (Rails: ExplainProxy) | 🔶 |
| `lock ("FOR UPDATE"), readonly, strict_loading` | ✅ | readonly save/destroy → ReadOnlyRecord; strict_loading → StrictLoadingViolationError | ✅ |
| `scope :name do ... end` (with parameters) | ✅ | Block-body splice | ✅ |
| `default_scope, unscoped` | ✅ | default_scope: single `where(...)` only (macro recursion limit) | 🔶 |
| Dynamic finders `find_by_email` | ✅ | No `method_missing` — use `find_by(email:)` | ❌ |

### Validations

| Feature | Original | Port | Status |
|---|---|---|---|
| presence / length / numericality / format / uniqueness (+`scope:`) | ✅ | Same | ✅ |
| inclusion, exclusion, acceptance, confirmation, comparison | ✅ | Rails 8 acceptance skips nil | ✅ |
| `validate` (method/block), `valid?(context)` / `invalid?` | ✅ | Default context :create/:update | ✅ |
| `on:, allow_blank:, allow_nil:, strict:` | ✅ | strict → StrictValidationFailed | ✅ |
| `if: / unless:` | ✅ | Ruby keywords — named args `condition:` / `unless_condition:` | 🔶 |
| `errors: add/full_messages/where/details/group_by_attribute` | ✅ | details keys are Strings (no runtime Symbols) | 🔶 |
| `around_validation` | — | Does not exist in Rails 8 | — |
| numericality of a String into an Int column | ✅ | Will not compile (documented) | ❌ |

### Callbacks

| Feature | Original | Port | Status |
|---|---|---|---|
| `before/after _validation/_save/_create/_update/_destroy` | ✅ | Order oracle-verified | ✅ |
| `around_save/create/update/destroy` | ✅ | Block or symbol form, order 1:1 | ✅ |
| `after_initialize, after_find, after_touch` | ✅ | after_find fires before after_initialize on load (1:1) | ✅ |
| `after_commit, after_rollback` (+ `on:` filter) | ✅ | Real COMMIT/ROLLBACK incl. savepoints | ✅ |

### Associations

| Feature | Original | Port | Status |
|---|---|---|---|
| `belongs_to` (+ `build_/create_`), `has_many`, `has_one` (+dependent), options `foreign_key, class_name, optional` | ✅ | Same | ✅ |
| CollectionProxy `each/count/size/empty?/ids/pluck/build/create/create!/destroy_all/delete_all/order?/where?` | ✅ | Same | ✅ |
| CollectionProxy `<<, concat, include?, destroy, delete, replace` | ✅ | `delete`/`replace` (nullify) implemented but not oracle-pinned (FK NOT NULL in scratch schema) | 🔶 |
| `<assoc>_ids` | ✅ | Codegen | ✅ |
| `through / source` | ✅ | Subquery `mid_fk IN (SELECT …)` | ✅ |
| Polymorphic (`as:`) | ✅ | Param `as_name:` (`as` is a keyword); compile-time POLY_OWNERS/POLY_USERS registry | 🔶 |
| `has_and_belongs_to_many` | ✅ | Join naming from both `table_name`s | ✅ |
| `counter_cache`, `inverse_of`, `autosave`, `touch` | ✅ | autosave stores children in `@loaded_assocs` (semantics 1:1 on oracle cases) | ✅ |
| `primary_key:` / `validate:` association options | ✅ | Not ported | ⬜ |
| Runtime `class_name: "Foo"` for arbitrary strings | ✅ | Compile-time known classes only | ❌ |

### Persistence & dirty

| Feature | Original | Port | Status |
|---|---|---|---|
| `new, create(_!), save(_!), update(_!), assign_attributes, attributes` | ✅ | Persistence methods take a Hash, not keywords | 🔶 |
| `destroy, persisted?, new_record?, frozen?` | ✅ | Same | ✅ |
| dirty: `changed?/changed/changes/saved_changes/will_save_change_to_x?` | ✅ | Same | ✅ |
| `update_columns, touch(*cols), insert_all(_!), upsert_all` | ✅ | Same | ✅ |
| `reload`, `update_attribute`, `increment/decrement(+!), toggle(+!)`, `restore_attributes`, `previous_changes`, instance `delete`, `becomes` | ✅ | Return-value semantics 1:1 | ✅ |
| Virtual attributes | ✅ | Direct setter only (no runtime method magic) | 🔶 |

### Transactions & locking

| Feature | Original | Port | Status |
|---|---|---|---|
| `transaction (requires_new:, isolation:)` | ✅ | Connection pinned to the fiber; joined-nested Rollback does not roll back (matches 8.1.4, verified on live Rails) | ✅ |
| `with_lock, lock!` | ✅ | SELECT FOR UPDATE on the pinned connection | ✅ |
| Optimistic locking (`lock_version`) | ✅ | `UPDATE ... AND lock_version = $N`; 0 rows → StaleObjectError | ✅ |

### Migrations & schema

| Feature | Original | Port | Status |
|---|---|---|---|
| `create_table` (all types, `timestamps, references, index`), `id: false`, column ops, `add_index (unique:, name:, where:)`, `add_reference`, FKs, `execute`, reversible `change` / up-down, `change_table`, `create_join_table`, check constraints, `reversible` blocks | ✅ | Same; partial indexes oracle-verified via dumps | ✅ |
| `crails db:migrate / rollback / schema:dump / schema:load` | ✅ | Dumps `db/schema.cr` (primary) + `db/schema.yml` (codegen input); schema:load recompiles a runner (~1 s, deliberate deviation from instant `ruby db/schema.rb`) | 🔶 |
| `db/schema.cr` ↔ `schema.rb` | ✅ | Byte-identical syntax to 8.1.4 (`ActiveRecord::Schema[8.1].define`, `force: :cascade`, `t.index`, `t.check_constraint`, `enable_extension`, `add_foreign_key`); differences: `require "active_record_cr"` header, typed empty literals (`[] of Int64`); expression defaults (`now()`) are not dumped | 🔶 |

### Enums, stores, STI, misc

| Feature | Original | Port | Status |
|---|---|---|---|
| `enum status: [...]` → predicates/bang-methods/scopes | ✅ | Macro `ar_enum` (`enum` is a keyword); getter returns String (8.1, oracle-verified) | ✅ |
| `store / store_accessor` | ✅ | jsonb out of the box, `StoreProxy` container | ✅ |
| `serialize` | ✅ | JSON coder only (Rails' YAML default not ported); text column ↔ JSON roundtrip; mutating a read container is not tracked — assign a new one | 🔶 |
| `alias_attribute` | ✅ | Getter/setter + `where` resolution | ✅ |
| `accepts_nested_attributes_for` | ✅ | has_many with autosave semantics, `allow_destroy:`, `reject_if: :all_blank`; belongs_to form ⬜; setter is explicit (`model.n_posts_attributes = [...]`) | 🔶 |
| `cache_key`, `has_secure_token`, `attr_readonly`, `to_param`, `signed_id` | ✅ | cache_key ✅, has_secure_token ✅ (24 hex), attr_readonly ✅ (silently ignored, oracle-verified); to_param ⬜; signed_id ❌ (MessageVerifier not available outside a Rails app) | 🔶 |
| STI (`type` column) | ✅ | One inheritance level: `__read_row` dispatch + `becomes` | ✅ |
| Runtime `constantize` | ✅ | Compile-time registry only | ❌ |

### Encryption (phase G)

| Feature | Original | activerecord encryption | Port | Status |
|---|---|---|---|---|
| AES-256-GCM cipher, deterministic IV (HMAC-SHA256), Message + serializer (byte-exact JSON envelope), compression >140 B | ✅ | Same (EVP aes-256-gcm) | ✅ |
| Key providers: DerivedSecretKeyProvider / DeterministicKeyProvider (PBKDF2-HMAC-SHA1 2**16, AS::KeyGenerator) | ✅ | Same | ✅ |
| `encrypts` macro, `Model.encrypted_attributes`, `#ciphertext_for`, `Model.where_encrypted` | ✅ | Deterministic lookup (analog of ExtendedDeterministicQueries) | ✅ |
| Config: `configure` \|\| ENV `ACTIVE_RECORD_ENCRYPTION_*` \|\| defaults | ✅ | Same (ENV support is an extension) | ✅ |
| Envelope encryption / key references (k/i headers), `previous:` schemes, `ignore_case` original_* columns, NullEncryptor contexts | ✅ | Not ported | ⬜ |

## Deviations & Crystal-specific notes

- No `method_missing`, no runtime Symbols, no `constantize`, static
  typing — these power most ❌ rows above; equivalents are compile-time
  registries and codegen.
- Nilable finders cannot be unwrapped into a chain; persistence methods
  accept `Hash`, not keywords; virtual attributes via direct setters
  (details in the linked SEMANTICS doc of the umbrella project).
- Class variables are not shared with subclasses — state is accessed via
  explicit `Base.` receivers; transactions pin a connection to the fiber.

## Testing

```sh
# fixture DB crails_ar_test + datalake read-only
psql -h /var/run/postgresql -U root -d postgres -c 'create database crails_ar_test owner root'
psql -h /var/run/postgresql -U root -d crails_ar_test -f spec/fixtures/seed.sql
crystal spec
```

Oracle-first development: `oracle/cases.rb` + `oracle/migrations.rb` /
`oracle/schema.rb` are recorded against real activerecord 8.1.4;
mirror specs in `spec/oracle_spec.cr` / `spec/migrations_spec.cr` /
`spec/schema_spec.cr` reproduce the expected files without editing the
cases. Encryption parity: 26 Ruby cases + a reverse check where the real
gem decrypts port ciphertexts (`oracle/verify_encryption.rb`).
