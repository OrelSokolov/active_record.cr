# Migrations oracle: runs a fixed set of migrations with the ORIGINAL
# activerecord 8.1.4 and dumps the resulting schema in a normalized form.
# The Crystal port must reproduce the dumps exactly (spec/migrations_spec.cr).
#
#   ruby oracle/migrations.rb > oracle/migrations_expected.yml
#
# Dumps: BASE (empty db), UP (all migrated), STEP1 (one rollback), DOWN
# (rolled back to zero).

require "active_record"
require "yaml"

ActiveRecord::Base.establish_connection(
  adapter: "postgresql",
  host: "/var/run/postgresql",
  database: "crails_ar_mig",
)

# --- the migration set (mirrored 1:1 in spec/migrations_spec.cr) ------

class CreatePosts < ActiveRecord::Migration[8.1]
  def change
    create_table :posts do |t|
      t.string :title, null: false
      t.text :body
      t.integer :views, default: 0, null: false
      t.float :score
      t.decimal :rating, precision: 8, scale: 2
      t.boolean :published, default: false, null: false
      t.datetime :published_at
      t.date :published_on
      t.time :deadline
      t.jsonb :tags, default: []
      t.timestamps
      t.index :published
    end
  end
end

class CreateAuthors < ActiveRecord::Migration[8.1]
  def change
    create_table :authors do |t|
      t.string :name, null: false
      t.string :email
      t.float :ratio
      t.json :meta
      t.uuid :guid
      t.binary :blob_data
      t.timestamps
      t.index :email, unique: true
    end
  end
end

class CreateComments < ActiveRecord::Migration[8.1]
  def change
    create_table :comments do |t|
      t.references :post, foreign_key: true
      t.string :body, null: false
      t.timestamps
    end
  end
end

class AlterPosts < ActiveRecord::Migration[8.1]
  def change
    add_reference :posts, :author, index: true
    add_column :posts, :slug, :string
    add_index :posts, :slug, unique: true
    rename_column :posts, :body, :content
    change_column_default :posts, :views, 5
    change_column_null :posts, :slug, false
    remove_column :posts, :score
    add_foreign_key :posts, :authors
  end
end

class ModifyPosts < ActiveRecord::Migration[8.1]
  def change
    change_table :posts do |t|
      t.string :tagline
      t.remove :published_on
      t.index :tagline
    end
    create_join_table :posts, :tags
    add_check_constraint :posts, "views >= 0", name: "posts_views_check"
  end
end

class CreateTempThings < ActiveRecord::Migration[8.1]
  def change
    create_table :temp_things do |t|
      t.string :note
    end
  end
end

class DropTempThings < ActiveRecord::Migration[8.1]
  def change
    drop_table :temp_things
  end
end

class PartialAndReversible < ActiveRecord::Migration[8.1]
  def change
    add_index :posts, :title, where: "views > 0"
    reversible do |dir|
      dir.up   { execute "CREATE TABLE rev_marks (id bigserial PRIMARY KEY, note text)" }
      dir.down { execute "DROP TABLE IF EXISTS rev_marks" }
    end
    change_table :posts do |t|
      t.index :content, where: "views > 0"
    end
  end
end

class LegacyWidgets < ActiveRecord::Migration[8.1]
  def up
    execute "CREATE TABLE legacy_widgets (id bigserial PRIMARY KEY, note text)"
  end

  def down
    execute "DROP TABLE legacy_widgets"
  end
end

MIGRATIONS = [CreatePosts, CreateAuthors, CreateComments, AlterPosts,
              ModifyPosts, CreateTempThings, DropTempThings,
              PartialAndReversible, LegacyWidgets]

# --- normalized schema dump (mirror this format in the Crystal port) ---

def dump_schema(conn)
  cols = conn.select_all(<<~SQL).to_a
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
  SQL
  idx = conn.select_all(<<~SQL).to_a
    SELECT tablename, indexname, indexdef
    FROM pg_indexes
    WHERE schemaname = 'public' AND tablename <> 'schema_migrations'
    ORDER BY tablename, indexname
  SQL
  fks = conn.select_all(<<~SQL).to_a
    SELECT conrelid::regclass::text AS rel, conname, pg_get_constraintdef(oid) AS def
    FROM pg_constraint
    WHERE contype = 'f' AND connamespace = 'public'::regnamespace
    ORDER BY conrelid::regclass::text, conname
  SQL

  {
    "columns" => cols.map { |c|
      "#{c['table_name']}.#{c['column_name']} #{c['udt_name']}(#{c['len']},#{c['nprec']},#{c['nscale']},#{c['dprec']}) null=#{c['is_nullable']} default=#{c['column_default'].inspect}"
    },
    "indexes" => idx.map { |i| "#{i['tablename']}.#{i['indexname']}: #{i['indexdef'].gsub('"', '')}" },
    "fks" => fks.map { |f| "#{f['rel']}.#{f['conname']}: #{f['def'].gsub('"', '')}" },
  }
end

def report(tag)
  puts "=== #{tag}"
  dump_schema(ActiveRecord::Base.connection).each do |section, lines|
    puts "-- #{section}"
    lines.each { |l| puts l }
  end
end

conn = ActiveRecord::Base.connection
conn.execute(<<~SQL).each { |r| conn.execute("DROP TABLE IF EXISTS #{r['tablename']} CASCADE") }
  SELECT tablename FROM pg_tables WHERE schemaname = 'public'
SQL
report("BASE")

def run_all(direction, migrations)
  migrations.each_with_index do |m, i|
    migration = m.new
    migration.version = 20_261_001_000_000 + i
    migration.migrate(direction)
  end
end

run_all(:up, MIGRATIONS)
report("UP")

step1 = MIGRATIONS.last.new
step1.version = 20_261_001_000_000 + MIGRATIONS.size - 1
step1.migrate(:down)
report("STEP1")

# LegacyWidgets was already rolled back in STEP1; #migrate (unlike the
# Migrator) does not consult schema_migrations, so skip it here.
# A block-less drop_table raises IrreversibleMigration on rollback — the
# port must reproduce that; we capture the marker and dump the stopped state.
MIGRATIONS[0..-2].reverse.each_with_index do |m, i|
  migration = m.new
  migration.version = 20_261_001_000_000 + (MIGRATIONS.size - 2 - i)
  begin
    migration.migrate(:down)
  rescue ActiveRecord::IrreversibleMigration => e
    puts "== IRREVERSIBLE #{m}: #{e.message.lines.first&.strip}"
    break
  end
end
report("DOWN")
