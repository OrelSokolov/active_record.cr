# Schema oracle: runs the SAME migration set as oracle/migrations.rb with
# the ORIGINAL activerecord 8.1.4 and captures its db/schema.rb dump.
# The Crystal port must reproduce that dump in db/schema.cr syntax 1:1
# (spec/schema_spec.cr), modulo the documented mechanical tweaks below.
#
#   ruby oracle/schema.rb > oracle/schema_expected.cr
#
# Tweaks applied to the Rails dump (Ruby → Crystal, nothing else):
#   * `require "active_record_cr"` prepended (schema.cr is self-contained);
#   * `default: []` → `default: [] of Int64` (empty Crystal array literal
#     needs a type).

require "active_record"

ActiveRecord::Base.establish_connection(
  adapter: "postgresql",
  host: "/var/run/postgresql",
  database: "crails_ar_schema",
  username: "root",
)

# --- the migration set (mirror of oracle/migrations.rb) ----------------------

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

# --- run everything up, then capture Rails' own schema dump -----------------

conn = ActiveRecord::Base.connection
conn.execute(<<~SQL).each { |r| conn.execute("DROP TABLE IF EXISTS #{r['tablename']} CASCADE") }
  SELECT tablename FROM pg_tables WHERE schemaname = 'public'
SQL

# The harness calls migrate() directly (no Migrator), so record the versions
# in schema_migrations ourselves — the way both real `db:migrate` and the
# Crystal Migrator do — otherwise Rails dumps define(version: 0).
ActiveRecord::Migration.verbose = false
MIGRATIONS.each_with_index do |m, i|
  migration = m.new
  migration.version = 20_261_001_000_000 + i
  migration.migrate(:up)
end
conn.execute(%(CREATE TABLE IF NOT EXISTS schema_migrations (version bigint NOT NULL PRIMARY KEY)))
MIGRATIONS.each_with_index do |m, i|
  conn.execute(%(INSERT INTO schema_migrations (version) VALUES (#{20_261_001_000_000 + i})))
end

require "stringio"
io = StringIO.new
ActiveRecord::SchemaDumper.dump(ActiveRecord::Base.connection_pool, io)
io.rewind

crystal = io.read
  .gsub("default: []", "default: [] of Int64")    # typed empty-array literal
  .sub(/\A/, %{require "active_record_cr"\n\n})

puts crystal
