# Rails scopes port specs: lambda-format `scope :x, -> {}`, relation
# chaining (method_missing + merge), nested preload/includes hashes,
# has_rich_text and preloadable_attachment.
#
# Runs as its own compilation with the scopes fixture schema pinned:
#
#   CRAILS_SCHEMA=spec/fixtures/scopes_schema.yml \
#     crystal spec spec/scopes_spec.cr
{% if env("CRAILS_SCHEMA") %}
require "spec"
require "file_utils"
require "../src/active_record_cr"

DB_PATH = File.join(Dir.tempdir, "crails_ar_scopes_spec_#{Process.pid}.sqlite3")

class Room < ActiveRecord::Base
end

class User < ActiveRecord::Base
  preloadable_attachment :avatar
end

class ActionTextRichText < ActiveRecord::Base
end

class ActiveStorageBlob < ActiveRecord::Base
end

class ActiveStorageAttachment < ActiveRecord::Base
end

class Boost < ActiveRecord::Base
  belongs_to :message
  belongs_to :booster, class_name: "User"
end

class Message < ActiveRecord::Base
  belongs_to :room
  belongs_to :creator, class_name: "User"
  has_many :boosts, foreign_key: "message_id"
  has_rich_text :body

  scope :ordered, -> { order(:created_at) }
  scope :in_room, ->(rid) { where("room_id = ?", rid) }
  scope :with_creator, -> { preload(creator: :avatar_attachment) }
  scope :with_boosts, -> { includes(boosts: { booster: :avatar_attachment }) }
  scope :with_presentation, -> { with_creator.with_boosts.preload(:room) }

  # block form still supported (backward compatibility)
  scope(:newest) { order("created_at DESC") }
end

def ts(seconds : Int32) : Time
  Time.utc(2024, 1, 1, 12, 0, seconds)
end

