# ActiveRecord::Base — read-side core (P0 slice for the datalake).
#
# Codegen: every model subclass is registered via `macro inherited`;
# a top-level `macro finished` reopens it at end of program and splices
# attribute methods generated from db/schema.yml via `{{ run(...) }}`
# (see codegen_runner.cr).

module ActiveRecord
  class RecordNotFound < Exception
  end

  class RecordInvalid < Exception
    attr_reader :record

    def initialize(@record : Base)
      super("Validation failed: #{@record.errors.full_messages.join(", ")}")
    end
  end

  class RecordNotSaved < Exception
  end

  class RecordNotUnique < Exception
  end

  class StrictValidationFailed < Exception
  end

  class ReadOnlyRecord < Exception
  end

  class StrictLoadingViolationError < Exception
  end

  class StaleObjectError < Exception
  end

  MODELS = [] of TypeNode

  # String-only association spec (CanCan SQL builder). Dispatching the
  # metaclass-carrying `__associations` on a virtual `Base.class+` receiver
  # trips an LLVM codegen bug (GEP on a metaclass union); this shape is
  # safe to dispatch virtually.
  alias AssocSpec = NamedTuple(name: String, kind: String, table: String,
                               pk: String, foreign_key: String)

  # Compile-time registry of `set_table_name` overrides, filled by the macro.
  # (Constants defined in subclasses are not yet visible from `macro finished`,
  # so a registry is used instead of a `__TABLE_NAME__` constant lookup.)
  TABLE_OVERRIDES = [] of Nil

  # Compile-time registry of default_scope bodies ({class name, where call}).
  DEFAULT_SCOPES = [] of Nil

  # Compile-time registry of primary key overrides ({class name, pk name}).
  PRIMARY_KEYS = [] of Nil

  # Compile-time registry of `attribute ... default:` declarations
  # ({class name, attribute name, default literal}).
  ATTRIBUTE_DEFAULTS = [] of Nil

  # Compile-time enum registry: {class name, column, NamedTuple of
  # value => int}. Rails 8.1 enum getters return STRINGS (oracle-verified).
  ENUMS = [] of Nil

  # enum options kept in side registries (ENUMS arity stays at 3 — five
  # consumption sites destructure it): {class, enum, prefix-string} and
  # {class, enum, default-value}.
  ENUM_PREFIXES = [] of Nil
  ENUM_DEFAULTS = [] of Nil

  # Compile-time store registry: {class name, jsonb column}. Models using
  # `store` get a StoreProxy reader instead of the raw JSON::Any.
  STORES = [] of Nil

  # Compile-time serialize registry: {class name, text column, kind} where
  # kind is "any" (JSON::Any reader) or "array" (Array(JSON::Any) + the
  # Rails type.new default). ar_codegen skips the plain column getter for
  # these; the `serialize` macro emits the typed reader itself.
  SERIALIZERS = [] of Nil

  # Compile-time encrypted-attribute registry (the `encrypts` macro):
  # {class name, column, deterministic, support_unencrypted_data,
  # downcase, key}. ar_codegen replaces the plain getter/setter with
  # decrypt/encrypt ones (src/encryption.cr).
  ENCRYPTED = [] of Nil

  # Compile-time attribute alias registry: {class, alias, column}.
  ALIASES = [] of Nil

  # Read-only view over a jsonb store column: `settings["theme"]` returns
  # the scalar like Ruby's Hash (String for strings; raw.to_s otherwise).
  class StoreProxy
    def initialize(@hash : Hash(String, JSON::Any))
    end

    def [](key : String) : String?
      @hash[key]?.try do |v|
        raw = v.raw
        raw.is_a?(String) ? raw : raw.to_s
      end
    end

    def key?(key : String) : Bool
      @hash.has_key?(key)
    end

    def size : Int32
      @hash.size
    end
  end

  class Base
    macro inherited
      {% ActiveRecord::MODELS << @type %}
    end

    # Virtual-dispatch base for codegen-generated per-model find? — lets
    # runtime class objects (GlobalID::Locator lookup) call find?. Concrete
    # models override this via the codegen; Base itself is never queried.
    def self.find?(id : Int64 | Int32 | String) : self?
      raise NotImplementedError.new("find? on a non-concrete model")
    end

    # Virtual-dispatch base for the codegen table_name accessor.
    def self.table_name : String
      raise NotImplementedError.new("table_name on a non-concrete model")
    end

    # Explicit table name override (before codegen):
    #   class LegacyPost < ActiveRecord::Base
    #     set_table_name "posts"
    #   end
    macro set_table_name(name)
      {% ActiveRecord::TABLE_OVERRIDES << {@type.name.stringify, name} %}
    end

    # Explicit primary key override (before codegen):
    #   class Widget < ActiveRecord::Base
    #     set_primary_key "uid"
    #   end
    macro set_primary_key(name)
      {% ActiveRecord::PRIMARY_KEYS << {@type.name.stringify, name} %}
    end

    # attribute :nickname, default: "anon" — model-level default applied to
    # NEW records only (a NULL read from the database stays nil, mirroring
    # Rails 8.1 — oracle-verified). The `type` argument is accepted for
    # 1:1 with the Ruby API and ignored: column types come from the
    # schema codegen.
    macro attribute(name, type = nil, default = nil)
      {% ActiveRecord::ATTRIBUTE_DEFAULTS << {@type.name.stringify, name.id.stringify, default} %}
    end

    # encrypts :content, deterministic: true — шифрование атрибута
    # (ActiveRecord::Encryption, фаза G; src/encryption.cr). Геттер
    # расшифровывает, сеттер шифрует: в БД (и в @ivar) лежит ciphertext
    # {"p":..,"h":{..}}. Поиск по deterministic-атрибуту —
    # Model.where_encrypted(attr, value). Отклонения от гема: previous:,
    # ignore_case: и компрессор-опции не поддержаны.
    macro encrypts(*names, deterministic = false, support_unencrypted_data = false,
                   downcase = false, key = nil)
      {% for name in names %}
        {% ActiveRecord::ENCRYPTED << { @type.name.stringify, name.id.stringify, deterministic, support_unencrypted_data, downcase, key } %}
      {% end %}
    end

    # enum :status, {draft: 0, active: 1} — Ruby's `enum` is a keyword in
    # Crystal, hence the ar_ prefix. Rails 8.1 semantics: the getter
    # returns a String (unmapped DB values read as nil, oracle-verified),
    # `status=` accepts String/Symbol/Int, `active?` predicates, `active!`
    # save-bangs, `Model.active` scope, `Model.statuses` mapping. Values
    # may be ints or strings (Rails' %w[...].index_by(&:itself)); invalid
    # string values raise ArgumentError on write — setter, .new and update
    # (string-valued enums) alike, matching the oracle.
    #
    # Options: an ArrayLiteral of symbols auto-numbers the values (Rails'
    # %i[...] form); `prefix:` renames predicates/bangs/scopes (Rails'
    # `prefix: :involved_in` → `involved_in_invisible?`); `default:`
    # applies the value to new records in after_initialize.
    macro ar_enum(name, values, prefix = nil, default = nil)
      # Registry values are normalized to an ArrayLiteral of {key, value}
      # tuples (ArrayLiteral inputs auto-number, Rails' %i[...] form) —
      # consumption sites iterate `for pair in e[2]` uniformly.
      {% norm = [] of Nil %}
      {% if values.is_a?(ArrayLiteral) %}
        {% i = 0 %}
        {% for sym in values %}
          {% norm << {sym.id, i} %}
          {% i = i + 1 %}
        {% end %}
      {% else %}
        {% for k, v in values %}
          {% norm << {k.id, v} %}
        {% end %}
      {% end %}
      {% ActiveRecord::ENUMS << { @type.name.stringify, name.id.stringify, norm } %}
      {% if prefix %}
        {% ActiveRecord::ENUM_PREFIXES << { @type.name.stringify, name.id.stringify, prefix.id.stringify } %}
      {% end %}
      {% if default %}
        {% default_value = nil %}
        {% for pair in norm %}
          {% if pair[0].id.stringify == default.id.stringify %}{% default_value = pair[1] %}{% end %}
        {% end %}
        {% raise "ar_enum #{name}: default #{default} is not one of its values" unless default_value %}
        after_initialize { @{{name.id}} = {{ default_value }} if @{{name.id}}.nil? && new_record? }
      {% end %}
    end

    # store :settings, accessors: [:theme] — jsonb-backed accessor methods.
    # The container reader below (StoreProxy) survives because ar_codegen
    # skips the plain column getter for STORES-registry columns, so
    # `settings["theme"]` inspects like Ruby's Hash value ("dark", not
    # JSON::Any("dark")).
    macro store(attr_name, accessors = nil)
      {% ActiveRecord::STORES << {@type.name.stringify, attr_name.id.stringify} %}
      {% for a in accessors %}
        def {{a.id}} : String?
          if (s = @{{attr_name.id}})
            s[{{a.id.stringify}}]?.try(&.as_s?)
          else
            nil
          end
        end

        def {{a.id}}=(value : String) : Nil
          base = @{{attr_name.id}}.try(&.as_h) || {} of String => JSON::Any
          base[{{a.id.stringify}}] = JSON::Any.new(value)
          self.{{attr_name.id}} = JSON::Any.new(base)
        end
      {% end %}

      def {{attr_name.id}} : ::ActiveRecord::StoreProxy?
        @{{attr_name.id}}.try { |v| ::ActiveRecord::StoreProxy.new(v.as_h) }
      end
    end

    # serialize :settings, coder: :json — text column ↔ JSON roundtrip.
    # Rails 8.1: serialize(attr_name, coder: nil, type: Object, ...) with a
    # default YAML coder; the port supports the JSON coder only (Rails'
    # `serialize :settings, coder: JSON`). The raw JSON string is kept in
    # the ivar (String column); the typed reader parses it on access.
    # `type: Array` mirrors Rails' typed form: Array(JSON::Any) reader with
    # the type.new default ([] for NULL columns and new records).
    # Deviations: the YAML coder is not ported; `attributes` / `_was` expose
    # the raw JSON string (no deserialized-object cache, so in-place
    # mutation of a read container is not tracked — assign a new container).
    macro serialize(attr_name, coder = nil, type = nil)
      {% c = coder ? coder.id.stringify : "json" %}
      {% unless ["json", "JSON"].includes?(c) %}
        {% raise "serialize: only the JSON coder is supported (got #{c})" %}
      {% end %}
      {% if type && type.id.stringify == "Array" %}
        {% ActiveRecord::SERIALIZERS << {@type.name.stringify, attr_name.id.stringify, "array"} %}

        def {{attr_name.id}} : Array(JSON::Any)
          raw = @{{attr_name.id}}
          raw.nil? ? [] of JSON::Any : JSON.parse(raw).as_a
        end

        def {{attr_name.id}}=(value : Array(JSON::Any)) : Nil
          @{{attr_name.id}} = value.to_json
        end

        def {{attr_name.id}}=(value : Array(String)) : Nil
          @{{attr_name.id}} = value.to_json
        end
      {% else %}
        {% ActiveRecord::SERIALIZERS << {@type.name.stringify, attr_name.id.stringify, "any"} %}

        def {{attr_name.id}} : JSON::Any?
          raw = @{{attr_name.id}}
          raw.nil? ? nil : JSON.parse(raw)
        end

        def {{attr_name.id}}=(value : JSON::Any) : Nil
          @{{attr_name.id}} = value.to_json
        end

        def {{attr_name.id}}=(value : Hash(String, JSON::Any)) : Nil
          @{{attr_name.id}} = value.to_json
        end
      {% end %}
    end

    # has_secure_token: 24-char hex token generated before the first save.
    macro has_secure_token(attr_name = :token)
      def before_save__cb_secure_token : Bool
        if new_record? && @{{attr_name.id}}.nil?
          @{{attr_name.id}} = Random::Secure.hex(12)
        end
        true
      end
    end

    # attr_readonly: changes to these columns are silently ignored on
    # update (Rails behaviour, oracle-verified).
    macro attr_readonly(*names)
      def __readonly_attrs : Array(String)
        a = [] of String
        {% for n in names %}a << {{n.id.stringify}}{% end %}
        a
      end
    end

    # alias_attribute :title, :name — reader/writer delegates; the alias
    # also resolves inside where(...).
    macro alias_attribute(new_name, old_name)
      def {{new_name.id}}
        {{old_name.id}}
      end

      def {{new_name.id}}=(value)
        self.{{old_name.id}} = value
      end

      {% ActiveRecord::ALIASES << {@type.name.stringify, new_name.id.stringify, old_name.id.stringify} %}
    end

    # scope :published do ... end — the block body is spliced into a class
    # method; block parameters become method parameters.
    #   scope :with_views_gt do |n|
    #     where("views > ?", n)
    #   end
    #
    # Rails lambda form is also accepted (the ProcLiteral is decomposed by
    # the macro, so parameter type annotations are not required — the proc
    # itself is never compiled):
    #   scope :ordered, -> { order(:created_at) }
    #   scope :with_views_gt, ->(n) { where("views > ?", n) }
    macro scope(name, lambda = nil, &block)
      {% if lambda %}
        {% unless lambda.is_a?(ProcLiteral) %}
          {% raise "scope #{name}: expected a -> {} lambda, got #{lambda.class_name}" %}
        {% end %}
        def self.{{name.id}}({{ lambda.args.map(&.name).splat }})
          {{ lambda.body }}
        end
        {% ::ActiveRecord::SCOPES << { @type.stringify, name.id.stringify, lambda.args, lambda.body } %}
      {% else %}
        def self.{{name.id}}({{ block.args.splat }})
          {{ block.body }}
        end
        {% ::ActiveRecord::SCOPES << { @type.stringify, name.id.stringify, block.args, block.body } %}
      {% end %}
    end

    # default_scope { where(...) } — the body must be a single `where`
    # call (Crystal port limitation; arbitrary chains would recurse
    # through the class-level query API). Applied in `self.all`;
    # `unscoped` bypasses it.
    macro default_scope(&block)
      {% body = block.body %}
      {% if body.is_a?(Call) && body.name.stringify == "where" %}
        {% ActiveRecord::DEFAULT_SCOPES << {@type.name.stringify, body} %}
      {% else %}
        {% raise "default_scope supports a single `where(...)` call (Crystal port limitation)" %}
      {% end %}
    end

    attr_accessor id : Int64?
    property? new_record = true
    property? destroyed = false
    # Set on records materialized from Relation#readonly / #strict_loading.
    property? readonly = false
    property? strict_loading = false

    # Errors from the last validation run (see validations.cr).
    attr_accessor errors = Errors.new

    @original_attributes : Hash(String, Value)?
    @previous_changes : Hash(String, Tuple(Value, Value)) = {} of String => Tuple(Value, Value)
    @previously_new_record = false

    # Rails 7+ dirty: true when the last save created the record.
    def previously_new_record? : Bool
      @previously_new_record
    end

    # Rails attribute_previously_changed?: did the last save change `name`,
    # optionally from a given old / to a given new value (loose String/Int
    # comparison — enum columns read back as raw Int64/String values).
    def attribute_previously_changed?(name : String, from = nil, to = nil) : Bool
      change = saved_changes[name]?
      return false unless change
      old_value, new_value = change
      return false unless __previously_matches?(old_value, from)
      return false unless __previously_matches?(new_value, to)
      true
    end

    private def __previously_matches?(value : Value, expected) : Bool
      case expected
      when Nil then true
      when String then value.to_s == expected
      when Int32 then value == expected.to_i64
      when Int64 then value == expected
      else value.to_s == expected.to_s
      end
    end

    # Overridden per model when `attribute ... default:` is declared.
    def __apply_manual_attribute_defaults : Nil
      nil
    end

    def __readonly_attrs : Array(String)
      [] of String
    end

    # Attribute-alias resolution (overridden per model by alias_attribute).
    def self.__resolve_column(name : String) : String
      name
    end

    def persisted? : Bool
      !new_record? && !destroyed?
    end

    # dirty API ------------------------------------------------------------
    # `changes` etc. live in persistence.cr; they compare `attributes`
    # against the snapshot taken on load/save (`@original_attributes`).

    def __original_attributes : Hash(String, Value)
      @original_attributes || {} of String => Value
    end

    def __snapshot_original! : Nil
      @original_attributes = attributes.dup
    end

    def __previous_changes!(changes) : Nil
      @previous_changes = changes
    end

    def saved_changes : Hash(String, Tuple(Value, Value))
      @previous_changes
    end

    def has_changes_to_save? : Bool
      changed?
    end

    def ==(other : self) : Bool
      !id.nil? && !other.id.nil? && id == other.id
    end

    def hash(hasher)
      id.hash(hasher)
    end

    # Attribute codegen from schema.yml (called with string column names
    # so PostgreSQL keywords like `until` stay 1:1 — def names are built
    # at the AST level and never re-parsed).
    # cols: [["name", "CrystalType", is_bool?, kw_ok?, default_lit], ...]
    macro ar_codegen(pk, cols)
      {% has_type = false %}
      {% for c in cols %}{% if c[0] == "type" %}{% has_type = true %}{% end %}{% end %}

      # STI case: the direct superclass is itself a registered
      # non-abstract model (Rooms::Open < Room). Intermediate abstract
      # bases (ApplicationRecord) are skipped via `abstract?`.
      # (Inlined — a macro body can't call macro methods on this
      # Crystal version; MODELS already lists models defined so far,
      # and a superclass is always defined before its subclass.)
      {% super_is_model = false %}
      {% unless @type.superclass.stringify == "ActiveRecord::Base" %}
        {% for m in ActiveRecord::MODELS %}
          {% if m.name.stringify == @type.superclass.name.stringify && !m.abstract? %}
            {% super_is_model = true %}
          {% end %}
        {% end %}
      {% end %}

      {% for c in cols %}
        @{{c[0].id}} : {{c[1].id}}? = {{c[4]}}

        {% enum_col = false %}
        {% for e in ActiveRecord::ENUMS %}
          {% if e[0] == @type.name.stringify && e[1] == c[0] %}{% enum_col = true %}{% end %}
        {% end %}
        {% store_col = false %}
        {% for s in ActiveRecord::STORES %}
          {% if s[0] == @type.name.stringify && s[1] == c[0] %}{% store_col = true %}{% end %}
        {% end %}
        {% ser_col = false %}
        {% for s in ActiveRecord::SERIALIZERS %}
          {% if s[0] == @type.name.stringify && s[1] == c[0] %}{% ser_col = true %}{% end %}
        {% end %}
        {% enc_opts = nil %}
        {% for e in ActiveRecord::ENCRYPTED %}
          {% if e[0] == @type.name.stringify && e[1] == c[0] %}{% enc_opts = e %}{% end %}
        {% end %}
        {% if enum_col %}
          # enum reader generated separately (Rails 8.1: String getters)
          # raw assignment bypassing the validating setter (row loading) —
          # oracle: junk DB values READ as nil, they don't raise on load
          def __assign_raw_{{c[0].id}}(value : {{c[1].id}}?) : Nil
            @{{c[0].id}} = value
          end
        {% elsif store_col %}
          def {{c[0].id}} : ::ActiveRecord::StoreProxy?
            @{{c[0].id}}.try { |v| ::ActiveRecord::StoreProxy.new(v.as_h) }
          end
        {% elsif ser_col %}
          # serialize reader generated by the `serialize` macro (base.cr)
        {% elsif enc_opts %}
          # encrypted attribute (encrypts): reader decrypts, writer
          # encrypts; @ivar (and the DB) keep the ciphertext

          # raw assignment bypassing the encrypting setter (row loading)
          def __assign_raw_{{c[0].id}}(value : String?) : Nil
            @{{c[0].id}} = value
          end
          def {{c[0].id}} : String?
            raw = @{{c[0].id}}
            return nil if raw.nil?
            ::ActiveRecord::Encryption.default_scheme(
              deterministic: {{enc_opts[2]}},
              downcase: {{enc_opts[4]}},
              support_unencrypted_data: {{enc_opts[3]}},
              key: {{enc_opts[5]}}
            ).deserialize(raw)
          end

          def {{c[0].id}}=(value : String?) : Nil
            @{{c[0].id}} =
              if value.nil?
                nil
              else
                ::ActiveRecord::Encryption.default_scheme(
                  deterministic: {{enc_opts[2]}},
                  downcase: {{enc_opts[4]}},
                  key: {{enc_opts[5]}}
                ).serialize(value)
              end
          end
        {% else %}
          def {{c[0].id}} : {{c[1].id}}?
            @{{c[0].id}}
          end
        {% end %}

        {% unless enc_opts %}
          def {{c[0].id}}=(value : {{c[1].id}}?)
            @{{c[0].id}} = value
          end
        {% end %}

        {% if c[2] %}
          def {{c[0].id}}? : Bool
            !!@{{c[0].id}}
          end
        {% end %}

        def {{c[0].id}}_was : ::ActiveRecord::Value
          changed_attribute?({{c[0]}}) ? __original_attributes[{{c[0]}}] : @{{c[0].id}}.as(::ActiveRecord::Value)
        end

        def {{c[0].id}}_changed? : Bool
          attribute_changed?({{c[0]}}, @{{c[0].id}})
        end

        def will_save_change_to_{{c[0].id}}? : Bool
          {{c[0].id}}_changed?
        end

        def {{c[0].id}}_previously_changed?(from = nil, to = nil) : Bool
          attribute_previously_changed?({{c[0]}}, from: from, to: to)
        end
      {% end %}

      {% params = [] of Nil %}
      {% for c in cols %}{% if c[3] %}{% params << c %}{% end %}{% end %}
      {% if params.empty? %}
        def initialize(for_load = false)
          {% if has_type && super_is_model %}
            @type = {{ @type.name.split("::").last }} if @type.nil?
          {% end %}
          __apply_manual_attribute_defaults unless for_load
          __run_after_initialize unless for_load
        end
      {% else %}
        def initialize(for_load = false, *, {% for c in params %} {{c[0].id}} : {{c[1].id}}? = {{c[4]}}, {% end %})
          {% for c in params %}
            {% enc_init = false %}
            {% for e in ActiveRecord::ENCRYPTED %}
              {% if e[0] == @type.name.stringify && e[1] == c[0] %}{% enc_init = true %}{% end %}
            {% end %}
            # string-valued enum columns validate through the setter —
            # Rails raises ArgumentError on Model.new(enum_col: "junk");
            # nil assigns directly (nullable column, Rails allows nil)
            {% enum_init = false %}
            {% for e in ActiveRecord::ENUMS %}
              {% if e[0] == @type.name.stringify && e[1] == c[0] %}
                {% enum_init = (e[2].is_a?(ArrayLiteral) ? e[2].map { |tup| tup[1] }.first : e[2].values.first).is_a?(StringLiteral) %}
              {% end %}
            {% end %}
            # encrypted columns go through the encrypting setter
            {% if enc_init %}self.{{c[0].id}} = {{c[0].id}};{% elsif enum_init %}
              if (ev = {{c[0].id}})
                self.{{c[0].id}} = ev
              else
                @{{c[0].id}} = nil
              end
            {% else %}@{{c[0].id}} = {{c[0].id}};{% end %}
          {% end %}
          {% if has_type && super_is_model %}
            @type = {{ @type.name.split("::").last }} if @type.nil?
          {% end %}
          __apply_manual_attribute_defaults unless for_load
          __run_after_initialize unless for_load
        end
      {% end %}

      def self.__from_row(rs : DB::ResultSet) : self
        __from_row_cols(rs, __column_names)
      end

      def self.__read_row(rs : DB::ResultSet, names : Array(String)) : self
        record = new(for_load: true)
        names.each do |name|
          case name
          when {{pk}} then record.id = rs.read(Int64?)
          {% for c in cols %}
            when {{c[0]}} then
              {% if c[1] == "Int64" %}
                # int2/int4 columns decode as Int32 — widen to Int64
                record.{{c[0].id}} = rs.read(Int32 | Int64 | Nil).try(&.to_i64)
              {% else %}
                {% enc_read = false %}
                {% for e in ActiveRecord::ENCRYPTED %}
                  {% if e[0] == @type.name.stringify && e[1] == c[0] %}{% enc_read = true %}{% end %}
                {% end %}
                {% enum_read = false %}
                {% for e in ActiveRecord::ENUMS %}
                  {% if e[0] == @type.name.stringify && e[1] == c[0] %}{% enum_read = true %}{% end %}
                {% end %}
                # encrypted columns: load the ciphertext straight into the
                # ivar (the setter would re-encrypt it); enum columns: load
                # raw too (the setter would raise on junk values — oracle
                # reads those back as nil)
                {% if enc_read || enum_read %}
                  record.__assign_raw_{{c[0].id}}(rs.read({{c[1].id}}?))
                {% elsif c[1] == "JSON::Any" %}
                  # json/jsonb columns: pg decodes to JSON::Any natively,
                  # SQLite returns TEXT — normalize both (a NULL stays nil)
                  record.{{c[0].id}} = rs.read(String | JSON::Any | Nil)
                    .try { |v| v.as?(JSON::Any) || JSON::Any.from_json(v.to_s) }
                {% else %}
                  record.{{c[0].id}} = rs.read({{c[1].id}}?)
                {% end %}
              {% end %}
          {% end %}
          else
            raise ArgumentError.new("unknown column #{name} for #{self}")
          end
        end
        record.new_record = false
        record.__snapshot_original!
        # Rails order (oracle-verified): after_find fires BEFORE
        # after_initialize on loaded records.
        record.__run_after_find
        record.__run_after_initialize
        record
      end

      # Builds a record from the given column subset (Relation#select);
      # the primary key always lands in `@id` regardless of its name.
      # STI tables (a `type` column): rows are materialized as the base
      # class and converted to the registered subclass via becomes().
      def self.__from_row_cols(rs : DB::ResultSet, names : Array(String)) : self
        base = __read_row(rs, names)
        {% if has_type %}
          if (tv = base.type)
            case tv
            {% for sub in @type.all_subclasses %}
              {% unless sub.abstract? %}
            when {{sub.name.split("::").last}} then return base.becomes({{sub}})
              {% end %}
            {% end %}
            else
              # unknown type value: keep the base class
            end
          end
        {% end %}
        base
      end

      def attributes : Hash(String, ActiveRecord::Value)
        attrs = {} of String => ActiveRecord::Value
        attrs[{{pk}}] = @id
        {% for c in cols %}
          attrs[{{c[0]}}] = @{{c[0].id}}
        {% end %}
        attrs
      end

      def [](name : String) : ActiveRecord::Value
        case name
        when {{pk}} then @id
        {% for c in cols %}
          when {{c[0]}} then @{{c[0].id}}
        {% end %}
        else
          raise ArgumentError.new("unknown attribute #{name} for #{self.class}")
        end
      end

      def assign_attributes(values : Hash(String, ActiveRecord::Value)) : Nil
        values.each do |name, value|
          case name
          {% for c in cols %}
            {% enc_assign = false %}
            {% for e in ActiveRecord::ENCRYPTED %}
              {% if e[0] == @type.name.stringify && e[1] == c[0] %}{% enc_assign = true %}{% end %}
            {% end %}
            # enum columns accept the string name through the validating
            # setter (name -> value mapping, junk raises ArgumentError);
            # raw column-typed values assign directly
            {% enum_assign = false %}
            {% for e in ActiveRecord::ENUMS %}
              {% if e[0] == @type.name.stringify && e[1] == c[0] %}{% enum_assign = true %}{% end %}
            {% end %}
            # encrypted columns go through the encrypting setter
            {% if enc_assign %}
            when {{c[0]}} then self.{{c[0].id}} = value.as?(String)
            {% elsif enum_assign %}
            when {{c[0]}} then
              if (ev = value.as?(String))
                self.{{c[0].id}} = ev
              else
                @{{c[0].id}} = value.as?({{c[1].id}})
              end
            {% else %}
            when {{c[0]}} then @{{c[0].id}} = value.as?({{c[1].id}})
            {% end %}
          {% end %}
          else
            raise ArgumentError.new("unknown attribute #{name} for #{self.class}")
          end
        end
      end

      def self.__column_defaults : Hash(String, ActiveRecord::Value)
        defaults = {} of String => ActiveRecord::Value
        {% for c in cols %}
          {% unless c[4] == "nil" %}
            defaults[{{c[0]}}] = {{c[4].id}}.as(ActiveRecord::Value)
          {% end %}
        {% end %}
        defaults
      end
    end
  end

  # End-of-program codegen: attribute methods + class query API per model.
  macro finished
    {% for t in ActiveRecord::MODELS %}
      {% unless t.abstract? %}
        {% class_name = t.name.split("::").last %}
        {% custom_table = nil %}
        {% for pair in ActiveRecord::TABLE_OVERRIDES %}
          {% if pair[0] == t.name.stringify %}
            {% custom_table = pair[1] %}
          {% end %}
        {% end %}
        # STI subclasses inherit the table name (explicit override or
        # convention) from their model superclass (one level; deeper STI
        # needs an explicit set_table_name). Intermediate abstract bases
        # (ApplicationRecord) are not models — walk past them.
        {% table_class = class_name %}
        {% if custom_table.nil? && t.superclass.stringify != "ActiveRecord::Base" %}
          {% super_is_model = false %}
          {% for m in ActiveRecord::MODELS %}
            {% if m.name.stringify == t.superclass.name.stringify && !m.abstract? %}
              {% super_is_model = true %}
            {% end %}
          {% end %}
          {% for pair in ActiveRecord::TABLE_OVERRIDES %}
            {% if pair[0] == t.superclass.name.stringify %}{% custom_table = pair[1] %}{% end %}
          {% end %}
          {% if custom_table.nil? && super_is_model %}
            {% table_class = t.superclass.name.split("::").last %}
          {% end %}
        {% end %}
        {% table_arg = custom_table || "" %}
        {% custom_pk = nil %}
        {% for pair in ActiveRecord::PRIMARY_KEYS %}
          {% if pair[0] == t.name.stringify %}
            {% custom_pk = pair[1] %}
          {% end %}
        {% end %}
        {% pk_arg = custom_pk || "" %}
        # STI shape: a non-abstract registered model superclass marks the
        # class as single-table-inherited (abstract intermediates like
        # ApplicationRecord do not).
        {% super_is_model = false %}
        {% for m in ActiveRecord::MODELS %}
          {% if m.name.stringify == t.superclass.name.stringify && !m.abstract? %}
            {% super_is_model = true %}
          {% end %}
        {% end %}
        {% runner = __DIR__ + "/codegen_runner.cr" %}
        class ::{{ t.stringify.id }}
          {{ run(runner, table_class, table_arg, pk_arg, t.name.stringify).id }}

          {% defaults = ActiveRecord::ATTRIBUTE_DEFAULTS.select { |p| p[0] == t.name.stringify } %}
          {% unless defaults.empty? %}
            def __apply_manual_attribute_defaults : Nil
              {% for p in defaults %}
                @{{p[1].id}} = {{p[2]}} if @{{p[1].id}}.nil?
              {% end %}
              nil
            end
          {% end %}

          # Polymorphic belongs_to: dispatch over the compile-time registry
          # of `as:` owners (no runtime constantize in Crystal).
          {% for u in ActiveRecord::POLY_USERS %}
            {% if u[0] == t.name.stringify %}
              def {{u[1].id}} : ::ActiveRecord::Base?
                tid = {{(u[1] + "_id").id}}
                ttype = {{(u[1] + "_type").id}}
                return nil if tid.nil? || ttype.nil?
                case ttype
                {% for o in ActiveRecord::POLY_OWNERS %}
                  {% if o[0] == u[1] %}
                when {{o[1]}} then {{o[2]}}.find?(tid.not_nil!)
                  {% end %}
                {% end %}
                else nil
                end
              end

              def {{u[1].id}}=(record : ::ActiveRecord::Base)
                self.{{(u[1] + "_id").id}} = record.id
                self.{{(u[1] + "_type").id}} = record.class.name
                record
              end
            {% end %}
          {% end %}

          {% ds = nil %}
          {% for pair in ActiveRecord::DEFAULT_SCOPES %}
            {% if pair[0] == t.name.stringify %}{% ds = pair[1] %}{% end %}
          {% end %}

          {% encs = ActiveRecord::ENCRYPTED.select { |e| e[0] == t.name.stringify } %}
          {% unless encs.empty? %}
            # Encrypted attributes of the model (Set in the gem).
            def self.encrypted_attributes : Array(String)
              {{ encs.map { |e| e[1] } }}
            end

            # The ciphertext actually stored for *attr_name* (nil / plain
            # value for non-encrypted attributes).
            def ciphertext_for(attr_name : String) : String?
              case attr_name
              {% for e in encs %}
              when {{e[1]}} then @{{e[1].id}}
              {% end %}
              else
                attributes[attr_name]?.try(&.to_s)
              end
            end

            # Search on a deterministic encrypted attribute (the gem's
            # ExtendedDeterministicQueries): encrypt *value* and do a
            # plain string lookup.
            def self.where_encrypted(attr_name : String,
                                     value : String) : ::ActiveRecord::Relation(self)
              case attr_name
              {% for e in encs %}
                {% if e[2] %}
              when {{e[1]}} then
                ciphertext = ::ActiveRecord::Encryption
                  .default_scheme(deterministic: true, downcase: {{e[4]}}, key: {{e[5]}})
                  .serialize(value).not_nil!
                where({{e[1]}} + " = ?", ciphertext)
                {% end %}
              {% end %}
              else
                raise ArgumentError.new(
                  "not a deterministic encrypted attribute: #{attr_name}")
              end
            end
          {% end %}

          def self.all : ::ActiveRecord::Relation(self)
            {% if ds %}
              rel = ::ActiveRecord::Relation(self).new(self)
              rel = rel.{{ ds.name.id }}({% if ds.args.size > 0 %}{{ ds.args.splat }}, {% end %}{% if ds.named_args %}{% for na in ds.named_args %}{{ na.name.id }}: {{ na.value }}, {% end %}{% end %})
            {% else %}
              rel = ::ActiveRecord::Relation(self).new(self)
            {% end %}
            # STI descendant: single-table filter on the type column.
            # Intermediate abstract bases (ApplicationRecord) are not
            # models — walk past them (same as the table-name logic).
            # Inlined (a `macro finished` body can't call macro methods
            # defined in Base or at top level on this Crystal version).
            {% super_m = false %}
            {% unless t.superclass.stringify == "ActiveRecord::Base" %}
              {% for m in ActiveRecord::MODELS %}
                {% if m.name.stringify == t.superclass.name.stringify && !m.abstract? %}
                  {% super_m = true %}
                {% end %}
              {% end %}
            {% end %}
            {% if super_m %}
              rel = rel.where(type: name.not_nil!.split("::").last) if __has_type_column?
            {% end %}
            rel
          end

          # Bypasses default_scope (Rails `unscoped`).
          def self.unscoped : ::ActiveRecord::Relation(self)
            ::ActiveRecord::Relation(self).new(self)
          end

          def self.where(condition : String, *args) : ::ActiveRecord::Relation(self)
            all.where(condition, *args)
          end

          def self.where(**opts) : ::ActiveRecord::Relation(self)
            all.where(**opts)
          end

          def self.not(**opts) : ::ActiveRecord::Relation(self)
            all.not(**opts)
          end

          def self.order(*cols : String | Symbol) : ::ActiveRecord::Relation(self)
            all.order(*cols)
          end

          def self.order(**opts) : ::ActiveRecord::Relation(self)
            all.order(**opts)
          end

          def self.limit(n : Int) : ::ActiveRecord::Relation(self)
            all.limit(n)
          end

          def self.offset(n : Int) : ::ActiveRecord::Relation(self)
            all.offset(n)
          end

          def self.count : Int64 | Hash(ActiveRecord::Value, Int64)
            all.count
          end

          def self.exists? : Bool
            all.exists?
          end

          def self.any? : Bool
            all.any?
          end

          def self.exists?(id : Int64 | Int32) : Bool
            all.where(%("#{primary_key}" = ?), id.to_i64).exists?
          end

          def self.exists?(**opts) : Bool
            all.where(**opts).exists?
          end

          def self.select(*cols : String | Symbol) : ::ActiveRecord::Relation(self)
            all.select(*cols)
          end

          def self.reselect(*cols : String | Symbol) : ::ActiveRecord::Relation(self)
            all.reselect(*cols)
          end

          def self.lock(clause : String = "FOR UPDATE") : ::ActiveRecord::Relation(self)
            all.lock(clause)
          end

          def self.readonly(value : Bool = true) : ::ActiveRecord::Relation(self)
            all.readonly(value)
          end

          def self.strict_loading(value : Bool = true) : ::ActiveRecord::Relation(self)
            all.strict_loading(value)
          end

          def self.includes(*names : String | Symbol) : ::ActiveRecord::Relation(self)
            all.includes(*names)
          end

          # Nested Rails form (see Relation#includes): class-level
          # includes(creator: :avatar_attachment) / preload(:room, boosts: { ... }).
          def self.includes(**nested : Symbol | String | ::NamedTuple) : ::ActiveRecord::Relation(self)
            all.includes(**nested)
          end

          def self.includes(*names : String | Symbol, **nested : Symbol | String | ::NamedTuple) : ::ActiveRecord::Relation(self)
            all.includes(*names, **nested)
          end

          def self.preload(*names : String | Symbol) : ::ActiveRecord::Relation(self)
            all.preload(*names)
          end

          def self.preload(**nested : Symbol | String | ::NamedTuple) : ::ActiveRecord::Relation(self)
            all.preload(**nested)
          end

          def self.preload(*names : String | Symbol, **nested : Symbol | String | ::NamedTuple) : ::ActiveRecord::Relation(self)
            all.preload(*names, **nested)
          end

          def self.eager_load(*names : String | Symbol) : ::ActiveRecord::Relation(self)
            all.eager_load(*names)
          end

          def self.references(*names : String | Symbol) : ::ActiveRecord::Relation(self)
            all.references(*names)
          end

          def self.take : self?
            all.take
          end

          def self.first : self?
            all.first
          end

          def self.first! : self
            all.first!
          end

          def self.last : self?
            all.last
          end

          def self.pluck(col : String | Symbol) : Array(ActiveRecord::Value)
            all.pluck(col)
          end

          def self.ids : Array(Int64)
            all.ids
          end

          def self.find(id : Int64 | Int32 | String) : self
            pk = case id
                 in Int64, Int32 then id.to_i64
                 in String
                   parsed = id.to_i64?
                   raise ActiveRecord::RecordNotFound.new(
                     "Couldn't find #{self} with 'id'=#{id}") unless parsed
                   parsed
                 end
            find?(pk) || raise ActiveRecord::RecordNotFound.new(
              "Couldn't find #{self} with 'id'=#{pk}")
          end

          def self.find?(id : Int64 | Int32 | String) : self?
            pk = case id
                 in Int64, Int32 then id.to_i64
                 in String then id.to_i64?
                 end
            pk ? all.where(%("#{primary_key}" = ?), pk).first : nil
          end

          def self.find_by(**opts) : self?
            all.where(**opts).first
          end

          def self.find_by!(**opts) : self
            find_by(**opts) || raise ActiveRecord::RecordNotFound.new(
              "Couldn't find #{self} with #{opts.map { |k, v| "#{k}=#{v}" }.join(" ")}")
          end

          def self.find_each(batch_size : Int32 = 1000, & : self ->) : Nil
            all.find_each(batch_size) { |record| yield record }
          end

          def self.sum(col : String | Symbol) : Int64
            all.sum(col)
          end

          def self.average(col : String | Symbol) : PG::Numeric?
            all.average(col)
          end

          def self.minimum(col : String | Symbol) : Int64?
            all.minimum(col)
          end

          def self.maximum(col : String | Symbol) : Int64?
            all.maximum(col)
          end

          def self.group(*cols : String | Symbol) : ::ActiveRecord::Relation(self)
            all.group(*cols)
          end

          def self.having(condition : String, *args) : ::ActiveRecord::Relation(self)
            all.having(condition, *args)
          end

          def self.distinct(value : Bool = true) : ::ActiveRecord::Relation(self)
            all.distinct(value)
          end

          def self.joins(*names : String | Symbol) : ::ActiveRecord::Relation(self)
            all.joins(*names)
          end

          def self.left_outer_joins(*names : String | Symbol) : ::ActiveRecord::Relation(self)
            all.left_outer_joins(*names)
          end

          def self.reorder(*cols : String | Symbol) : ::ActiveRecord::Relation(self)
            all.reorder(*cols)
          end

          def self.reorder(**opts) : ::ActiveRecord::Relation(self)
            all.reorder(**opts)
          end

          def self.in_order_of(col : String | Symbol, values : Array(Int64 | Int32)) : ::ActiveRecord::Relation(self)
            all.in_order_of(col, values)
          end

          def self.none : ::ActiveRecord::Relation(self)
            all.none
          end

          def self.update_all(values : Hash(String, ActiveRecord::Value)) : Int64
            all.update_all(values)
          end

          def self.delete_all : Int64
            all.delete_all
          end

          def self.destroy_all : Array(self)
            all.destroy_all
          end

          def self.touch_all : Int64
            all.touch_all
          end

          def self.annotate(message : String) : ::ActiveRecord::Relation(self)
            all.annotate(message)
          end

          def self.explain : String
            all.explain
          end

          # Preloader for Relation#includes: has_many → one IN query, groups
          # the results onto the owners; belongs_to → one IN query, caches
          # each target (see ASSOCIATIONS registry).
          def self.__preload_assoc(name : String, records : Array(self)) : Nil
            case name
            {% for a in ActiveRecord::ASSOCIATIONS %}
              {% if a[0] == t.name.stringify %}
                {% if a[2] == "has_many" %}
              when {{a[1]}} then
                  ids = records.map(&.id).compact
                  unless ids.empty?
                    all = {{a[3]}}.where(%({{a[4]}} IN (#{ids.join(", ")}))).to_a
                    groups = {} of Int64 => Array(::ActiveRecord::Base)
                    all.each do |rec|
                      if (fkv = rec[{{a[4]}}].as?(Int64))
                        (groups[fkv] ||= [] of ::ActiveRecord::Base) << rec
                      end
                    end
                    records.each do |owner|
                      if oid = owner.id
                        # an empty group still marks the association loaded
                        owner.__set_loaded_assoc({{a[1]}}, groups[oid]? || [] of ::ActiveRecord::Base)
                      end
                    end
                  end
                {% elsif a[2] == "belongs_to" %}
              when {{a[1]}} then
                  fks = records.map { |o| o[{{a[4]}}].as?(Int64) }.compact.uniq
                  unless fks.empty?
                    targets = Hash(Int64, ::ActiveRecord::Base).new
                    {{a[3]}}.where(%("#{ {{a[3]}}.primary_key }" IN (#{fks.join(", ")}))).to_a.each do |rec|
                      targets[rec.id.not_nil!] = rec
                    end
                    records.each do |owner|
                      if (fkv = owner[{{a[4]}}].as?(Int64)) && (target = targets[fkv]?)
                        owner.__cache_assoc({{a[1]}}, target)
                      end
                    end
                  end
                {% elsif a[2] == "has_one_poly" %}
                  # Polymorphic has_one through (record_type, record_id):
                  # Action Text rich text records. One IN query, target
                  # cached per owner.
              when {{a[1]}} then
                  ids = records.map(&.id).compact
                  unless ids.empty?
                    targets = {} of Int64 => ::ActiveRecord::Base
                    {{a[3]}}.where(
                      "record_type = ? AND record_id IN (#{ids.join(", ")})",
                      {{t.name.stringify}}).to_a.each do |rec|
                      if (rid = rec["record_id"].as?(Int64))
                        targets[rid] = rec
                      end
                    end
                    records.each do |owner|
                      if (oid = owner.id) && (target = targets[oid]?)
                        owner.__cache_assoc({{a[1]}}, target)
                      end
                    end
                  end
                {% elsif a[2] == "as_one" %}
                  # Active Storage-style single attachment: one row in
                  # active_storage_attachments per (name, record_type,
                  # record_id). One IN query, target cached per owner.
              when {{a[1]}} then
                  ids = records.map(&.id).compact
                  unless ids.empty?
                    targets = {} of Int64 => ::ActiveRecord::Base
                    {{a[3]}}.where(
                      "record_type = ? AND record_id IN (#{ids.join(", ")}) AND name = ?",
                      {{t.name.stringify}}, {{a[5]}}).to_a.each do |rec|
                      if (rid = rec["record_id"].as?(Int64))
                        targets[rid] = rec
                      end
                    end
                    records.each do |owner|
                      if (oid = owner.id) && (target = targets[oid]?)
                        owner.__cache_assoc({{a[1]}}, target)
                      end
                    end
                  end
                {% end %}
              {% end %}
            {% end %}
            end
            nil
          end

          # Recursive preloader for dot-path includes
          # (Relation#includes(creator: :avatar_attachment) → the
          # "creator.avatar_attachment" path): preloads the head association
          # via __preload_assoc, collects the loaded child records and
          # dispatches the rest of the path on the child class (static
          # dispatch through the registry class — no virtual metaclass
          # needed). Polymorphic has_many owners' children are not walked.
          def self.__preload_path(segs : Array(String), records : Array(self)) : Nil
            return if records.empty? || segs.empty?
            head = segs.first
            rest = segs[1..]
            __preload_assoc(head, records)
            return if rest.empty?
            case head
            {% for a in ActiveRecord::ASSOCIATIONS %}
              {% if a[0] == t.name.stringify %}
                {% if a[2] == "has_many" %}
              when {{a[1]}} then
                  children = records.flat_map { |o| o.__loaded_assoc_records({{a[1]}}) || [] of ::ActiveRecord::Base }
                  unless children.empty?
                    {{a[3]}}.__preload_path(rest, children.map(&.as({{a[3]}})))
                  end
                {% elsif a[2] == "belongs_to" %}
              when {{a[1]}} then
                  children = records.compact_map { |o| o.__cached_assoc_record({{a[1]}}) }
                  unless children.empty?
                    {{a[3]}}.__preload_path(rest, children.map(&.as({{a[3]}})))
                  end
                {% elsif a[2] == "has_one_poly" || a[2] == "as_one" %}
              when {{a[1]}} then
                  children = records.compact_map { |o| o.__cached_assoc_record({{a[1]}}) }
                  unless children.empty?
                    {{a[3]}}.__preload_path(rest, children.map(&.as({{a[3]}})))
                  end
                {% end %}
              {% end %}
            {% end %}
            end
            nil
          end

          # Eager loading with a single LEFT OUTER JOIN query
          # (Relation#eager_load; also the includes+references switch).
          def self.__eager_load(name : String, wheres : Array(String),
                                 args : Array(DB::Any), orders : Array(String),
                                 limit : Int64?, offset : Int64?) : Array(self)
            case name
            {% for a in ActiveRecord::ASSOCIATIONS %}
              {% if a[0] == t.name.stringify && (a[2] == "has_many" || a[2] == "belongs_to") %}
              when {{a[1]}} then
                otable = table_name.gsub('"', "")
                ctable = {{a[3]}}.table_name.gsub('"', "")
                opk = primary_key
                cpk = {{a[3]}}.primary_key
                owner_names = __column_names
                child_names = {{a[3]}}.__column_names
                select_parts = owner_names.map { |c| %("#{otable}"."#{c}") } +
                               child_names.map { |c| %("#{ctable}"."#{c}" AS "c_#{c}") }
                {% if a[2] == "has_many" %}
                  join = %(LEFT OUTER JOIN "#{ctable}" ON "#{ctable}".{{a[4]}} = "#{otable}"."#{opk}")
                {% else %}
                  join = %(LEFT OUTER JOIN "#{ctable}" ON "#{ctable}"."#{cpk}" = "#{otable}".{{a[4]}})
                {% end %}
                counter = 0
                where_sql = wheres.map { |w| w.gsub(/\?/) { counter += 1; "$#{counter}" } }.join(" AND ")
                qorders = orders.map do |o|
                  o.starts_with?('"') && !o.includes?('.') ? %("#{otable}".#{o}) : o
                end
                sql = String.build do |io|
                  io << "SELECT " << select_parts.join(", ") << " FROM " << %("#{otable}")
                  io << " " << join
                  io << " WHERE " << where_sql unless where_sql.empty?
                  io << " ORDER BY " << qorders.join(", ") unless qorders.empty?
                  io << " LIMIT " << limit if limit
                  io << " OFFSET " << offset if offset
                end
                records = [] of self
                index = {} of Int64 => self
                groups = {} of Int64 => Array(::ActiveRecord::Base)
                ::ActiveRecord::Base.__session.query(sql, args: args) do |rs|
                  rs.each do
                    owner = __read_row(rs, owner_names)
                    child = {{a[3]}}.__read_row(rs, child_names)
                    if (oid = owner.id) && (dup = index[oid]?)
                      owner = dup
                    else
                      records << owner
                      index[oid] = owner if oid
                    end
                    if cid = child.id
                      {% if a[2] == "has_many" %}
                        if oid = owner.id
                          (groups[oid] ||= [] of ::ActiveRecord::Base) << child
                        end
                      {% else %}
                        owner.__cache_assoc({{a[1]}}, child)
                      {% end %}
                    end
                  end
                end
                {% if a[2] == "has_many" %}
                  records.each do |o|
                    if oid = o.id
                      o.__set_loaded_assoc({{a[1]}}, groups[oid]? || [] of ::ActiveRecord::Base)
                    end
                  end
                {% end %}
                records
              {% end %}
            {% end %}
            else
              all.to_a
            end
          end

          # Association name → target table name (includes+references switch).
          def self.__assoc_table(name : String) : String?
            case name
            {% for a in ActiveRecord::ASSOCIATIONS %}
              {% if a[0] == t.name.stringify && (a[2] == "has_many" || a[2] == "belongs_to") %}
              when {{a[1]}} then {{a[3]}}.table_name
              {% end %}
            {% end %}
            else
              nil
            end
          end

          # Association reflections (runtime subset of Rails'
          # reflect_on_all_associations): {name, kind, klass, foreign_key}.
          # Polymorphic and through associations are not included.
          def self.__associations : Array(NamedTuple(name: String, kind: String, klass: ::ActiveRecord::Base.class, foreign_key: String))
            arr = [] of NamedTuple(name: String, kind: String, klass: ::ActiveRecord::Base.class, foreign_key: String)
            {% for a in ActiveRecord::ASSOCIATIONS %}
              {% if a[0] == t.name.stringify && (a[2] == "has_many" || a[2] == "belongs_to") %}
            arr << {name: {{a[1]}}, kind: {{a[2]}}, klass: {{a[3]}}, foreign_key: {{a[4]}}}
              {% end %}
            {% end %}
            arr
          end

          # String-only variant of __associations (see AssocSpec): safe for
          # virtual metaclass dispatch.
          def self.__assoc_specs : Array(::ActiveRecord::AssocSpec)
            arr = [] of ::ActiveRecord::AssocSpec
            {% for a in ActiveRecord::ASSOCIATIONS %}
              {% if a[0] == t.name.stringify && (a[2] == "has_many" || a[2] == "belongs_to") %}
            arr << {name: {{a[1]}}, kind: {{a[2]}}, table: {{a[3]}}.table_name,
                    pk: {{a[3]}}.primary_key, foreign_key: {{a[4]}}}
              {% end %}
            {% end %}
            arr
          end

          # STI seam (CanCan StiDetector/StiNormalizer): false when this
          # class is single-table-inherited from another model.
          def self.descends_from_active_record? : Bool
            {{ super_is_model ? false : true }}
          end

          # The STI parent model class, or nil when not STI.
          def self.__sti_parent_class : Union(::ActiveRecord::Base.class, Nil)
            {% if super_is_model %}
            {{ t.superclass }}
            {% else %}
            nil
            {% end %}
          end

          # enum emission (getter overrides the skipped codegen one);
          # e[2] is an ArrayLiteral of {key, value} tuples
          {% for e in ActiveRecord::ENUMS %}
            {% if e[0] == t.name.stringify %}
              def {{e[1].id}} : String?
                v = @{{e[1].id}}
                return nil if v.nil?
                case v
                {% for pair in e[2] %}
                when {{pair[1]}} then {{pair[0].stringify}}
                {% end %}
                # unmapped DB values read as nil (oracle-verified Rails 8.1:
                # junk enum rows don't raise on load)
                else nil
                end
              end

              def {{e[1].id}}=(value : String)
                case value
                {% for pair in e[2] %}
                when {{pair[0].stringify}} then @{{e[1].id}} = {{pair[1]}}
                {% end %}
                else
                  raise ArgumentError.new("invalid value #{value} for {{e[1].id}}")
                end
              end

              def {{e[1].id}}=(value : Symbol)
                self.{{e[1].id}} = value.to_s
              end

              # String-valued enums (Rails' %w[...].index_by(&:itself)) map
              # key => string; int enums keep the Int64 mapping.
              {% int_vals = e[2].map { |tup| tup[1] }.first.is_a?(NumberLiteral) %}
              {% pfx = nil %}
              {% for p in ActiveRecord::ENUM_PREFIXES %}
                {% if p[0] == t.name.stringify && p[1] == e[1] %}{% pfx = p[2] %}{% end %}
              {% end %}
              def self.{{(e[1].id.stringify + (e[1].id.stringify.ends_with?("s") ? "es" : "s")).id}} : Hash(String, {{ (int_vals ? "Int64" : "String").id }})
                { {% for pair in e[2] %}{{pair[0].stringify}} => {{ int_vals ? "#{pair[1]}_i64".id : pair[1] }}, {% end %} }
              end

              {% for pair in e[2] %}
                {% k = pair[0] %}
                {% v = pair[1] %}
                {% mname = (pfx ? (pfx.id.stringify + "_" + k.stringify) : k.stringify).id %}
                def {{mname}}? : Bool
                  @{{e[1].id}} == {{v}}
                end

                def {{mname}}! : Bool
                  self.{{e[1].id}} = {{k.stringify}}
                  save
                end

                def self.{{mname}} : ::ActiveRecord::Relation(self)
                  all.where({{e[1].id.stringify}}: {{v}})
                end
              {% end %}
            {% end %}
          {% end %}

          # attribute aliases (where(title:) resolves to the real column)
          {% model_aliases = ActiveRecord::ALIASES.select { |a| a[0] == t.name.stringify } %}
          {% unless model_aliases.empty? %}
            def self.__resolve_column(name : String) : String
              case name
              {% for a in model_aliases %}
              when {{a[1]}} then {{a[2]}}
              {% end %}
              else name
              end
            end
          {% end %}

          # --- hook runners assembled from prefixed methods -----------------
          def __run_validations(context : Symbol) : Nil
            {% for m in t.methods %}
              {% if m.name.stringify.starts_with?("validation__") %}{{ m.name.id }}(context){% end %}
            {% end %}
            nil
          end

          def __run_before_validation : Bool
            {% for m in t.methods %}
              {% if m.name.stringify.starts_with?("before_validation__cb_") %}
                return false unless {{ m.name.id }}
              {% end %}
            {% end %}
            true
          end

          def __run_before_save : Bool
            {% for m in t.methods %}
              {% if m.name.stringify.starts_with?("before_save__cb_") %}
                return false unless {{ m.name.id }}
              {% end %}
            {% end %}
            true
          end

          def __run_before_create : Bool
            {% for m in t.methods %}
              {% if m.name.stringify.starts_with?("before_create__cb_") %}
                return false unless {{ m.name.id }}
              {% end %}
            {% end %}
            true
          end

          def __run_before_update : Bool
            {% for m in t.methods %}
              {% if m.name.stringify.starts_with?("before_update__cb_") %}
                return false unless {{ m.name.id }}
              {% end %}
            {% end %}
            true
          end

          def __run_before_destroy : Nil
            {% for m in t.methods %}
              {% if m.name.stringify.starts_with?("before_destroy__cb_") %}{{ m.name.id }}{% end %}
            {% end %}
            nil
          end

          def __run_after_create : Nil
            {% for m in t.methods %}
              {% if m.name.stringify.starts_with?("after_create__cb_") %}{{ m.name.id }}{% end %}
            {% end %}
            nil
          end

          def __run_after_update : Nil
            {% for m in t.methods %}
              {% if m.name.stringify.starts_with?("after_update__cb_") %}{{ m.name.id }}{% end %}
            {% end %}
            nil
          end

          def __run_after_save : Nil
            {% for m in t.methods %}
              {% if m.name.stringify.starts_with?("after_save__cb_") %}{{ m.name.id }}{% end %}
            {% end %}
            nil
          end

          def __run_after_destroy : Nil
            {% for m in t.methods %}
              {% if m.name.stringify.starts_with?("after_destroy__cb_") %}{{ m.name.id }}{% end %}
            {% end %}
            nil
          end

          def __run_dependents : Nil
            {% for m in t.methods %}
              {% if m.name.stringify.starts_with?("dependent__cb_") %}{{ m.name.id }}{% end %}
            {% end %}
            nil
          end

          def __run_after_commit(event : Symbol) : Nil
            {% for m in t.methods %}
              {% if m.name.stringify.starts_with?("after_commit__cb_") %}{{ m.name.id }}(event){% end %}
            {% end %}
            nil
          end

          def __run_after_rollback(event : Symbol) : Nil
            {% for m in t.methods %}
              {% if m.name.stringify.starts_with?("after_rollback__cb_") %}{{ m.name.id }}(event){% end %}
            {% end %}
            nil
          end

          def __run_after_initialize : Nil
            {% for m in t.methods %}
              {% if m.name.stringify.starts_with?("after_initialize__cb_") %}{{ m.name.id }}{% end %}
            {% end %}
            nil
          end

          def __run_after_find : Nil
            {% for m in t.methods %}
              {% if m.name.stringify.starts_with?("after_find__cb_") %}{{ m.name.id }}{% end %}
            {% end %}
            nil
          end

          def __run_after_touch : Nil
            {% for m in t.methods %}
              {% if m.name.stringify.starts_with?("after_touch__cb_") %}{{ m.name.id }}{% end %}
            {% end %}
            nil
          end

          # Around-callback chains: depth-dispatch walking (the Nth callback
          # receives a block continuing with the N+1th; `else` runs action).
          {% for kind in ["around_save", "around_create", "around_update", "around_destroy"] %}
            {% prefix = kind.id.stringify + "__cb_" %}
            {% chain = t.methods.select { |m| m.name.stringify.starts_with?(prefix) } %}
            def __wrap_{{kind.id}}(depth : Int32, action : Proc(Nil)) : Nil
              case depth
              {% for i in 0...chain.size %}
                when {{i}} then {{ chain[i].name.id }} { __wrap_{{kind.id}}({{i + 1}}, action) }
              {% end %}
              else
                action.call
              end
            end
          {% end %}
        end
      {% end %}
    {% end %}

    # Table → association specs (CanCan SQL builder; STI subclasses share
    # the parent model's table and the first registered model wins).
    module ::ActiveRecord
      def self.__assoc_specs_by_table(table : String) : Array(AssocSpec)
        case table
        {% for t in ActiveRecord::MODELS %}
          {% unless t.abstract? %}
        when ::{{ t.stringify.id }}.table_name then ::{{ t.stringify.id }}.__assoc_specs
          {% end %}
        {% end %}
        else
          [] of AssocSpec
        end
      end
    end
  end
end
