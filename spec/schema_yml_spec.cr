# db/schema.yml index oracle spec: the YAML dump must carry the full index
# set (name/columns/unique/where) of every table. The oracle is the database
# itself — pg_indexes/pg_index introspection, independent of the dumper code
# path. Round-trip: the YAML data alone must be able to rebuild every index
# (drop all non-PK indexes → CREATE INDEX from the YAML → re-dump → identical).

require "spec"
require "../src/active_record_cr"
require "./support/migration_set"

YML_DB_URL = "postgres://root@/crails_ar_yml?host=/var/run/postgresql"

def reset_yml_db(conn)
  conn.query_all(%(SELECT tablename FROM pg_tables WHERE schemaname = 'public'),
    as: String).each do |t|
    conn.exec(%(DROP TABLE IF EXISTS "#{t}" CASCADE))
  end
end

# Oracle inventory from pg_indexes: table → sorted "name|unique|cols|where"
# lines, parsed straight out of indexdef (implicit PK indexes skipped via
# pg_index.indisprimary).
def yml_oracle_inventory(conn) : Hash(String, Array(String))
  pks = conn.query_all(%(
    SELECT c.relname AS tbl, i.relname AS idx
    FROM pg_index x
    JOIN pg_class c ON c.oid = x.indrelid
    JOIN pg_class i ON i.oid = x.indexrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE x.indisprimary AND n.nspname = 'public'
  ), as: {String, String}).to_h

  conn.query_all(%(
    SELECT tablename, indexname, indexdef
    FROM pg_indexes
    WHERE schemaname = 'public'
      AND tablename NOT IN ('schema_migrations', 'ar_internal_metadata')
    ORDER BY tablename, indexname
  ), as: {String, String, String})
    .reject { |(table, name, _)| pks[table]? == name }
    .map do |(table, name, defn)|
      unique = defn.starts_with?("CREATE UNIQUE INDEX")
      m = defn.match(/ USING \w+ \((.+?)\)(?: WHERE (.+))?\z/)
      raise "oracle parse failed: #{defn}" unless m
      cols = m[1].split(", ").map { |c| c.delete('"') }
      where = m[2]?
      {table, "#{name}|#{unique}|#{cols.join(",")}|#{where}"}
    end
    .group_by(&.[0])
    .transform_values(&.map(&.[1]))
end

# The same inventory read back from a dumped schema.yml.
def yml_dumped_inventory(path : String) : Hash(String, Array(String))
  yaml = YAML.parse(File.read(path))
  yaml.as_h.keys.each_with_object({} of String => Array(String)) do |table, inv|
    lines = [] of String
    yaml[table]["indexes"]?.try(&.as_a?).try &.each do |idx|
      lines << "#{idx["name"].as_s}|#{idx["unique"].as_bool}|" \
               "#{idx["columns"].as_a.map(&.as_s).join(",")}|#{idx["where"]?.try(&.as_s?)}"
    end
    inv[table.as_s] = lines.sort unless lines.empty?
  end
end

describe "ActiveRecord db/schema.yml indexes (oracle: pg_indexes)" do
  it "dumps every index with name/columns/unique/where" do
    ActiveRecord::Base.establish_connection(YML_DB_URL)
    conn = ActiveRecord::Base.connection

    reset_yml_db(conn)
    MIGRATIONS.each_with_index do |m, i|
      m.new(20_261_002_000_000 + i).migrate(:up)
    end

    path = File.join(Dir.tempdir, "crails_ar_schema_yml_#{Process.pid}.yml")
    begin
      tables = ActiveRecord::SchemaDumper.dump_to_file(path)
      tables.should be > 0

      yml_dumped_inventory(path).should eq(yml_oracle_inventory(conn))

      # spot checks against the migration set (support/migration_set.cr):
      # partial, unique and reference indexes survive the round parse
      posts = yml_dumped_inventory(path)["posts"]
      posts.should contain("index_posts_on_slug|true|slug|")
      posts.should contain("index_posts_on_title|false|title|(views > 0)")
      posts.should contain("index_posts_on_author_id|false|author_id|")
      authors = yml_dumped_inventory(path)["authors"]
      authors.should contain("index_authors_on_email|true|email|")
      # implicit PK indexes must NOT leak into the YAML
      File.read(path).should_not contain("pkey")
      # schema_migrations is not a dumped table
      YAML.parse(File.read(path))["schema_migrations"]?.should be_nil
    ensure
      File.delete(path) if File.exists?(path)
    end
  end

  it "round-trips: YAML alone rebuilds every index (drop → create → re-dump)" do
    ActiveRecord::Base.establish_connection(YML_DB_URL)
    conn = ActiveRecord::Base.connection

    path1 = File.join(Dir.tempdir, "crails_ar_schema_yml_#{Process.pid}_1.yml")
    path2 = File.join(Dir.tempdir, "crails_ar_schema_yml_#{Process.pid}_2.yml")
    begin
      ActiveRecord::SchemaDumper.dump_to_file(path1)

      # wipe every non-PK index, then recreate purely from the YAML
      pks = conn.query_all(%(
        SELECT c.relname AS tbl, i.relname AS idx
        FROM pg_index x
        JOIN pg_class c ON c.oid = x.indrelid
        JOIN pg_class i ON i.oid = x.indexrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE x.indisprimary AND n.nspname = 'public'
      ), as: {String, String}).to_h
      conn.query_all(%(
        SELECT tablename, indexname FROM pg_indexes
        WHERE schemaname = 'public'
          AND tablename NOT IN ('schema_migrations', 'ar_internal_metadata')
      ), as: {String, String}).each do |(table, iname)|
        next if pks[table]? == iname
        conn.exec(%(DROP INDEX IF EXISTS "#{iname}"))
      end
      yml_oracle_inventory(conn).should be_empty

      yaml = YAML.parse(File.read(path1))
      yaml.as_h.each do |table, data|
        data["indexes"]?.try(&.as_a?).try &.each do |idx|
          unique = idx["unique"].as_bool ? "UNIQUE " : ""
          cols = idx["columns"].as_a.map { |c| %("#{c.as_s}") }.join(", ")
          where = idx["where"]?.try(&.as_s?).try { |w| " WHERE #{w}" } || ""
          conn.exec(%(CREATE #{unique}INDEX "#{idx["name"].as_s}" ) +
                    %(ON "#{table.as_s}" (#{cols})#{where}))
        end
      end

      ActiveRecord::SchemaDumper.dump_to_file(path2)
      File.read(path2).should eq(File.read(path1))
    ensure
      File.delete(path1) if File.exists?(path1)
      File.delete(path2) if File.exists?(path2)
    end
  end
end