describe "Rails scopes port" do
  before_all do
    FileUtils.rm_f(DB_PATH)
    FileUtils.rm_f("#{DB_PATH}-wal")
    FileUtils.rm_f("#{DB_PATH}-shm")
    ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: DB_PATH)
    conn = ActiveRecord::Base.connection
    conn.exec(<<-SQL)
      CREATE TABLE users (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name VARCHAR,
        created_at DATETIME
      )
    SQL
    conn.exec(<<-SQL)
      CREATE TABLE rooms (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name VARCHAR NOT NULL
      )
    SQL
    conn.exec(<<-SQL)
      CREATE TABLE messages (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        room_id INTEGER NOT NULL,
        creator_id INTEGER,
        created_at DATETIME
      )
    SQL
    conn.exec(<<-SQL)
      CREATE TABLE boosts (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        message_id INTEGER NOT NULL,
        booster_id INTEGER
      )
    SQL
    conn.exec(<<-SQL)
      CREATE TABLE action_text_rich_texts (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        record_type VARCHAR NOT NULL,
        record_id INTEGER NOT NULL,
        name VARCHAR NOT NULL,
        body TEXT
      )
    SQL
    conn.exec(<<-SQL)
      CREATE TABLE active_storage_attachments (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name VARCHAR NOT NULL,
        record_type VARCHAR NOT NULL,
        record_id INTEGER NOT NULL,
        blob_id INTEGER NOT NULL
      )
    SQL
    conn.exec(<<-SQL)
      CREATE TABLE active_storage_blobs (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        filename VARCHAR
      )
    SQL

    Room.create({"name" => "design"})
    alice = User.create({"name" => "alice"})
    bob = User.create({"name" => "bob"})
    ActiveStorageBlob.create({"filename" => "alice.png"})
    ActiveStorageAttachment.create({
      "name" => "avatar", "record_type" => "User",
      "record_id" => alice.id.not_nil!, "blob_id" => 1_i64})
    m1 = Message.create({"room_id" => 1_i64, "creator_id" => alice.id, "created_at" => ts(10)})
    m2 = Message.create({"room_id" => 1_i64, "creator_id" => bob.id, "created_at" => ts(20)})
    Message.create({"room_id" => 2_i64, "creator_id" => alice.id, "created_at" => ts(30)})
    Boost.create({"message_id" => m1.id.not_nil!, "booster_id" => bob.id})
  end

  after_all do
    ActiveRecord::Base.connection.close
    FileUtils.rm_f(DB_PATH)
    FileUtils.rm_f("#{DB_PATH}-wal")
    FileUtils.rm_f("#{DB_PATH}-shm")
  end

  it "lambda scope: order + symbol column" do
    ids = Message.ordered.map(&.id)
    ids.should eq([1_i64, 2_i64, 3_i64])
  end

  it "block scope form still works" do
    Message.newest.first.not_nil!.id.should eq(3_i64)
  end

  it "parameterized lambda scope" do
    Message.in_room(2_i64).map(&.id).should eq([3_i64])
  end

  it "scope chains off a relation (AND semantics)" do
    rel = Message.where("room_id = ?", 1_i64).ordered
    rel.map(&.id).should eq([1_i64, 2_i64])
    # a second scope on the relation keeps the where
    rel2 = Message.where("room_id = ?", 1_i64).in_room(2_i64)
    rel2.map(&.id).should eq([] of Int64)
  end

  it "merge combines where/order/includes" do
    sql = Message.where("room_id = ?", 1_i64).merge(Message.ordered).to_sql
    sql.should contain("room_id")
    sql.should contain("created_at")
  end

  it "nested preload hash: includes(boosts: :booster)" do
    msg = Message.includes(boosts: :booster).where("id = ?", 1_i64).first.not_nil!
    boosts = msg.boosts.to_a
    boosts.size.should eq(1)
    boost = boosts.first
    # both levels preloaded (no lazy query needed)
    boost.__cached_assoc_record("booster").should_not be_nil
    boost.booster.not_nil!.name.should eq("bob")
  end

  it "nested preload hash with attachment leaf: preload(creator: :avatar_attachment)" do
    msg = Message.preload(creator: :avatar_attachment).where("id = ?", 1_i64).first.not_nil!
    creator = msg.creator.not_nil!
    creator.__cached_assoc_record("avatar_attachment").should_not be_nil
    creator.avatar_attachment.not_nil!.blob_id.should eq(1_i64)
    creator.avatar_blob.not_nil!.filename.should eq("alice.png")
    # no attachment for bob — reader falls back to a query and returns nil
    msg2 = Message.where("id = ?", 2_i64).first.not_nil!
    msg2.creator.not_nil!.avatar_attachment.should be_nil
  end

  it "mixed preload: preload(:room, creator: :avatar_attachment)" do
    msg = Message.preload(:room, creator: :avatar_attachment).first.not_nil!
    msg.__cached_assoc_record("room").should_not be_nil
    msg.room.not_nil!.name.should eq("design")
  end

  it "three-level nested preload: includes(boosts: { booster: :avatar_attachment })" do
    msg = Message.with_boosts.where("id = ?", 1_i64).first.not_nil!
    boost = msg.boosts.first.not_nil!
    booster = boost.booster.not_nil!
    booster.name.should eq("bob")
    booster.__cached_assoc_record("avatar_attachment").should be_nil # bob has none
    # alice (message 1 creator) via with_creator gets hers
    msg2 = Message.with_creator.where("id = ?", 1_i64).first.not_nil!
    msg2.creator.not_nil!.__cached_assoc_record("avatar_attachment").should_not be_nil
  end

  it "scope composed of scopes (with_presentation) merges includes" do
    sql = Message.with_presentation.to_sql
    sql.should contain("messages")
    msg = Message.with_presentation.where("id = ?", 1_i64).first.not_nil!
    msg.__cached_assoc_record("room").should_not be_nil
    msg.__cached_assoc_record("creator").should_not be_nil
    msg.boosts.to_a.size.should eq(1)
  end

  it "has_rich_text reader/writer" do
    msg = Message.create({"room_id" => 1_i64})
    msg.body = "<h1>hello</h1>"
    msg.save
    row = ActionTextRichText.where("record_type = ? AND record_id = ? AND name = ?",
      "Message", msg.id.not_nil!, "body").take
    row.not_nil!.body.should eq("<h1>hello</h1>")

    fresh = Message.find(msg.id.not_nil!)
    fresh.body.should eq("<h1>hello</h1>")
    fresh.rich_text_body.not_nil!.body.should eq("<h1>hello</h1>")

    # update path rewrites the row
    fresh.body = "<p>bye</p>"
    fresh.save
    ActionTextRichText.where("record_type = ? AND record_id = ?",
      "Message", msg.id.not_nil!).to_a.size.should eq(1)
    Message.find(msg.id.not_nil!).body.should eq("<p>bye</p>")
  end

  it "with_rich_text_body preloads the rich text row" do
    ActionTextRichText.create({
      "record_type" => "Message", "record_id" => 1_i64,
      "name"        => "body", "body" => "preloaded!"})
    msg = Message.with_rich_text_body.where("id = ?", 1_i64).first.not_nil!
    msg.__cached_assoc_record("rich_text_body").should_not be_nil
    # reader serves from the preload cache even after a direct row rewrite
    conn = ActiveRecord::Base.connection
    conn.exec("UPDATE action_text_rich_texts SET body = 'rewritten' WHERE record_id = 1")
    msg.body.should eq("preloaded!")
  end

  it "with_rich_text_body_and_embeds is the same preload" do
    ActionTextRichText.create({
      "record_type" => "Message", "record_id" => 2_i64,
      "name" => "body", "body" => "embeds"})
    msg = Message.with_rich_text_body_and_embeds.where("id = ?", 2_i64).first.not_nil!
    msg.__cached_assoc_record("rich_text_body").should_not be_nil
    msg.body.should eq("embeds")
  end

  it "with_attached_avatar scope" do
    users = User.with_attached_avatar.to_a
    alice = users.find { |u| u.name == "alice" }.not_nil!
    alice.__cached_assoc_record("avatar_attachment").should_not be_nil
    alice.avatar_blob.not_nil!.filename.should eq("alice.png")
  end
end
{% end %}
