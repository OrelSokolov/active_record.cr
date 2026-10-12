# Migrations: Rails-compatible DSL subset, oracle-verified against
# activerecord 8.1.4 (oracle/migrations.rb → oracle/migrations_expected.yml).
#
# Supported: create_table (typed columns, defaults, null, indexes,
# timestamps, references + foreign_key), drop_table (reversible only with
# a block), add/remove/rename/change_column, change_column_default,
# change_column_null, add/remove_index, add/remove_reference,
# add/remove_foreign_key, execute (up/down only).
# `change` is reverted through a command recorder; non-reversible commands
# raise ActiveRecord::IrreversibleMigration on rollback, exactly like Rails.

require "digest"

module ActiveRecord
  class IrreversibleMigration < Exception
  end

  class Migration
    property version : Int64?

    def initialize(@version : Int64? = nil)
    end

    # --- overridables -----------------------------------------------------
    def up : Nil
    end

    def down : Nil
    end

    def change : Nil
    end

    # --- driver -----------------------------------------------------------
    def migrate(direction : Symbol) : Nil
      case direction
      when :up
        announce(:up)
        up
        change
        announce_done(:up)
      when :down
        announce(:down)
        recorder = Recorder.new
        @recorder = recorder
        begin
          change # record inversions instead of executing
        ensure
          @recorder = nil
        end
        recorder.replay_reverse
        down # explicit down for up/down migrations (change-only ones no-op)
        announce_done(:down)
      end
    end

    @recorder : Recorder? = nil

    private def recording? : Bool
      !@recorder.nil?
    end

    private def record(inverse : ->) : Nil
      @recorder.not_nil!.record(inverse)
    end

    def announce(direction) : Nil
      puts "== #{version}: #{self.class.name} #{direction}"
    end

    def announce_done(direction) : Nil
      # format kept minimal (the oracle spec compares schema dumps, not log)
    end

    # --- table definition DSL (create_table block) ------------------------
    class TableDefinition
      getter columns = [] of Column
      getter indexes = [] of Index
      getter foreign_keys = [] of ForeignKey
      getter check_constraints = [] of CheckConstraint

      struct Column
        getter name, sql_type, default, null

        # Int32/Float32 widen the Value union so that schema.cr literals
        # dumped from the database (`default: 5`) compile without _i64 suffixes.
        def initialize(@name : String, @sql_type : String,
                       @default : ::ActiveRecord::Value | Int32 | Float32 = nil, @null : Bool = true)
        end

        def to_sql : String
          sql = "#{@name.inspect} #{@sql_type}"
          sql += " DEFAULT #{Column.default_sql(@default)}" unless @default.nil?
          sql += " NOT NULL" unless @null
          sql
        end

        def self.default_sql(default) : String
          case default
          when String then "'#{default}'"
          when JSON::Any
            "'#{default.to_json}'::jsonb"
          when Array                then "'[]'"
          when Bool, Int64, Float64 then default.to_s
          else                           default.to_s
          end
        end
      end

      struct Index
        getter name, columns, unique, where

        def initialize(@name : String, @columns : Array(String), @unique : Bool,
                       @where : String? = nil)
        end
      end

      struct ForeignKey
        getter column, to_table, name

        def initialize(@column : String, @to_table : String, @name : String)
        end
      end

      struct CheckConstraint
        getter expression, name

        def initialize(@expression : String, @name : String)
        end
      end

      def column(name : Symbol | String, type : Symbol | String, **opts)
        columns << Column.new(name.to_s, Migrations.sql_type(type, opts),
          opts[:default]?, Migrations.null_of(opts))
      end

      {% for t in %w(string text integer bigint float decimal boolean datetime
                    time date json jsonb uuid binary) %}
        def {{t.id}}(name : Symbol | String, **opts)
          column(name, {{t}}, **opts)
        end
      {% end %}

      def timestamps(**opts)
        merged = opts.merge(null: false)
        column(:created_at, :datetime, **merged)
        column(:updated_at, :datetime, **merged)
      end

      # references: bigint column + index (+ FK with foreign_key: true);
      # polymorphic: true adds the `{name}_type` string column (Rails
      # `t.references :tag, polymorphic: true` — needed by `crails generate
      # model`), null: false carries over to the reference column.
      def references(name : Symbol | String, index : Bool = true,
                     foreign_key : Bool = false, polymorphic : Bool = false,
                     null : Bool = true, **opts)
        col = "#{name}_id"
        columns << Column.new(col, "bigint", nil, null)
        if polymorphic
          columns << Column.new("#{name}_type", "character varying(255)", nil, null)
        end
        if index
          add_index(polymorphic ? [col, "#{name}_type"] : [col])
        end
        if foreign_key
          foreign_keys << ForeignKey.new(col, Migrations.tableize(name.to_s),
            Migrations.fk_name(@table_name, col))
        end
      end

      def add_index(columns : Array(String), unique : Bool = false,
                    name : String? = nil, where : String? = nil)
        iname = name || Migrations.index_name(@table_name, columns)
        indexes << Index.new(iname, columns, unique, where)
      end

      def index(columns : Symbol | String | Array(Symbol | String), unique : Bool = false,
                name : String? = nil, where : String? = nil)
        cols = columns.is_a?(Array) ? columns.map(&.to_s) : [columns.to_s]
        add_index(cols, unique, name, where)
      end

      # t.check_constraint "views >= 0", name: "posts_views_check" — applied
      # via ALTER TABLE after the table (and its indexes) exist, like Rails.
      def check_constraint(expression : String, name : String? = nil) : Nil
        cname = name || "chk_#{Digest::SHA256.hexdigest(expression)[0, 10]}"
        check_constraints << CheckConstraint.new(expression, cname)
      end

      # table name is set by create_table before yielding the block
      def name : String
        @table_name
      end

      def initialize(@table_name : String = "")
      end

      def self.build(table_name : String) : self
        new(table_name)
      end
    end

    # --- schema statements ------------------------------------------------
    def create_table(name : Symbol | String, primary_key : Symbol | String = "id",
                     id : Bool = true, force : Symbol | String? = nil,
                     &block : TableDefinition ->) : Nil
      table = name.to_s
      if recording?
        td = TableDefinition.build(table)
        block.call(td) # definition is irrelevant for the inverse (plain drop)
        record(-> { Base.connection.exec(%(DROP TABLE IF EXISTS "#{table}")); nil })
        return
      end
      td = TableDefinition.build(table)
      block.call(td)
      if force # schema.cr dumps carry force: :cascade for Rails-1:1 reloads
        cascade = force.to_s == "cascade" ? " CASCADE" : " RESTRICT"
        Base.connection.exec(%(DROP TABLE IF EXISTS "#{table}"#{cascade}))
      end
      cols = String.build do |s|
        if id
          s << %("#{primary_key}" bigserial PRIMARY KEY)
          s << ", " unless td.columns.empty?
        end
        td.columns.each_with_index do |c, i|
          s << ", " if i > 0
          s << c.to_sql
        end
      end
      Base.connection.exec(%(CREATE TABLE "#{table}" (#{cols})))
      td.indexes.each do |i|
        unique = i.unique ? "UNIQUE " : ""
        where_sql = i.where ? " WHERE (#{i.where})" : ""
        Base.connection.exec(
          %(CREATE #{unique}INDEX "#{i.name}" ON "#{table}" (#{i.columns.map { |c| %("#{c}") }.join(", ")})#{where_sql}))
      end
      td.foreign_keys.each do |fk|
        Base.connection.exec(
          %(ALTER TABLE "#{table}" ADD CONSTRAINT "#{fk.name}" FOREIGN KEY ("#{fk.column}") REFERENCES "#{fk.to_table}" ("id")))
      end
      td.check_constraints.each do |cc|
        Base.connection.exec(
          %(ALTER TABLE "#{table}" ADD CONSTRAINT "#{cc.name}" CHECK (#{cc.expression})))
      end
    end

    def drop_table(name : Symbol | String, &block : TableDefinition ->) : Nil
      table = name.to_s
      if recording?
        td = TableDefinition.build(table)
        block.call(td) # record the definition for the inverse create
        record(-> { recreate_table(td); nil })
        return
      end
      Base.connection.exec(%(DROP TABLE IF EXISTS "#{table}"))
    end

    def drop_table(name : Symbol | String) : Nil
      if recording?
        raise IrreversibleMigration.new(
          "To avoid mistakes, drop_table is only reversible if given options or a block")
      end
      Base.connection.exec(%(DROP TABLE IF EXISTS "#{name}"))
    end

    def recreate_table(td : TableDefinition) : Nil
      create_table(td.name) { |t| td.columns.each { |c| t.columns << c } }
    end

    # change_table :posts do |t|
    #   t.string :tagline        # → add_column (reversible)
    #   t.remove :published_on   # → remove_column (irreversible)
    #   t.index :tagline         # → add_index (reversible)
    # end
    # The proxy delegates to the reversible schema statements, inheriting
    # their recording semantics.
    def change_table(name : Symbol | String, &block : ChangeTable ->) : Nil
      block.call(ChangeTable.new(self, name.to_s))
    end

    struct ChangeTable
      def initialize(@migration : Migration, @table : String)
      end

      def column(name : Symbol | String, type : Symbol | String, **opts) : Nil
        @migration.add_column(@table, name, type, **opts)
      end

      {% for t in %w(string text integer bigint float decimal boolean datetime
                    time date json jsonb uuid binary) %}
        def {{t.id}}(name : Symbol | String, **opts)
          column(name, {{t}}, **opts)
        end
      {% end %}

      def remove(name : Symbol | String) : Nil
        @migration.remove_column(@table, name)
      end

      def rename(name : Symbol | String, new_name : Symbol | String) : Nil
        @migration.rename_column(@table, name, new_name)
      end

      def change_default(name : Symbol | String, default : Value?) : Nil
        @migration.change_column_default(@table, name, default)
      end

      def change_null(name : Symbol | String, null : Bool) : Nil
        @migration.change_column_null(@table, name, null)
      end

      def index(columns : Symbol | String | Array(Symbol | String),
                unique : Bool = false, name : String? = nil,
                where : String? = nil) : Nil
        @migration.add_index(@table, columns, unique, name, where)
      end
    end

    # Rails create_join_table :posts, :tags → posts_tags(post_id, tag_id),
    # no primary key. Table name is the alphabetically sorted pair, columns
    # are the singularized sorted names. (Oracle-verified: no index is
    # created unless index: true is passed.)
    def create_join_table(a : Symbol | String, b : Symbol | String,
                          index : Bool = false) : Nil
      create_join_table(a, b, index) { |_t| nil }
    end

    def create_join_table(a : Symbol | String, b : Symbol | String,
                          index : Bool = true, & : TableDefinition ->) : Nil
      parts = [a.to_s, b.to_s].sort
      table = "#{parts[0]}_#{parts[1]}"
      # Rails: columns are named from the SORTED pair, singularized
      col_a = "#{parts[0].rchop('s')}_id"
      col_b = "#{parts[1].rchop('s')}_id"
      extra = TableDefinition.build(table)
      yield extra
      create_table(table, id: false) do |t|
        t.bigint(col_a, null: false)
        t.bigint(col_b, null: false)
        t.index([col_a, col_b]) if index
        extra.columns.each { |c| t.columns << c }
        extra.@indexes.each { |i| t.indexes << i }
      end
    end

    # Check constraints (not covered by the schema dump oracle — SQL is
    # exercised through the migration suite).
    def add_check_constraint(table : Symbol | String, expression : String,
                             name : String? = nil) : Nil
      tbl = table.to_s
      if recording?
        cname = name || "chk_#{tbl}_#{Digest::SHA256.hexdigest(expression)[0, 10]}"
        record(-> { Base.connection.exec(%(ALTER TABLE "#{tbl}" DROP CONSTRAINT IF EXISTS "#{cname}")); nil })
        return
      end
      cname = name || "chk_#{tbl}_#{Digest::SHA256.hexdigest(expression)[0, 10]}"
      Base.connection.exec(%(ALTER TABLE "#{tbl}" ADD CONSTRAINT "#{cname}" CHECK (#{expression})))
    end

    def remove_check_constraint(table : Symbol | String, name : Symbol | String) : Nil
      Base.connection.exec(%(ALTER TABLE "#{table}" DROP CONSTRAINT IF EXISTS "#{name}"))
    end

    # enable_extension "pg_catalog.plpgsql" — schema.cr dumps lead with the
    # installed extensions, like Rails. Idempotent.
    def enable_extension(name : String) : Nil
      ext = name.includes?('.') ? name.split('.', 2)[1] : name
      Base.connection.exec(%(CREATE EXTENSION IF NOT EXISTS "#{ext}"))
    end

    def add_column(table : Symbol | String, name : Symbol | String,
                   type : Symbol | String, **opts) : Nil
      tbl = table.to_s
      col = name.to_s
      if recording?
        record(-> { Base.connection.exec(%(ALTER TABLE "#{tbl}" DROP COLUMN IF EXISTS "#{col}")); nil })
        return
      end
      column = TableDefinition::Column.new(col, Migrations.sql_type(type, opts),
        opts[:default]?, Migrations.null_of(opts))
      Base.connection.exec(%(ALTER TABLE "#{tbl}" ADD COLUMN #{column.to_sql}))
    end

    # Type is optional (Rails passes it so the reverse of remove_column
    # can re-add the column; `crails generate migration RemoveXFromY`
    # relies on this).
    def remove_column(table : Symbol | String, name : Symbol | String,
                      type : Symbol | String? = nil, **opts) : Nil
      if recording?
        if type
          col = TableDefinition::Column.new(name.to_s,
            Migrations.sql_type(type, opts), opts[:default]?, Migrations.null_of(opts))
          tbl = table.to_s
          record(-> { Base.connection.exec(
            %(ALTER TABLE "#{tbl}" ADD COLUMN #{col.to_sql})); nil })
        else
          raise IrreversibleMigration.new(
            "remove_column is only reversible if given the type (not supported)")
        end
        return
      end
      Base.connection.exec(
        %(ALTER TABLE "#{table}" DROP COLUMN IF EXISTS "#{name}"))
    end

    def rename_column(table : Symbol | String, name : Symbol | String,
                      new_name : Symbol | String) : Nil
      tbl = table.to_s
      if recording?
        record(-> { Base.connection.exec(
          %(ALTER TABLE "#{tbl}" RENAME COLUMN "#{new_name}" TO "#{name}")); nil })
        return
      end
      Base.connection.exec(
        %(ALTER TABLE "#{tbl}" RENAME COLUMN "#{name}" TO "#{new_name}"))
    end

    def change_column_default(table : Symbol | String, name : Symbol | String,
                              default : Value?) : Nil
      if recording?
        raise IrreversibleMigration.new(
          "change_column_default is only reversible with from/to (not supported)")
      end
      sql_default = default.nil? ? "NULL" : TableDefinition::Column.default_sql(default)
      Base.connection.exec(
        %(ALTER TABLE "#{table}" ALTER COLUMN "#{name}" SET DEFAULT #{sql_default}))
    end

    def change_column_null(table : Symbol | String, name : Symbol | String,
                           null : Bool) : Nil
      if recording?
        raise IrreversibleMigration.new("change_column_null is not reversible")
      end
      clause = null ? "DROP NOT NULL" : "SET NOT NULL"
      Base.connection.exec(%(ALTER TABLE "#{table}" ALTER COLUMN "#{name}" #{clause}))
    end

    def change_column(table : Symbol | String, name : Symbol | String,
                      type : Symbol | String, **opts) : Nil
      if recording?
        raise IrreversibleMigration.new("change_column is not reversible")
      end
      col = TableDefinition::Column.new(name.to_s, Migrations.sql_type(type, opts),
        opts[:default]?, Migrations.null_of(opts))
      Base.connection.exec(
        %(ALTER TABLE "#{table}" ALTER COLUMN "#{name}" TYPE #{col.sql_type.split(" ", 2)[1]? || "text"}))
    end

    def add_index(table : Symbol | String, columns : Symbol | String | Array(Symbol | String),
                  unique : Bool = false, name : String? = nil,
                  where : String? = nil) : Nil
      tbl = table.to_s
      cols = columns.is_a?(Array) ? columns.map(&.to_s) : [columns.to_s]
      iname = name || Migrations.index_name(tbl, cols)
      if recording?
        record(-> { Base.connection.exec(%(DROP INDEX IF EXISTS "#{iname}")); nil })
        return
      end
      unique_sql = unique ? "UNIQUE " : ""
      where_sql = where ? " WHERE (#{where})" : ""
      Base.connection.exec(
        %(CREATE #{unique_sql}INDEX "#{iname}" ON "#{tbl}" (#{cols.map { |c| %("#{c}") }.join(", ")})#{where_sql}))
    end

    def remove_index(table : Symbol | String, columns : Symbol | String | Array(Symbol | String),
                     name : String? = nil) : Nil
      if recording?
        raise IrreversibleMigration.new("remove_index is not reversible")
      end
      tbl = table.to_s
      cols = columns.is_a?(Array) ? columns.map(&.to_s) : [columns.to_s]
      iname = name || Migrations.index_name(tbl, cols)
      Base.connection.exec(%(DROP INDEX IF EXISTS "#{iname}"))
    end

    def add_reference(table : Symbol | String, name : Symbol | String,
                      index : Bool = true, foreign_key : Bool = false,
                      polymorphic : Bool = false) : Nil
      tbl = table.to_s
      col = "#{name}_id"
      type_col = "#{name}_type"
      if recording?
        to_table = Migrations.tableize(name.to_s)
        fkn = Migrations.fk_name(tbl, col)
        iname = Migrations.index_name(tbl, polymorphic ? [col, type_col] : [col])
        steps = [] of Proc(Nil)
        steps << -> { Base.connection.exec(%(DROP INDEX IF EXISTS "#{iname}")); nil }
        if foreign_key
          steps << -> { Base.connection.exec(%(ALTER TABLE "#{tbl}" DROP CONSTRAINT IF EXISTS "#{fkn}")); nil }
        end
        steps << -> { Base.connection.exec(%(ALTER TABLE "#{tbl}" DROP COLUMN IF EXISTS "#{col}")); nil }
        if polymorphic
          steps << -> { Base.connection.exec(%(ALTER TABLE "#{tbl}" DROP COLUMN IF EXISTS "#{type_col}")); nil }
        end
        record(-> { steps.each(&.call); nil })
        return
      end
      add_column(table, col, :bigint)
      if polymorphic
        add_column(table, type_col, :string)
      end
      if index
        add_index(tbl, polymorphic ? [col, type_col] : [col])
      end
      if foreign_key
        add_foreign_key(tbl, Migrations.tableize(name.to_s), column: col)
      end
    end

    def add_belongs_to(table : Symbol | String, name : Symbol | String,
                       index : Bool = true, foreign_key : Bool = false,
                       polymorphic : Bool = false) : Nil
      add_reference(table, name, index: index, foreign_key: foreign_key,
        polymorphic: polymorphic)
    end

    def remove_reference(table : Symbol | String, name : Symbol | String,
                         polymorphic : Bool = false, **opts) : Nil
      if recording?
        raise IrreversibleMigration.new("remove_reference is not reversible")
      end
      tbl = table.to_s
      col = "#{name}_id"
      type_col = "#{name}_type"
      if polymorphic
        remove_column(tbl, type_col)
      end
      Base.connection.exec(
        %(ALTER TABLE "#{tbl}" DROP INDEX IF EXISTS "#{Migrations.index_name(tbl, [col])}"))
      remove_foreign_key(tbl, Migrations.tableize(name.to_s)) rescue nil
      Base.connection.exec(
        %(ALTER TABLE "#{tbl}" DROP COLUMN IF EXISTS "#{col}"))
    end

    def remove_belongs_to(table : Symbol | String, name : Symbol | String,
                          polymorphic : Bool = false, **opts) : Nil
      remove_reference(table, name, polymorphic: polymorphic)
    end

    def add_foreign_key(from_table : Symbol | String, to_table : Symbol | String,
                        column : String? = nil, name : String? = nil) : Nil
      from = from_table.to_s
      to = to_table.to_s
      col = column || Migrations.singularize(to) + "_id"
      fk_name = name || Migrations.fk_name(from, col)
      if recording?
        record(-> { Base.connection.exec(%(ALTER TABLE "#{from}" DROP CONSTRAINT IF EXISTS "#{fk_name}")); nil })
        return
      end
      Base.connection.exec(
        %(ALTER TABLE "#{from}" ADD CONSTRAINT "#{fk_name}" FOREIGN KEY ("#{col}") REFERENCES "#{to}" ("id")))
    end

    def remove_foreign_key(from_table : Symbol | String, to_table : Symbol | String) : Nil
      if recording?
        raise IrreversibleMigration.new("remove_foreign_key is not reversible")
      end
      from = from_table.to_s
      col = Migrations.singularize(to_table.to_s) + "_id"
      fk_name = Migrations.fk_name(from, col)
      Base.connection.exec(%(ALTER TABLE "#{from}" DROP CONSTRAINT IF EXISTS "#{fk_name}"))
    end

    def execute(sql : String) : Nil
      if recording?
        raise IrreversibleMigration.new("execute is not reversible (use up/down)")
      end
      Base.connection.exec(sql)
    end

    # reversible do |dir|
    #   dir.up   { execute "..." }
    #   dir.down { execute "..." }
    # end
    # Up: runs the up-block in place. Down (inside a recorded `change`):
    # records the down-block as the inverse, without running the up-block.
    def reversible(&block : ReversibleDirection ->) : Nil
      dir = ReversibleDirection.new
      block.call(dir)
      if recording?
        record(-> { dir.__run_down; nil })
      else
        dir.__run_up
      end
    end

    class ReversibleDirection
      @up_block : Proc(Nil)? = nil
      @down_block : Proc(Nil)? = nil

      def up(&block : Proc(Nil)) : Nil
        @up_block = block
      end

      def down(&block : Proc(Nil)) : Nil
        @down_block = block
      end

      def __run_up : Nil
        @up_block.try(&.call)
      end

      def __run_down : Nil
        @down_block.try(&.call)
      end
    end

    # --- command recorder ---------------------------------------------------
    class Recorder
      @inverses = [] of Proc(Nil)

      def record(inverse : Proc(Nil)) : Nil
        @inverses << inverse
      end

      def replay_reverse : Nil
        @inverses.reverse.each(&.call)
      end
    end
  end

  # --- naming / type helpers ------------------------------------------------
  module Migrations
    extend self

    # Rails type → PostgreSQL DDL (verified against oracle/migrations_expected.yml)
    def sql_type(type : Symbol | String, opts) : String
      precision = opts[:precision]?
      scale = opts[:scale]?
      limit = opts[:limit]?
      case type.to_s
      when "string"  then limit ? "character varying(#{limit})" : "character varying"
      when "text"    then "text"
      when "integer" then "integer"
      when "bigint"  then "bigint"
      when "float"   then "double precision"
      when "decimal"
        if precision && scale
          "numeric(#{precision},#{scale})"
        elsif precision
          "numeric(#{precision})"
        else
          "numeric"
        end
      when "boolean"  then "boolean"
      when "datetime" then precision == false ? "timestamp" : "timestamp(6)"
      when "time"     then precision == false ? "time" : "time(6)"
      when "date"     then "date"
      when "json"     then "json"
      when "jsonb"    then "jsonb"
      when "uuid"     then "uuid"
      when "binary"   then "bytea"
      else                 "text"
      end
    end

    def index_name(table : String, columns : Array(String)) : String
      "index_#{table}_on_#{columns.join("_and_")}"
    end

    # `null:` option default (explicit `false` must survive truthiness checks)
    def null_of(opts) : Bool
      n = opts[:null]?
      n.nil? ? true : n
    end

    # fk_rails_<sha256("#{table}_#{column}_fk")[0,10]> — Rails 8 formula
    def fk_name(table : String, column : String) : String
      "fk_rails_#{Digest::SHA256.hexdigest("#{table}_#{column}_fk")[0, 10]}"
    end

    def tableize(word : String) : String
      pluralize(singularize_camel(word))
    end

    def singularize(word : String) : String
      word.ends_with?("ies") ? word[0..-4] + "y" : word.ends_with?("ses") ? word[0..-3] : word.ends_with?('s') ? word[0..-2] : word
    end

    def pluralize(word : String) : String
      return word if word.ends_with?("ics", "es") && word != "address"
      word.ends_with?('y') ? word[0..-2] + "ies" : word.ends_with?("s", "x", "ch", "sh") ? word + "es" : word + "s"
    end

    def singularize_camel(word : String) : String
      snake(word)
    end

    def snake(word : String) : String
      word.gsub(/([A-Z]+)([A-Z][a-z])/, "\\1_\\2")
        .gsub(/([a-z\d])([A-Z])/, "\\1_\\2")
        .downcase
    end
  end

  # --- migrator ---------------------------------------------------------------
  class Migrator
    def initialize(@direction : Symbol, @migrations : Array(Migration), @step : Int32 = 0)
    end

    def migrate : Nil
      ensure_schema_migrations
      ordered = @direction == :up ? @migrations.sort_by(&.version.not_nil!) : @migrations.sort_by(&.version.not_nil!).reverse
      done = 0
      ordered.each do |m|
        v = m.version.not_nil!
        next if @direction == :up && applied?(v)
        next if @direction == :down && !applied?(v)
        break if @step > 0 && done >= @step
        m.migrate(@direction)
        record_version(v)
        done += 1
      end
    end

    private def ensure_schema_migrations : Nil
      Base.connection.exec(%(CREATE TABLE IF NOT EXISTS "schema_migrations" (
        "version" bigint NOT NULL PRIMARY KEY)))
    end

    private def applied?(version : Int64) : Bool
      Base.connection.query_one?(
        %(SELECT 1 FROM "schema_migrations" WHERE "version" = $1 LIMIT 1),
        args: [version], as: Int32) ? true : false
    end

    private def record_version(version : Int64) : Nil
      if @direction == :up
        Base.connection.exec(
          %(INSERT INTO "schema_migrations" ("version") VALUES ($1)), args: [version])
      else
        Base.connection.exec(
          %(DELETE FROM "schema_migrations" WHERE "version" = $1), args: [version])
      end
    end
  end
end
