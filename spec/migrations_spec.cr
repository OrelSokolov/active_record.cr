# Migrations oracle spec: 1:1 mirror of oracle/migrations.rb. The expected
# dumps (BASE/UP/STEP1/DOWN) were captured from the ORIGINAL activerecord
# 8.1.4 on the scratch database crails_ar_mig — the port must reproduce them
# exactly, including the IrreversibleMigration on drop_table rollback.

require "spec"
require "../src/active_record_cr"

require "./support/migration_set"

# --- normalized schema dump (mirror of oracle/migrations.rb) ---------------

def dump_columns(conn) : Array(String)
  conn.query_all(%(
    SELECT c.table_name, c.column_name, c.udt_name, c.is_nullable, c.column_default,
           COALESCE(c.character_maximum_length::text, '') AS len,
           COALESCE(c.numeric_precision::text, '') AS nprec,
           COALESCE(c.numeric_scale::text, '') AS nscale,
           COALESCE(c.datetime_precision::text, '') AS dprec
    FROM information_schema.columns c
    JOIN information_schema.tables t
      ON t.table_schema = c.table_schema AND t.table_name = c.table_name
    WHERE c.table_schema = 'public' AND t.table_type = 'BASE TABLE'
    ORDER BY c.table_name, c.ordinal_position
  ), as: {String, String, String, String, String?, String, String, String, String})
    .map { |(t, c, udt, nullable, default, len, nprec, nscale, dprec)|
      "#{t}.#{c} #{udt}(#{len},#{nprec},#{nscale},#{dprec}) null=#{nullable} default=#{default.inspect}"
    }
end

def dump_indexes(conn) : Array(String)
  conn.query_all(%(
    SELECT tablename, indexname, indexdef
    FROM pg_indexes
    WHERE schemaname = 'public' AND tablename <> 'schema_migrations'
    ORDER BY tablename, indexname
  ), as: {String, String, String})
    .map { |(t, i, defn)| "#{t}.#{i}: #{defn.gsub('"', "")}" }
end

def dump_fks(conn) : Array(String)
  conn.query_all(%(
    SELECT conrelid::regclass::text AS rel, conname, pg_get_constraintdef(oid) AS def
    FROM pg_constraint
    WHERE contype = 'f' AND connamespace = 'public'::regnamespace
    ORDER BY conrelid::regclass::text, conname
  ), as: {String, String, String})
    .map { |(rel, con, defn)| "#{rel}.#{con}: #{defn.gsub('"', "")}" }
end

def report(conn, tag : String) : Array(String)
  lines = [] of String
  {"columns" => dump_columns(conn), "indexes" => dump_indexes(conn),
   "fks" => dump_fks(conn)}.each do |section, rows|
    lines << "-- #{section}"
    lines.concat(rows)
  end
  lines
end

# Parse expected.yml: sections start with "=== TAG"; migration log lines
# ("== 2026...", "   ->") are skipped; the IRREVERSIBLE marker is compared.
def parse_expected(path : String) : Hash(String, Array(String))
  sections = Hash(String, Array(String)).new
  current = ""
  pending_irreversible = ""
  File.read_lines(path).each do |line|
    if line.starts_with?("=== ")
      current = line[4..]
      sections[current] = [] of String
      sections[current] << pending_irreversible unless pending_irreversible.empty?
      pending_irreversible = ""
    elsif {"-- columns", "-- indexes", "-- fks"}.includes?(line)
      sections[current] << line if current != ""
    elsif line.starts_with?("== IRREVERSIBLE ")
      # printed after the previous dump but before the next one — it
      # belongs to the FOLLOWING section (see oracle/migrations.rb flow);
      # keep only the class marker (messages differ between frameworks)
      pending_irreversible = line.split(':')[0].rstrip
    elsif line.starts_with?("== ") || line.starts_with?("   ->") || line.starts_with?("-- ")
      next # migration log noise (say-commands and timings)
    elsif current != "" && !line.strip.empty?
      sections[current] << line
    end
  end
  sections
end

describe "ActiveRecord migrations oracle (expected.yml from activerecord 8.1.4)" do
  it "reproduces BASE/UP/STEP1/DOWN schema dumps" do
    ActiveRecord::Base.establish_connection(
      "postgres://root@/crails_ar_mig?host=/var/run/postgresql")
    conn = ActiveRecord::Base.connection

    # reset: drop everything (schema_migrations included), like the oracle
    conn.query_all(%(SELECT tablename FROM pg_tables WHERE schemaname = 'public'),
      as: String).each do |t|
      conn.exec(%(DROP TABLE IF EXISTS "#{t}" CASCADE))
    end

    actual = {} of String => Array(String)
    actual["BASE"] = report(conn, "BASE")

    # up: all migrations in order (direct calls, mirroring the Ruby harness)
    MIGRATIONS.each_with_index do |m, i|
      migration = m.new(20_261_001_000_000 + i)
      migration.migrate(:up)
    end
    actual["UP"] = report(conn, "UP")

    # STEP1: roll the last migration back
    step1 = MIGRATIONS.last.new(20_261_001_000_000 + MIGRATIONS.size - 1)
    step1.migrate(:down)
    actual["STEP1"] = report(conn, "STEP1")

    # DOWN: rollback the rest; drop_table without a block is irreversible
    lines = [] of String
    MIGRATIONS[0..-2].reverse.each_with_index do |m, i|
      migration = m.new(20_261_001_000_000 + (MIGRATIONS.size - 2 - i))
      begin
        migration.migrate(:down)
      rescue e : ActiveRecord::IrreversibleMigration
        lines << "== IRREVERSIBLE #{m}"
        break
      end
    end
    down_report = report(conn, "DOWN")
    down_report.unshift(lines.first) unless lines.empty?
    actual["DOWN"] = down_report

    expected = parse_expected(File.join(__DIR__, "..", "oracle", "migrations_expected.yml"))

    expected.each do |tag, want|
      actual[tag].should eq(want), "#{tag}: got #{actual[tag].inspect}, want #{want.inspect}"
    end
  end
end
