# --- the migration set (mirror of oracle/migrations.rb) --------------------

class CreatePosts < ActiveRecord::Migration
  def change
    create_table :posts do |t|
      t.string :title, null: false
      t.text :body
      t.integer :views, default: 0_i64, null: false
      t.float :score
      t.decimal :rating, precision: 8, scale: 2
      t.boolean :published, default: false, null: false
      t.datetime :published_at
      t.date :published_on
      t.time :deadline
      t.jsonb :tags, default: [] of Int64
      t.timestamps
      t.index :published
    end
  end
end

class CreateAuthors < ActiveRecord::Migration
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

class CreateComments < ActiveRecord::Migration
  def change
    create_table :comments do |t|
      t.references :post, foreign_key: true
      t.string :body, null: false
      t.timestamps
    end
  end
end

class AlterPosts < ActiveRecord::Migration
  def change
    add_reference :posts, :author, index: true
    add_column :posts, :slug, :string
    add_index :posts, :slug, unique: true
    rename_column :posts, :body, :content
    change_column_default :posts, :views, 5_i64
    change_column_null :posts, :slug, false
    remove_column :posts, :score
    add_foreign_key :posts, :authors
  end
end

class ModifyPosts < ActiveRecord::Migration
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

class CreateTempThings < ActiveRecord::Migration
  def change
    create_table :temp_things do |t|
      t.string :note
    end
  end
end

class DropTempThings < ActiveRecord::Migration
  def change
    drop_table :temp_things
  end
end

class PartialAndReversible < ActiveRecord::Migration
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

class LegacyWidgets < ActiveRecord::Migration
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
