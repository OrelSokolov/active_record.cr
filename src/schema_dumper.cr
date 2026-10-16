# Schema dump → db/schema.cr (Rails schema.rb syntax, 1:1) plus the YAML
# fallback (db/schema.yml, the codegen_runner input for model attributes).
#
# dump_cr output is byte-exact against the oracle: oracle/schema.rb runs the
# same migrations with the ORIGINAL activerecord 8.1.4 and captures its
# SchemaDumper.dump (oracle/schema_expected.cr) — only two mechanical
# Ruby→Crystal tweaks are applied there (`require` line, typed `[] of Int64`).
#
# Used by `crails db:migrate / db:schema:dump / db:schema:load`.

require "yaml"

module ActiveRecord
  module SchemaDumper
    IGNORED_TABLES = %w(schema_migrations ar_internal_metadata)

    # Rails 8.1 schema.rb header (kept verbatim for eye-level 1:1).
    HEADER = <<-HEADER
      # This file is auto-generated from the current state of the database. Instead
      # of editing this file, please use the migrations feature of Active Record to
      # incrementally modify your database, and then regenerate this schema definition.
      #
      # This file is the source Rails uses to define your schema when running `bin/rails
      # db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
      # be faster and is potentially less error prone than running all of your
      # migrations from scratch. Old migrations may fail to apply correctly if those
      # migrations use external dependencies or application code.
      #
      # It's strongly recommended that you check this file into your version control system.
      HEADER

    # --- db/schema.cr (primary) ---------------------------------------------

    def self.dump_cr : String
      conn = Base.connection

      columns = conn.query_all(<<-SQL, as: {String, String, String, Bool, String?, String, String, String, String})
        SELECT c.table_name, c.column_name, c.udt_name, c.is_nullable = 'YES', c.column_default,
               COALESCE(c.character_maximum_length::text, ''),
               COALESCE(c.numeric_precision::text, ''),
               COALESCE(c.numeric_scale::text, ''),
               COALESCE(c.datetime_precision::text, '')
        FROM information_schema.columns c
        JOIN information_schema.tables t
          ON t.table_schema = c.table_schema AND t.table_name = c.table_name
        WHERE c.table_schema = 'public' AND t.table_type = 'BASE TABLE'
          AND c.table_name NOT IN ('schema_migrations', 'ar_internal_metadata')
        ORDER BY c.table_name, c.ordinal_position
      SQL

      # primary keys: table → pk index name (pk-less tables absent → id: false)
      pk_indexes = {} of String => String
      conn.query_all(<<-SQL, as: {String, String}).each do |(table, index)|
          SELECT c.relname AS tbl, i.relname AS idx
          FROM pg_index x
          JOIN pg_class c ON c.oid = x.indrelid
          JOIN pg_class i ON i.oid = x.indexrelid
          JOIN pg_namespace n ON n.oid = c.relnamespace
          WHERE x.indisprimary AND n.nspname = 'public'
        SQL
        pk_indexes[table] = index
      end
      pk_columns = {} of String => String
      conn.query_all(<<-SQL, as: {String, String}).each do |(table, column)|
          SELECT c.relname AS tbl, a.attname
          FROM pg_index x
          JOIN pg_class c ON c.oid = x.indrelid
          JOIN pg_namespace n ON n.oid = c.relnamespace
          JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum = ANY(x.indkey)
          WHERE x.indisprimary AND n.nspname = 'public'
        SQL
        pk_columns[table] = column
      end

      indexes = conn.query_all(<<-SQL, as: {String, String, String})
        SELECT tablename, indexname, indexdef
        FROM pg_indexes
        WHERE schemaname = 'public'
          AND tablename NOT IN ('schema_migrations', 'ar_internal_metadata')
        ORDER BY tablename, indexname
      SQL

      fks = conn.query_all(<<-SQL, as: {String, String, String})
        SELECT conrelid::regclass::text AS rel, conname, pg_get_constraintdef(oid) AS def
        FROM pg_constraint
        WHERE contype = 'f' AND connamespace = 'public'::regnamespace
        ORDER BY conrelid::regclass::text, conname
      SQL

      checks = conn.query_all(<<-SQL, as: {String, String, String})
        SELECT conrelid::regclass::text AS rel, conname, pg_get_constraintdef(oid) AS def
        FROM pg_constraint
        WHERE contype = 'c' AND conislocal AND connamespace = 'public'::regnamespace
        ORDER BY conrelid::regclass::text, conname
      SQL

      extensions = conn.query_all(<<-SQL, as: {String, String})
        SELECT e.extname, n.nspname
        FROM pg_extension e
        JOIN pg_namespace n ON n.oid = e.extnamespace
        ORDER BY e.extname
      SQL

      version = begin
        conn.query_one("SELECT COALESCE(MAX(version), 0) FROM schema_migrations", as: Int64)
      rescue
        0_i64
      end

      tables = {} of String => Array({String, String, String, Bool, String?, String, String, String, String})
      columns.each do |row|
        tables[row[0]] ||= [] of {String, String, String, Bool, String?, String, String, String, String}
        tables[row[0]] << row
      end

      String.build do |s|
        s << %(require "active_record_cr"\n\n)
        HEADER.each_line { |line| s << line << '\n' }
        s << '\n'
        s << "ActiveRecord::Schema[8.1].define(version: #{format_version(version)}) do\n"
        unless extensions.empty?
          s << "  # These are extensions that must be enabled in order to support this database\n"
          extensions.each do |(ext, ns)|
            name = ns == "public" ? ext : "#{ns}.#{ext}"
            s << "  enable_extension #{name.inspect}\n"
          end
        end

        indexes_by_table = {} of String => Array({String, String, String})
        indexes.each do |row|
          next if pk_indexes[row[0]]? == row[1] # skip the implicit PK index
          indexes_by_table[row[0]] ||= [] of {String, String, String}
          indexes_by_table[row[0]] << row
        end
        checks_by_table = {} of String => Array({String, String})
        checks.each do |(rel, con, defn)|
          next unless tables[rel]? # ignored tables
          if (m = defn.match(/\ACHECK \((.*)\)\z/m)) && (expr = m[1]).starts_with?('(') && expr.ends_with?(')')
            expr = expr[1..-2]
          else
            next
          end
          checks_by_table[rel] ||= [] of {String, String}
          checks_by_table[rel] << {con, expr}
        end

        tables.each do |table, cols|
          s << '\n'
          opts = pk_columns[table]? ? "" : ", id: false"
          s << %(  create_table #{table.inspect}#{opts}, force: :cascade do |t|\n)
          cols.each do |(tname, cname, udt, nullable, default, len, nprec, nscale, dprec)|
            next if cname == (pk_columns[table]? || "id") && default.to_s.starts_with?("nextval(")
            s << column_line(cname, udt, nullable, default, len, nprec, nscale, dprec)
          end
          indexes_by_table[table]?.try &.each do |(_, iname, idef)|
            s << index_line(iname, idef)
          end
          checks_by_table[table]?.try &.each do |con, expr|
            s << %(    t.check_constraint #{expr.inspect}, name: #{con.inspect}\n)
          end
          s << "  end\n"
        end

        fk_lines = fks.map do |(rel, con, defn)|
          next "" unless tables[rel]?
          fk_line(rel, con, defn)
        end.reject(&.empty?)
        unless fk_lines.empty?
          s << '\n'
          fk_lines.each { |line| s << line }
        end
        s << "end\n"
      end
    end

    def self.dump_cr_to_file(path : String = "db/schema.cr") : Int32
      tables = Base.connection.query_all(<<-SQL, as: String).size
        SELECT c.table_name
        FROM information_schema.columns c
        JOIN information_schema.tables t
          ON t.table_schema = c.table_schema AND t.table_name = c.table_name
        WHERE c.table_schema = 'public' AND t.table_type = 'BASE TABLE'
          AND c.table_name NOT IN ('schema_migrations', 'ar_internal_metadata')
        GROUP BY c.table_name
      SQL
      Dir.mkdir_p(File.dirname(path)) unless File.dirname(path) == "."
      File.write(path, dump_cr)
      tables
    end

    # --- db/schema.yml (fallback: model codegen input) ------------------------

    # A dumped index: everything needed to rebuild it (the admin/CRUD-from-
    # schema.yml consumer reads these; attribute codegen ignores the key).
    struct IndexDef
      getter name : String
      getter columns : Array(String)
      getter unique : Bool
      getter where : String?

      def initialize(@name, @columns, @unique, @where)
      end

      def to_h : Hash(String, Array(String) | Bool | String?)
        {"name" => @name, "columns" => @columns, "unique" => @unique,
         "where" => @where}
      end
    end

    def self.dump_to_file(path : String = "db/schema.yml") : Int32
      sqlite = Base.sqlite?
      rows = sqlite ? sqlite_rows : postgres_rows
      indexes = sqlite ? sqlite_indexes : postgres_indexes

      columns = {} of String => Array(Hash(String, String?))
      rows.each do |(table, column, udt, nullable, default)|
        entry = {"name" => column, "type" => udt, "nullable" => nullable, "default" => default}
        (columns[table] ||= [] of Hash(String, String?)) << entry
      end

      tables = {} of String => Hash(String, Array(Hash(String, String?)) | Array(Hash(String, Array(String) | Bool | String?)))
      columns.each do |table, cols|
        entry = {} of String => Array(Hash(String, String?)) | Array(Hash(String, Array(String) | Bool | String?))
        entry["columns"] = cols
        if idx = indexes[table]?
          entry["indexes"] = idx.map(&.to_h)
        end
        tables[table] = entry
      end

      Dir.mkdir_p(File.dirname(path)) unless File.dirname(path) == "."
      File.write(path, YAML.dump(tables))
      tables.size
    end

    # Index inventory (both adapters skip the implicit PK index; unique-
    # constraint-backed indexes ARE included, matching dump_cr/pg_indexes).
    def self.postgres_indexes : Hash(String, Array(IndexDef))
      conn = Base.connection
      pk = conn.query_all(<<-SQL, as: {String, String}).to_h
        SELECT c.relname AS tbl, i.relname AS idx
        FROM pg_index x
        JOIN pg_class c ON c.oid = x.indrelid
        JOIN pg_class i ON i.oid = x.indexrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE x.indisprimary AND n.nspname = 'public'
      SQL
      result = {} of String => Array(IndexDef)
      conn.query_all(<<-SQL, as: {String, String, String})
        SELECT tablename, indexname, indexdef
        FROM pg_indexes
        WHERE schemaname = 'public'
          AND tablename NOT IN ('schema_migrations', 'ar_internal_metadata')
        ORDER BY tablename, indexname
      SQL
        .each do |(table, iname, idef)|
          next if pk[table]? == iname
          parsed = parse_index_columns(idef)
          next unless parsed
          (result[table] ||= [] of IndexDef) <<
            IndexDef.new(iname, parsed[0], idef.starts_with?("CREATE UNIQUE INDEX"), parsed[1])
        end
      result
    end

    def self.sqlite_indexes : Hash(String, Array(IndexDef))
      conn = Base.connection
      result = {} of String => Array(IndexDef)
      sqlite_table_names.each do |table|
        # collect first, then introspect per index (no nested result sets)
        listed = [] of {String, Bool, String, Bool}
        conn.query("PRAGMA index_list(#{quote_ident_sqlite(table)})") do |rs|
          rs.each do
            rs.read(Int32)            # seq
            iname = rs.read(String)
            unique = rs.read(Int64) == 1_i64
            origin = rs.read(String)  # c = CREATE INDEX, u = UNIQUE constraint, pk
            partial = rs.read(Int64) == 1_i64
            listed << {iname, unique, origin, partial}
          end
        end
        listed.reject { |(_, _, origin, _)| origin == "pk" }.each do |(iname, unique, _origin, partial)|
          # auto-indexes (UNIQUE constraints) have no sqlite_master entry;
          # expression components come back unnamed (NULL) — kept as ""
          # (pragma_index_info table function → the name column only)
          cols = conn.query_all(
            %(SELECT name FROM pragma_index_info(#{sql_literal(iname)})),
            as: String?).map(&.to_s)
          where = nil
          if partial
            sql = conn.query_one?(
              %(SELECT sql FROM sqlite_master WHERE type = 'index' AND name = #{sql_literal(iname)}),
              as: String)
            if sql && (m = sql.match(/\)\s+WHERE\s+(.+)\z/im))
              where = m[1]
            end
          end
          (result[table] ||= [] of IndexDef) << IndexDef.new(iname, cols, unique, where)
        end
      end
      result
    end

    # SQLite introspection: sqlite_master + PRAGMA table_info, with declared
    # types normalized to the PostgreSQL udt names the codegen understands
    # (crystal_type/rails_type in codegen_runner.cr stay untouched).
    # FTS5 shadow tables (<vt>_data/_idx/_content/_docsize/_config) are
    # skipped by excluding every table shadowing a virtual table.
    def self.sqlite_table_names : Array(String)
      conn = Base.connection
      virtual = conn.query_all(
        "SELECT name FROM sqlite_master WHERE type = 'table' " \
        "AND sql LIKE 'CREATE VIRTUAL TABLE%'", as: String)
      shadows = ->(name : String) { virtual.any? { |vt| name == vt || name.starts_with?("#{vt}_") } }
      conn.query_all(
        "SELECT name FROM sqlite_master WHERE type = 'table' " \
        "AND name NOT LIKE 'sqlite_%' ORDER BY name", as: String)
        .reject { |name| shadows.call(name) }
    end

    def self.sqlite_rows : Array({String, String, String, String, String?})
      conn = Base.connection
      rows = [] of {String, String, String, String, String?}
      sqlite_table_names.each do |table|
        conn.query("PRAGMA table_info(#{quote_ident_sqlite(table)})") do |rs|
          rs.each do
            rs.read(Int32)                                  # cid
            name = rs.read(String)
            declared = rs.read(String)
            notnull = rs.read(Int64)
            default = rs.read(String?)
            pk = rs.read(Int64)
            # INTEGER PRIMARY KEY reports notnull=0 while being NOT NULL;
            # any pk flag (composite pks are 1..n) means NO NULLs.
            rows << {table, name, sqlite_udt(declared),
                     (notnull == 1_i64 || pk > 0) ? "NO" : "YES", default}
          end
        end
      end
      rows
    end

    # SQLite column affinity → PostgreSQL udt name (codegen's vocabulary).
    def self.sqlite_udt(declared : String) : String
      d = declared.downcase
      return "varchar" if d.empty? # typeless column → string
      return "bytea" if d.includes?("blob")
      return "bool" if d.includes?("bool")
      return "float8" if d.includes?("real") || d.includes?("floa") || d.includes?("doub")
      return "numeric" if d.includes?("num") || d.includes?("dec")
      return "timestamp" if d.includes?("timestamp") || d.includes?("datetime")
      return "date" if d == "date"
      return "jsonb" if d.includes?("json")
      return "varchar" if d.includes?("char") || d.includes?("clob")
      return "int8" if d.includes?("bigint") || d.includes?("int8")
      return "int4" if d.includes?("int")
      "text"
    end

    def self.quote_ident_sqlite(name : String) : String
      %("#{name.gsub('"', %("""))}")
    end

    def self.sql_literal(value : String) : String
      "'#{value.gsub("'", "''")}'"
    end

    def self.postgres_rows : Array({String, String, String, String, String?})
      Base.connection.query_all(<<-SQL, as: {String, String, String, String, String?})
        SELECT c.table_name, c.column_name, c.udt_name, c.is_nullable, c.column_default
        FROM information_schema.columns c
        JOIN information_schema.tables t
          ON t.table_schema = c.table_schema AND t.table_name = c.table_name
        WHERE c.table_schema = 'public' AND t.table_type = 'BASE TABLE'
        ORDER BY c.table_name, c.ordinal_position
      SQL
    end

    # --- emit helpers -----------------------------------------------------------

    def self.column_line(name : String, udt : String, nullable : Bool, default : String?,
                          len : String, nprec : String, nscale : String,
                          dprec : String) : String
      type, limit, precision, scale = dsl_type(udt, len, nprec, nscale, dprec)
      lit = default_literal(udt, default)
      parts = [] of String
      parts << "limit: #{limit}" if limit
      parts << "precision: #{precision}" if precision
      parts << "scale: #{scale}" if scale
      parts << "default: #{lit}" if lit
      parts << "null: false" unless nullable
      opts = parts.empty? ? "" : ", #{parts.join(", ")}"
      %(    t.#{type} #{name.inspect}#{opts}\n)
    end

    # udt → {dsl type, limit, precision, scale}
    def self.dsl_type(udt : String, len : String, nprec : String, nscale : String,
                      dprec : String) : {String, String?, String?, String?}
      case udt
      when "varchar", "bpchar"
        limit = (len.empty? || len == "255") ? nil : len
        {"string", limit, nil, nil}
      when "text"     then {"text", nil, nil, nil}
      when "int4"     then {"integer", nil, nil, nil}
      when "int8"     then {"bigint", nil, nil, nil}
      when "float4", "float8" then {"float", nil, nil, nil}
      when "numeric"
        {"decimal", nil, nprec.empty? ? nil : nprec, nscale.empty? ? nil : nscale}
      when "bool"     then {"boolean", nil, nil, nil}
      when "timestamp", "timestamptz"
        {"datetime", nil, nil, (dprec.empty? || dprec == "6") ? nil : dprec}
      when "time"
        {"time", nil, nil, (dprec.empty? || dprec == "6") ? nil : dprec}
      when "date"     then {"date", nil, nil, nil}
      when "json"     then {"json", nil, nil, nil}
      when "jsonb"    then {"jsonb", nil, nil, nil}
      when "uuid"     then {"uuid", nil, nil, nil}
      when "bytea"    then {"binary", nil, nil, nil}
      else raise "SchemaDumper: unknown PostgreSQL type '#{udt}'"
      end
    end

    # column_default → DSL literal (nil = omit; expression defaults such as
    # now() are skipped — the DSL has no proc defaults, a documented deviation).
    def self.default_literal(udt : String, default : String?) : String?
      return nil if default.nil? || default.empty?
      return nil if default.starts_with?("nextval(")
      return nil if default.matches?(/\A(current_timestamp|now\(\)|CURRENT_DATE)/i)
      if (m = default.match(/\A'(.*)'::[a-z ]+\z/m))
        raw = m[1].gsub("''", "'")
        return "[] of Int64" if udt.in?("jsonb", "json") && raw == "[]"
        return "::JSON.parse(#{raw.inspect})" if udt.in?("jsonb", "json")
        return raw.inspect
      end
      return default if default.matches?(/\A-?\d+\z/) || default == "true" || default == "false"
      default.matches?(/\A-?\d+\.\d+\z/) ? default : nil
    end

    def self.index_line(name : String, indexdef : String) : String
      parsed = parse_index_columns(indexdef)
      return "" unless parsed
      cols, where = parsed
      unique = indexdef.starts_with?("CREATE UNIQUE INDEX")
      parts = ["name: #{name.inspect}"]
      parts << "unique: true" if unique
      parts << "where: #{where.inspect}" if where
      %(    t.index [#{cols.map(&.inspect).join(", ")}], #{parts.join(", ")}\n)
    end

    # indexdef "CREATE [UNIQUE] INDEX … USING am (cols) [WHERE pred]" →
    # {unquoted column list, raw predicate (outer parens kept — the exact
    # form the Rails 8.1 schema.rb oracle emits)}.
    def self.parse_index_columns(indexdef : String) : {Array(String), String?}?
      m = indexdef.match(/ USING \w+ \((.+?)\)(?: WHERE (.+))?\z/)
      return nil unless m
      {m[1].split(", ").map { |c| unquote(c) }, m[2]?}
    end

    def self.fk_line(from : String, name : String, defn : String) : String
      m = defn.match(/\AFOREIGN KEY \((.+?)\) REFERENCES (.+?)\((.+?)\)\z/)
      return "" unless m
      column, to_table = m[1], m[2]
      parts = [] of String
      parts << "column: #{column.inspect}" unless column == Migrations.singularize(to_table) + "_id"
      parts << "name: #{name.inspect}" unless name == Migrations.fk_name(from, column)
      suffix = parts.empty? ? "" : ", #{parts.join(", ")}"
      "  add_foreign_key #{from.inspect}, #{to_table.inspect}#{suffix}\n"
    end

    def self.unquote(ident : String) : String
      ident.starts_with?("\"") ? ident[1..-2].gsub("\"\"", "\"") : ident
    end

    # 20261001000008 → 2026_10_01_000008 (Rails date-like grouping)
    def self.format_version(version : Int64) : String
      s = version.to_s
      s.size == 14 ? "#{s[0, 4]}_#{s[4, 2]}_#{s[6, 2]}_#{s[8, 6]}" : s
    end
  end
end
