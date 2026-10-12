require "active_record_cr"

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

ActiveRecord::Schema[8.1].define(version: 2026_10_01_000008) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "authors", force: :cascade do |t|
    t.string "name", null: false
    t.string "email"
    t.float "ratio"
    t.json "meta"
    t.uuid "guid"
    t.binary "blob_data"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_authors_on_email", unique: true
  end

  create_table "comments", force: :cascade do |t|
    t.bigint "post_id"
    t.string "body", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["post_id"], name: "index_comments_on_post_id"
  end

  create_table "legacy_widgets", force: :cascade do |t|
    t.text "note"
  end

  create_table "posts", force: :cascade do |t|
    t.string "title", null: false
    t.text "content"
    t.integer "views", default: 5, null: false
    t.decimal "rating", precision: 8, scale: 2
    t.boolean "published", default: false, null: false
    t.datetime "published_at"
    t.time "deadline"
    t.jsonb "tags", default: [] of Int64
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "author_id"
    t.string "slug", null: false
    t.string "tagline"
    t.index ["author_id"], name: "index_posts_on_author_id"
    t.index ["content"], name: "index_posts_on_content", where: "(views > 0)"
    t.index ["published"], name: "index_posts_on_published"
    t.index ["slug"], name: "index_posts_on_slug", unique: true
    t.index ["tagline"], name: "index_posts_on_tagline"
    t.index ["title"], name: "index_posts_on_title", where: "(views > 0)"
    t.check_constraint "views >= 0", name: "posts_views_check"
  end

  create_table "posts_tags", id: false, force: :cascade do |t|
    t.bigint "post_id", null: false
    t.bigint "tag_id", null: false
  end

  create_table "rev_marks", force: :cascade do |t|
    t.text "note"
  end

  add_foreign_key "comments", "posts"
  add_foreign_key "posts", "authors"
end
