# Associations: belongs_to / has_many / has_one (+ dependent: :destroy),
# through:, polymorphic (as:), has_and_belongs_to_many, counter_cache:,
# touch:, inverse_of (owner cache captured at build time), association
# callbacks (before_add/after_add/before_remove/after_remove).
#
# Notes: associated model class is resolved by convention
# (`comments` → `Comment`); `foreign_key:`/`class_name:` override it.
# through:/HABTM scopes use subqueries (same results as Rails' joins).
# Polymorphic belongs_to dispatches over a compile-time registry of
# `as:` owners (no runtime constantize in Crystal).

module ActiveRecord
  # Compile-time association registry: {class, name, kind, klass, fk}.
  ASSOCIATIONS = [] of Nil

  # Polymorphic owners ({as-name, type value, owner TypeNode}) and
  # polymorphic belongs_to users ({class, assoc name}).
  POLY_OWNERS = [] of Nil
  POLY_USERS = [] of Nil

  # Proxy returned by has_many: query methods + build/create/<<.
  struct CollectionProxy(T)
    include Enumerable(T)

    attr_reader owner_id : Int64?
    attr_reader foreign_key : String
    attr_reader model : T.class

    # through / polymorphic / HABTM proxies wrap a preset scope.
    @preset : Relation(T)? = nil
    # Owner object for inverse_of (set at build/<< time).
    @owner : Base? = nil
    @inverse_name : String? = nil
    # HABTM join table state (empty strings when not HABTM).
    @join_table : String? = nil
    @join_owner_col : String = ""
    @join_target_col : String = ""
    # Preloaded records (Relation#includes): query methods serve from memory.
    @loaded : Array(T)? = nil
    # autosave: true has_many — the owner collecting built children, and
    # the association name to track them under.
    @autosave_owner : Base? = nil
    @autosave_name : String? = nil
    # Association callbacks (Rails before_add/after_add/before_remove/
    # after_remove): procs of (owner, record), attached at proxy build
    # time by the association macros. Informational — Rails' throw(:abort)
    # halting on before-callbacks is not ported.
    @cb_owner : Base? = nil
    @before_add_cbs : Array(Proc(Base, T, Nil)) = [] of Proc(Base, T, Nil)
    @after_add_cbs : Array(Proc(Base, T, Nil)) = [] of Proc(Base, T, Nil)
    @before_remove_cbs : Array(Proc(Base, T, Nil)) = [] of Proc(Base, T, Nil)
    @after_remove_cbs : Array(Proc(Base, T, Nil)) = [] of Proc(Base, T, Nil)

    def initialize(@model : T.class, @owner_id : Int64?, @foreign_key : String)
    end

    def initialize(@model : T.class, @owner_id : Int64?, @foreign_key : String,
                   @owner : Base, @inverse_name : String?)
    end

    def initialize(@model : T.class, @preset : Relation(T))
      @owner_id = nil
      @foreign_key = ""
    end

    def initialize(@model : T.class, @loaded : Array(T))
      @owner_id = nil
      @foreign_key = ""
    end

    # autosave proxy wiring: serve from the in-memory target list (set via
    # __init_loaded) and track built records on the owner.
    def __init_autosave(owner : Base, name : String) : self
      @autosave_owner = owner
      @autosave_name = name
      self
    end

    # Serve query methods from a preloaded list while keeping owner_id/FK
    # (build/create/<< still assign the foreign key).
    def __init_loaded(records : Array(T)) : self
      @loaded = records
      self
    end

    def __init_habtm(join_table : String, owner_col : String, target_col : String,
                     owner_id : Int64?) : self
      @join_table = join_table
      @join_owner_col = owner_col
      @join_target_col = target_col
      @owner_id = owner_id
      self
    end

    # Attach association callbacks (owner-side method calls compiled into
    # procs by the association macros). Each argument accepts a single
    # proc or an array; nil leaves that hook empty.
    def __init_callbacks(owner : Base,
                         before_add : (Proc(Base, T, Nil) | Array(Proc(Base, T, Nil)))? = nil,
                         after_add : (Proc(Base, T, Nil) | Array(Proc(Base, T, Nil)))? = nil,
                         before_remove : (Proc(Base, T, Nil) | Array(Proc(Base, T, Nil)))? = nil,
                         after_remove : (Proc(Base, T, Nil) | Array(Proc(Base, T, Nil)))? = nil) : self
      @cb_owner = owner
      @before_add_cbs = cb_list(before_add)
      @after_add_cbs = cb_list(after_add)
      @before_remove_cbs = cb_list(before_remove)
      @after_remove_cbs = cb_list(after_remove)
      self
    end

    private def cb_list(cbs : (Proc(Base, T, Nil) | Array(Proc(Base, T, Nil)))?) : Array(Proc(Base, T, Nil))
      case cbs
      when Proc(Base, T, Nil)             then [cbs]
      when Array(Proc(Base, T, Nil)) then cbs
      else
        [] of Proc(Base, T, Nil)
      end
    end

    private def fire_cbs(list : Array(Proc(Base, T, Nil)), record : T) : Nil
      if owner = @cb_owner
        list.each { |cb| cb.call(owner, record) }
      end
    end

    private def scope : Relation(T)
      if preset = @preset
        preset
      elsif oid = @owner_id
        @model.where(%("#{@foreign_key}" = ?), oid)
      else
        @model.all
      end
    end

    def each(& : T ->) : Nil
      if l = @loaded
        l.each { |r| yield r }
      else
        scope.each { |r| yield r }
      end
    end

    def count : Int64 | Hash(ActiveRecord::Value, Int64)
      if l = @loaded
        l.size.to_i64
      else
        scope.count
      end
    end

    def size : Int64 | Hash(ActiveRecord::Value, Int64)
      count
    end

    def empty? : Bool
      if l = @loaded
        l.empty?
      else
        !scope.exists?
      end
    end

    def ids : Array(Int64)
      if l = @loaded
        l.map(&.id.not_nil!)
      else
        scope.ids
      end
    end

    def pluck(col : String | Symbol) : Array(Value)
      if l = @loaded
        l.map { |r| r[col.to_s] }
      else
        scope.pluck(col)
      end
    end

    def order(*cols : String | Symbol) : Relation(T)
      scope.order(*cols)
    end

    def where(condition : String, *args) : Relation(T)
      scope.where(condition, *args)
    end

    def build(values : Hash(String, Value) = {} of String => Value) : T
      record = @model.new
      record.assign_attributes(values)
      record.assign_attributes({@foreign_key => @owner_id.as(Value)})
      if (o = @owner) && (n = @inverse_name)
        record.__cache_assoc(n, o)
      end
      if (o = @autosave_owner) && (n = @autosave_name)
        # Rails: build appends to the (loaded) association target — the
        # record rides along until the owner's autosave hooks save it.
        o.__autosave_track(n, record)
        @loaded.try(&.<<(record))
      end
      record
    end

    def create(values : Hash(String, Value) = {} of String => Value) : T
      record = build(values)
      record.save
      record
    end

    def create!(values : Hash(String, Value) = {} of String => Value) : T
      record = build(values)
      record.save || raise RecordInvalid.new(record)
      record
    end

    def <<(record : T) : self
      fire_cbs(@before_add_cbs, record)
      if (jt = @join_table)
        if oid = @owner_id
          ::ActiveRecord::Base.__session.exec(
            %(INSERT INTO "#{jt}" ("#{@join_owner_col}", "#{@join_target_col}") VALUES ($1, $2)),
            args: [oid, record.id.not_nil!])
        end
      else
        record.assign_attributes({@foreign_key => @owner_id.as(Value)})
        if (o = @owner) && (n = @inverse_name)
          record.__cache_assoc(n, o)
        end
        record.save
      end
      fire_cbs(@after_add_cbs, record)
      self
    end

    def concat(records : Array(T)) : self
      records.each { |r| self << r }
      self
    end

    def include?(record : T) : Bool
      !record.id.nil? && scope.where(%q("id" = ?), record.id.not_nil!).exists?
    end

    # Destroys the record outright (Rails CollectionProxy#destroy).
    def destroy(record : T) : Array(T)
      if include?(record)
        fire_cbs(@before_remove_cbs, record)
        record.destroy
        fire_cbs(@after_remove_cbs, record)
        [record]
      else
        [] of T
      end
    end

    # Rails delete: HABTM removes join rows; otherwise nullifies the FK
    # without callbacks (the FK column must be nullable — our oracle
    # schema's NOT NULL makes this raise a DB error, mirroring
    # activerecord's NotNullViolation).
    def delete(*records : T) : Array(T)
      deleted = [] of T
      records.each do |record|
        next unless record.id && @owner_id
        fire_cbs(@before_remove_cbs, record)
        if jt = @join_table
          ::ActiveRecord::Base.__session.exec(
            %(DELETE FROM "#{jt}" WHERE "#{@join_owner_col}" = $1 AND "#{@join_target_col}" = $2),
            args: [@owner_id.not_nil!, record.id.not_nil!])
        else
          ::ActiveRecord::Base.__session.exec(
            %(UPDATE #{@model.quoted_table_name} SET "#{@foreign_key}" = NULL WHERE "#{@model.primary_key}" = $1),
            args: [record.id.not_nil!])
        end
        fire_cbs(@after_remove_cbs, record)
        deleted << record
      end
      deleted
    end

    # Rails replace: removes (delete/nullify) records not in the list,
    # saves the new ones.
    def replace(records : Array(T)) : Nil
      keep_ids = records.map { |r| r.id }.compact
      scope.where(%q("id" NOT IN (#{keep_ids.empty? ? "0" : keep_ids.join(", ")}))).to_a.each do |old|
        delete(old)
      end
      records.each do |r|
        self << r unless r.persisted?
      end
    end

    def destroy_all : Nil
      scope.each(&.destroy)
    end

    def delete_all : Nil
      if oid = @owner_id
        ::ActiveRecord::Base.__session.exec(
          %(DELETE FROM #{@model.quoted_table_name} WHERE "#{@foreign_key}" = $1),
          args: [oid])
      end
    end
  end

  class Base
    # Inverse-of cache: owner records captured at association build time
    # (belongs_to getters consult it before hitting the database) — also
    # used by preloading (Relation#includes).
    @assoc_cache = {} of String => Base

    # Preloaded has_many lists, keyed by association name (includes).
    @loaded_assocs = {} of String => Array(Base)

    def __cache_assoc(name : String, record : Base) : Nil
      @assoc_cache[name] = record
    end

    def __set_loaded_assoc(name : String, records : Array(Base)) : Nil
      @loaded_assocs[name] = records
    end

    # Preloaded has_many target (nil when not preloaded) — used by the
    # recursive dot-path preloader to walk nested includes levels.
    def __loaded_assoc_records(name : String) : Array(Base)?
      @loaded_assocs[name]?
    end

    # Cached belongs_to / has_one target (nil when not cached) — inverse-of
    # cache reader for the dot-path preloader.
    def __cached_assoc_record(name : String) : Base?
      @assoc_cache[name]?
    end

    # autosave: true has_many — children built through the association
    # proxy are appended to the loaded target so the owner's validation /
    # save hooks see them (Rails keeps them in the association target).
    def __autosave_track(name : String, record : Base) : Nil
      if (list = @loaded_assocs[name]?)
        list << record
      else
        list = [record] of Base
        @loaded_assocs[name] = list
      end
    end

    macro belongs_to(name, foreign_key = nil, class_name = nil, optional = true,
                     counter_cache = nil, touch = false, polymorphic = false,
                     inverse_of = nil, autosave = false)
      {% fk = (foreign_key || "#{name.id}_id").id %}
      {% klass = (class_name || name.id.stringify.capitalize).id %}
      {% ActiveRecord::ASSOCIATIONS << { @type.name.stringify, name.id.stringify, polymorphic ? "belongs_to_poly" : "belongs_to", klass, fk.stringify } %}

      {% if polymorphic %}
        {% if autosave %}
          {% raise "belongs_to #{name}: autosave is not supported on polymorphic associations" %}
        {% end %}
        {% ActiveRecord::POLY_USERS << { @type.name.stringify, name.id.stringify } %}
        # getter/setter emitted by the codegen in base.cr `macro finished`:
        # the dispatch needs ALL `as:` owners registered program-wide.
      {% else %}
        {% if autosave %}
          # autosave: the association is cached on read/assign (Rails'
          # loaded target); a new/dirty parent is validated together with
          # this record and saved in before_save (so the FK is set before
          # the INSERT), aborting the save when it fails.
          def {{name.id}} : {{klass}}?
            if (cached = @assoc_cache[{{name.id.stringify}}]?)
              return cached.as({{klass}})
            end
            if (oid = {{fk.id}}) && (rec = {{klass}}.find?(oid))
              @assoc_cache[{{name.id.stringify}}] = rec
              rec
            else
              nil
            end
          end

          def {{name.id}}=(record : {{klass}})
            @assoc_cache[{{name.id.stringify}}] = record
            @{{fk.id}} = record.id
            record
          end

          # Rails validate_belongs_to_association: only new/dirty records
          # (changed_for_autosave?); child errors surface as
          # "<assoc>.<attribute>" NestedErrors on this record.
          def validation__autosave_{{name.id}}(context : Symbol) : Nil
            if (cached = @assoc_cache[{{name.id.stringify}}]?)
              rec = cached.as({{klass}})
              if !rec.destroyed? && (rec.new_record? || rec.changed?)
                unless rec.valid?(context)
                  rec.errors.each do |e|
                    errors.add({{name.id.stringify}} + "." + e.attribute,
                                e.message || "is invalid", type: e.type)
                  end
                end
              end
            end
            nil
          end

          # Rails save_belongs_to_association (before_save; save(validate:)
          # is false because validation already ran with the owner).
          def before_save__cb_autosave_{{name.id}} : Bool
            if (cached = @assoc_cache[{{name.id.stringify}}]?)
              rec = cached.as({{klass}})
              if !rec.destroyed? && (rec.new_record? || rec.changed?)
                saved = rec.save(validate: false)
                if saved && (rid = rec.id) && {{fk.id}} != rid
                  @{{fk.id}} = rid
                end
                return false unless saved
              end
            end
            true
          end
        {% else %}
          def {{name.id}} : {{klass}}?
            if (cached = @assoc_cache[{{name.id.stringify}}]?)
              return cached.as({{klass}})
            end
            {{fk.id}}.nil? ? nil : {{klass}}.find?({{fk.id}}.not_nil!)
          end

          # Rails: assigning the associated object sets the FK (unsaved).
          def {{name.id}}=(record : {{klass}})
            @{{fk.id}} = record.id
            record
          end
        {% end %}

        def build_{{name.id}}(values : Hash(String, ::ActiveRecord::Value) = {} of String => ::ActiveRecord::Value) : {{klass}}
          record = {{klass}}.new
          record.assign_attributes(values)
          record
        end

        def create_{{name.id}}(values : Hash(String, ::ActiveRecord::Value) = {} of String => ::ActiveRecord::Value) : {{klass}}
          record = build_{{name.id}}(values)
          record.save
          @{{fk.id}} = record.id
          record
        end

        def create_{{name.id}}!(values : Hash(String, ::ActiveRecord::Value) = {} of String => ::ActiveRecord::Value) : {{klass}}
          record = build_{{name.id}}(values)
          record.save || raise RecordInvalid.new(record)
          @{{fk.id}} = record.id
          record
        end

        {% if counter_cache %}
          # counter_cache: the through-association's count column is bumped
          # on create and decremented on destroy (Rails also rebalances on
          # FK change — not ported).
          {% cc = counter_cache.id.stringify %}
          def after_create__cb_counter_cache : Nil
            if (oid = {{fk.id}})
              ::ActiveRecord::Base.__session.exec(
                %(UPDATE "#{ {{klass}}.table_name }" SET {{cc}} = {{cc}} + 1 WHERE "#{ {{klass}}.primary_key }" = $1),
                args: [oid])
            end
            nil
          end

          def before_destroy__cb_counter_cache : Nil
            if (oid = {{fk.id}}) && !new_record?
              ::ActiveRecord::Base.__session.exec(
                %(UPDATE "#{ {{klass}}.table_name }" SET {{cc}} = {{cc}} - 1 WHERE "#{ {{klass}}.primary_key }" = $1),
                args: [oid])
            end
            nil
          end
        {% end %}

        {% if touch %}
          # touch: the parent's updated_at is bumped on save and destroy.
          def after_save__cb_touch_assoc : Nil
            if (oid = {{fk.id}})
              {{klass}}.find?(oid).try(&.touch)
            end
            nil
          end

          def after_destroy__cb_touch_assoc : Nil
            if (oid = {{fk.id}})
              {{klass}}.find?(oid).try(&.touch)
            end
            nil
          end
        {% end %}
      {% end %}
    end

    macro has_many(name, dependent = nil, foreign_key = nil, class_name = nil,
                   through = nil, source = nil, inverse_of = nil, as_name = nil,
                   autosave = false, before_add = nil, after_add = nil,
                   before_remove = nil, after_remove = nil)
      {% owner_base = @type.name.split("::").last.downcase %}
      {% owner_fk = (foreign_key || (owner_base + "_id")) %}
      {% klass = (class_name || name.id.stringify.capitalize.gsub(/s$/, "")).id %}

      {% if through %}
        # has_many :xs, through: :ys — resolved from the registry: the
        # middle association must be declared earlier on the same class.
        {% mid = nil %}
        {% for a in ActiveRecord::ASSOCIATIONS %}
          {% if a[0] == @type.name.stringify && a[1] == through.id.stringify %}{% mid = a %}{% end %}
        {% end %}
        {% raise "has_many #{name}: through association #{through} not found on #{@type} (declare it first)" unless mid %}
        {% mid_klass = mid[3] %}
        {% mid_owner_fk = mid[4] %}
        {% src_klass = source ? source.id : (name.id.stringify.gsub(/s\z/, "").split("_").map(&.capitalize).join("")).id %}

        def {{name.id}} : ::ActiveRecord::CollectionProxy({{src_klass}})
          raise ::ActiveRecord::StrictLoadingViolationError.new(
            "{{@type}} is marked for strict_loading") if strict_loading?
          mid_table = {{mid_klass}}.table_name
          mid_fk = ::ActiveRecord::Migrations.singularize(mid_table) + "_id"
          sql = %("#{mid_fk}" IN (SELECT "id" FROM "#{mid_table}" WHERE {{mid_owner_fk}} = ?))
          ::ActiveRecord::CollectionProxy({{src_klass}}).new({{src_klass}}, {{src_klass}}.where(sql, @id || -1_i64))
        end

        def {{(name.id.stringify.gsub(/s$/, "") + "_ids").id}} : Array(Int64)
          {{name.id}}.ids
        end
      {% elsif as_name %}
        {% ActiveRecord::POLY_OWNERS << { as_name.id.stringify, @type.name.stringify, @type } %}
        {% ActiveRecord::ASSOCIATIONS << { @type.name.stringify, name.id.stringify, "has_many_poly", klass, (as_name.id.stringify + "_id") } %}

        def {{name.id}} : ::ActiveRecord::CollectionProxy({{klass}})
          raise ::ActiveRecord::StrictLoadingViolationError.new(
            "{{@type}} is marked for strict_loading") if strict_loading?
          scope = {{klass}}.where(%("{{as_name.id}}_id" = ?), @id)
            .where(%("{{as_name.id}}_type" = ?), {{@type.name.stringify}})
          ::ActiveRecord::CollectionProxy({{klass}}).new({{klass}}, scope)
        end

        def {{(name.id.stringify.gsub(/s$/, "") + "_ids").id}} : Array(Int64)
          {{name.id}}.ids
        end
      {% else %}
        {% ActiveRecord::ASSOCIATIONS << { @type.name.stringify, name.id.stringify, "has_many", klass, owner_fk } %}
        # inverse belongs_to name on the target: explicit inverse_of or the
        # registry match by foreign key (target class must be declared
        # earlier for the automatic form).
        {% inv_name = inverse_of ? inverse_of.id.stringify : nil %}
        {% unless inv_name %}
          {% for a in ActiveRecord::ASSOCIATIONS %}
            {% if a[0] == klass.stringify && a[2] == "belongs_to" && a[4] == owner_fk %}
              {% inv_name = a[1] %}
            {% end %}
          {% end %}
        {% end %}

        {% if autosave %}
          # autosave: true — the target lives in memory (Rails' loaded
          # association target): the first access loads it, subsequent
          # accesses serve the SAME records so mutations stick and are
          # picked up by the validation/save hooks below.
          def {{name.id}} : ::ActiveRecord::CollectionProxy({{klass}})
            raise ::ActiveRecord::StrictLoadingViolationError.new(
              "{{@type}} is marked for strict_loading") if strict_loading?
            unless (loaded = @loaded_assocs[{{name.id.stringify}}]?)
              fk_name = {{owner_fk}}
              loaded = {{klass}}.where(%("#{fk_name}" = ?), @id || -1_i64).to_a
                .map(&.as(::ActiveRecord::Base))
              __set_loaded_assoc({{name.id.stringify}}, loaded)
            end
            proxy = ::ActiveRecord::CollectionProxy({{klass}}).new(
              {{klass}}, @id, {{owner_fk}}, self, {{inv_name || "nil"}})
            proxy.__init_loaded(loaded.map(&.as({{klass}})))
            proxy.__init_autosave(self, {{name.id.stringify}})
            {% if before_add || after_add || before_remove || after_remove %}
              proxy.__init_callbacks(self,
                {% if before_add %} [ {% for m in (before_add.is_a?(ArrayLiteral) ? before_add : [before_add]) %} ->(o : ::ActiveRecord::Base, r : {{klass}}) { o.as({{@type}}).{{m.id}}(r); nil }, {% end %} ] of ::Proc(::ActiveRecord::Base, {{klass}}, Nil) {% else %} nil {% end %},
                {% if after_add %} [ {% for m in (after_add.is_a?(ArrayLiteral) ? after_add : [after_add]) %} ->(o : ::ActiveRecord::Base, r : {{klass}}) { o.as({{@type}}).{{m.id}}(r); nil }, {% end %} ] of ::Proc(::ActiveRecord::Base, {{klass}}, Nil) {% else %} nil {% end %},
                {% if before_remove %} [ {% for m in (before_remove.is_a?(ArrayLiteral) ? before_remove : [before_remove]) %} ->(o : ::ActiveRecord::Base, r : {{klass}}) { o.as({{@type}}).{{m.id}}(r); nil }, {% end %} ] of ::Proc(::ActiveRecord::Base, {{klass}}, Nil) {% else %} nil {% end %},
                {% if after_remove %} [ {% for m in (after_remove.is_a?(ArrayLiteral) ? after_remove : [after_remove]) %} ->(o : ::ActiveRecord::Base, r : {{klass}}) { o.as({{@type}}).{{m.id}}(r); nil }, {% end %} ] of ::Proc(::ActiveRecord::Base, {{klass}}, Nil) {% else %} nil {% end %})
            {% end %}
          end
        {% else %}
          def {{name.id}} : ::ActiveRecord::CollectionProxy({{klass}})
            raise ::ActiveRecord::StrictLoadingViolationError.new(
              "{{@type}} is marked for strict_loading") if strict_loading?
            if (loaded = @loaded_assocs[{{name.id.stringify}}]?)
              return ::ActiveRecord::CollectionProxy({{klass}}).new(
                {{klass}}, loaded.map(&.as({{klass}})))
            end
            proxy = ::ActiveRecord::CollectionProxy({{klass}}).new({{klass}}, @id, {{owner_fk}}, self, {{inv_name || "nil"}})
            {% if before_add || after_add || before_remove || after_remove %}
              proxy.__init_callbacks(self,
                {% if before_add %} [ {% for m in (before_add.is_a?(ArrayLiteral) ? before_add : [before_add]) %} ->(o : ::ActiveRecord::Base, r : {{klass}}) { o.as({{@type}}).{{m.id}}(r); nil }, {% end %} ] of ::Proc(::ActiveRecord::Base, {{klass}}, Nil) {% else %} nil {% end %},
                {% if after_add %} [ {% for m in (after_add.is_a?(ArrayLiteral) ? after_add : [after_add]) %} ->(o : ::ActiveRecord::Base, r : {{klass}}) { o.as({{@type}}).{{m.id}}(r); nil }, {% end %} ] of ::Proc(::ActiveRecord::Base, {{klass}}, Nil) {% else %} nil {% end %},
                {% if before_remove %} [ {% for m in (before_remove.is_a?(ArrayLiteral) ? before_remove : [before_remove]) %} ->(o : ::ActiveRecord::Base, r : {{klass}}) { o.as({{@type}}).{{m.id}}(r); nil }, {% end %} ] of ::Proc(::ActiveRecord::Base, {{klass}}, Nil) {% else %} nil {% end %},
                {% if after_remove %} [ {% for m in (after_remove.is_a?(ArrayLiteral) ? after_remove : [after_remove]) %} ->(o : ::ActiveRecord::Base, r : {{klass}}) { o.as({{@type}}).{{m.id}}(r); nil }, {% end %} ] of ::Proc(::ActiveRecord::Base, {{klass}}, Nil) {% else %} nil {% end %})
            {% end %}
            proxy
          end
        {% end %}

        def {{(name.id.stringify.gsub(/s$/, "") + "_ids").id}} : Array(Int64)
          {{name.id}}.ids
        end

        {% if autosave %}
          # Rails validate_collection_association: new/dirty target records
          # are validated with the owner; their errors surface as
          # "<assoc>.<attribute>" NestedErrors on this record.
          def validation__autosave_{{name.id}}(context : Symbol) : Nil
            if (records = @loaded_assocs[{{name.id.stringify}}]?)
              records.each do |rec|
                next if rec.destroyed?
                child = rec.as({{klass}})
                next unless child.new_record? || child.changed?
                unless child.valid?(context)
                  child.errors.each do |e|
                    errors.add({{name.id.stringify}} + "." + e.attribute,
                                e.message || "is invalid", type: e.type)
                  end
                end
              end
            end
            nil
          end

          # Rails save_collection_association — after_create/after_update
          # (NOT after_save: children added in after_create/after_update
          # would be saved twice). New records are inserted with the owner's
          # FK, dirty ones saved, both with validate: false (already
          # validated with the owner).
          def after_create__cb_autosave_{{name.id}} : Nil
            __autosave_save_{{name.id}}
            nil
          end

          def after_update__cb_autosave_{{name.id}} : Nil
            __autosave_save_{{name.id}}
            nil
          end

          def __autosave_save_{{name.id}} : Nil
            return unless (records = @loaded_assocs[{{name.id.stringify}}]?)
            records.each do |rec|
              next if rec.destroyed?
              child = rec.as({{klass}})
              next unless child.new_record? || child.changed?
              if child.new_record?
                child.{{owner_fk.id}} = @id
              end
              child.save(validate: false)
            end
            nil
          end
        {% end %}

        {% if dependent == :destroy %}
          __dependent_destroy {{name.id}}.destroy_all
        {% elsif dependent == :delete_all %}
          __dependent_destroy {{name.id}}.delete_all
        {% end %}
      {% end %}
    end

    # accepts_nested_attributes_for :n_posts, allow_destroy: true,
    #   reject_if: :all_blank — Rails autosave semantics: assignment only
    # builds/updates/marks records; children are validated together with
    # the parent (child errors surface as "N posts <message>") and saved
    # or destroyed in an after_save hook.
    macro accepts_nested_attributes_for(name, allow_destroy = false, reject_if = nil)
      {% nested = nil %}
      {% for a in ActiveRecord::ASSOCIATIONS %}
        {% if a[0] == @type.name.stringify && a[1] == name.id.stringify && a[2] == "has_many" %}
          {% nested = a %}
        {% end %}
      {% end %}
      {% raise "accepts_nested_attributes_for #{name}: has_many #{name} not found on #{@type} (declare it first)" unless nested %}
      {% klass = nested[3] %}
      {% fk = nested[4] %}
      {% allow_d = (allow_destroy == true) %}

      @__nested_{{name.id}} : Array(Tuple({{klass}}, Bool)) = [] of Tuple({{klass}}, Bool)

      def {{name.id}}_attributes=(records : Array(Hash(String, ::ActiveRecord::Value))) : Nil
        records.each do |h|
          hh = {} of String => ::ActiveRecord::Value
          h.each { |k, v| hh[k] = v unless k == "id" || k == "_destroy" }
          id = h["id"]?.try(&.as?(Int64))
          do_destroy = case d = h["_destroy"]?
                        when true, 1_i64, "1", "true" then true
                        else                              false
                        end
          if id
            rec = {{name.id}}.find { |r| r.id == id }
            raise ::ActiveRecord::RecordNotFound.new(
              "Couldn't find {{klass}} with id #{id} for {{name}}") unless rec
            unless do_destroy && {{allow_d}}
              rec.assign_attributes(hh)
            end
            @__nested_{{name.id}} << {rec, do_destroy && {{allow_d}}}
          else
            {% if reject_if && reject_if.id.stringify == "all_blank" %}
              next if hh.values.all? { |v| v.nil? || (v.is_a?(String) && v.empty?) }
            {% end %}
            @__nested_{{name.id}} << Tuple.new({{name.id}}.build(hh), false)
          end
        end
      end

      # Child validations run with the parent's (Rails autosave); errors
      # surface prefixed with the association name.
      def validation__nested_{{name.id}}(context : Symbol) : Nil
        @__nested_{{name.id}}.each do |rec, do_destroy|
          next if do_destroy
          rec.{{fk.id}} = @id if rec.{{fk.id}}.nil? && @id
          unless rec.valid?
            rec.errors.full_messages.each do |fm|
              errors.add({{name.id.stringify}}, "#{fm[0]?.try(&.downcase) || ""}#{fm.size > 1 ? fm[1..] : ""}")
            end
          end
        end
        nil
      end

      # Deferred child writes: create/update children and honour _destroy
      # after the parent row is persisted.
      def after_save__cb_nested_{{name.id}} : Nil
        pending = @__nested_{{name.id}}
        @__nested_{{name.id}} = [] of Tuple({{klass}}, Bool)
        pending.each do |rec, do_destroy|
          if do_destroy
            rec.destroy
          else
            rec.{{fk.id}} = @id
            rec.save
          end
        end
        nil
      end
    end

    macro has_one(name, dependent = nil, foreign_key = nil, class_name = nil)
      {% owner_base = @type.name.split("::").last.downcase %}
      {% owner_fk = (foreign_key || (owner_base + "_id")) %}
      {% klass = (class_name || name.id.stringify.capitalize).id %}

      def {{name.id}} : {{klass}}?
        raise ::ActiveRecord::StrictLoadingViolationError.new(
          "{{@type}} is marked for strict_loading") if strict_loading?
        {{klass}}.where({{owner_fk}} + " = ?", @id).first
      end

      def build_{{name.id}}(values : Hash(String, ::ActiveRecord::Value) = {} of String => ::ActiveRecord::Value) : {{klass}}
        record = {{klass}}.new
        record.assign_attributes(values)
        record.assign_attributes({ {{owner_fk}} => @id.as(::ActiveRecord::Value) })
        record
      end

      def create_{{name.id}}(values : Hash(String, ::ActiveRecord::Value) = {} of String => ::ActiveRecord::Value) : {{klass}}
        record = build_{{name.id}}(values)
        record.save
        record
      end

      def create_{{name.id}}!(values : Hash(String, ::ActiveRecord::Value) = {} of String => ::ActiveRecord::Value) : {{klass}}
        record = build_{{name.id}}(values)
        record.save || raise RecordInvalid.new(record)
        record
      end

      {% if dependent == :destroy %}
        __dependent_destroy {{name.id}}.try(&.destroy)
      {% end %}
    end

    # has_and_belongs_to_many :tags → posts_tags join table. The join table
    # and column names are derived at RUNTIME from both table names (Rails
    # derives them from class names instead — pass foreign_key options
    # there; results are identical).
    macro has_and_belongs_to_many(name, class_name = nil, before_add = nil,
                                  after_add = nil, before_remove = nil,
                                  after_remove = nil)
      {% klass = (class_name || name.id.stringify.capitalize.gsub(/s$/, "")).id %}

      def {{name.id}} : ::ActiveRecord::CollectionProxy({{klass}})
        jt = [self.class.table_name, {{klass}}.table_name].sort.join("_")
        owner_col = ::ActiveRecord::Migrations.singularize(self.class.table_name) + "_id"
        target_col = ::ActiveRecord::Migrations.singularize({{klass}}.table_name) + "_id"
        sql = %("id" IN (SELECT "#{target_col}" FROM "#{jt}" WHERE "#{owner_col}" = ?))
        proxy = ::ActiveRecord::CollectionProxy({{klass}}).new({{klass}}, {{klass}}.where(sql, @id || -1_i64))
        proxy.__init_habtm(jt, owner_col, target_col, @id)
        {% if before_add || after_add || before_remove || after_remove %}
          proxy.__init_callbacks(self,
            {% if before_add %} [ {% for m in (before_add.is_a?(ArrayLiteral) ? before_add : [before_add]) %} ->(o : ::ActiveRecord::Base, r : {{klass}}) { o.as({{@type}}).{{m.id}}(r); nil }, {% end %} ] of ::Proc(::ActiveRecord::Base, {{klass}}, Nil) {% else %} nil {% end %},
            {% if after_add %} [ {% for m in (after_add.is_a?(ArrayLiteral) ? after_add : [after_add]) %} ->(o : ::ActiveRecord::Base, r : {{klass}}) { o.as({{@type}}).{{m.id}}(r); nil }, {% end %} ] of ::Proc(::ActiveRecord::Base, {{klass}}, Nil) {% else %} nil {% end %},
            {% if before_remove %} [ {% for m in (before_remove.is_a?(ArrayLiteral) ? before_remove : [before_remove]) %} ->(o : ::ActiveRecord::Base, r : {{klass}}) { o.as({{@type}}).{{m.id}}(r); nil }, {% end %} ] of ::Proc(::ActiveRecord::Base, {{klass}}, Nil) {% else %} nil {% end %},
            {% if after_remove %} [ {% for m in (after_remove.is_a?(ArrayLiteral) ? after_remove : [after_remove]) %} ->(o : ::ActiveRecord::Base, r : {{klass}}) { o.as({{@type}}).{{m.id}}(r); nil }, {% end %} ] of ::Proc(::ActiveRecord::Base, {{klass}}, Nil) {% else %} nil {% end %})
        {% end %}
        proxy
      end

      def {{(name.id.stringify.gsub(/s$/, "") + "_ids").id}} : Array(Int64)
        {{name.id}}.ids
      end
    end
  end
end
