# SQLite adapter oracle specs (Campfire prerequisite): CRUD, placeholders,
# Rails 8 pragmas, FTS5 search and schema introspection — every read is
# cross-checked against the sqlite3 CLI as the independent oracle
# (AGENTS.md: synthetic cases + the original's own tooling).
#
# Models here compile-time-codegen from spec/fixtures/sqlite_schema.yml,
# so this suite runs as its own compilation with that schema pinned
# (the PG suites compile against db/schema.yml — one CRAILS_SCHEMA per
# compile). Without CRAILS_SCHEMA this file compiles empty:
#
#   CRAILS_SCHEMA=spec/fixtures/sqlite_schema.yml \
#     crystal spec spec/sqlite_oracle_spec.cr
{% if env("CRAILS_SCHEMA") %}
require "spec"
require "file_utils"
require "process"
require "../src/active_record_cr"

DB_PATH = File.join(Dir.tempdir, "crails_ar_sqlite_spec_#{Process.pid}.sqlite3")

# --- models (compile-time codegen via the fixture schema, exactly the
# --- production path; run with
# --- CRAILS_SCHEMA=spec/fixtures/sqlite_schema.yml) ---

class Room < ActiveRecord::Base
end

class Message < ActiveRecord::Base
end

# String-valued enum (Rails' enum :x, %w[...].index_by(&:itself), as used by
# the campfire oracle's Membership#involvement).
class Member < ActiveRecord::Base
  set_table_name "rooms"
  ar_enum :involvement, {invisible: "invisible", nothing: "nothing",
                         mentions: "mentions", everything: "everything"}
end

# has_json (ActiveModel::SchematizedJson port) on the same json column:
# boolean/integer/string keys — real values double as defaults, symbols
# default to nil (oracle: activemodel schematized_json.rb).
class Preference < ActiveRecord::Base
  set_table_name "rooms"
  has_json :settings, restrict_room_creation_to_administrators: false,
                      max_invites: :integer, greeting: "Hello!"
end

# sqlite3 CLI oracle: first column of the first row, or all rows joined.
module Oracle
  def self.cli(sql : String) : String
    out = `sqlite3 -readonly "#{DB_PATH}" "#{sql.gsub('"', %(\\"))}"`.strip
    out
  end

  def self.rows(sql : String) : Array(Array(String))
    output = `sqlite3 -readonly "#{DB_PATH}" "#{sql.gsub('"', %(\\"))}"`.strip
    return [] of Array(String) if output.empty?
    output.split('\n').map(&.split('|'))
  end
end

describe "ActiveRecord SQLite adapter (oracle: sqlite3 CLI)" do
  before_all do
    FileUtils.rm_f(DB_PATH)
    FileUtils.rm_f("#{DB_PATH}-wal")
    FileUtils.rm_f("#{DB_PATH}-shm")
    ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: DB_PATH)
    conn = ActiveRecord::Base.connection
    conn.exec(<<-SQL)
      CREATE TABLE rooms (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        kind VARCHAR NOT NULL DEFAULT 'open',
        settings JSON,
        involvement VARCHAR DEFAULT 'mentions',
        archived BOOLEAN NOT NULL DEFAULT 0,
        created_at DATETIME,
        updated_at DATETIME
      )
    SQL
    conn.exec(<<-SQL)
      CREATE TABLE messages (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        room_id INTEGER NOT NULL,
        body TEXT NOT NULL,
        client_message_id VARCHAR,
        pinned BOOLEAN NOT NULL DEFAULT 0,
        created_at DATETIME,
        updated_at DATETIME
      )
    SQL
    conn.exec("CREATE VIRTUAL TABLE message_search_index USING fts5(body)")
  end

  after_all do
    ActiveRecord::Base.connection.close
    FileUtils.rm_f(DB_PATH)
    FileUtils.rm_f("#{DB_PATH}-wal")
    FileUtils.rm_f("#{DB_PATH}-shm")
  end

  describe "connection pragmas (Rails 8 set)" do
    # journal_mode is persisted in the database file, so the independent
    # CLI connection sees it; synchronous/foreign_keys/journal_size_limit
    # are per-connection and must be read back through ActiveRecord's own
    # pooled connection.
    it "enables WAL journal mode" do
      Oracle.cli("PRAGMA journal_mode;").should eq("wal")
    end

    it "sets synchronous=NORMAL" do
      ActiveRecord::Base.connection.query_one("PRAGMA synchronous", as: Int64)
        .should eq(1_i64)
    end

    it "installs the fair busy handler over busy_timeout (0.1.4+)" do
      # configure_adapter runs PRAGMA busy_timeout first, then FairBusy
      # replaces that handler with uniform 500µs retries — sqlite resets
      # the timeout to 0 once a custom busy handler is installed, so 0
      # here PROVES the fair handler is the active one.
      ActiveRecord::Base.connection.query_one("PRAGMA busy_timeout", as: Int64)
        .should eq(0_i64)
    end

    it "sets journal_size_limit=64MB" do
      ActiveRecord::Base.connection.query_one("PRAGMA journal_size_limit", as: Int64)
        .should eq(67108864_i64)
    end

    it "enforces foreign keys" do
      ActiveRecord::Base.connection.query_one("PRAGMA foreign_keys", as: Int64)
        .should eq(1_i64)
    end

    it "keeps mmap off" do
      ActiveRecord::Base.connection.query_one("PRAGMA mmap_size", as: Int64)
        .should eq(0_i64)
    end

    it "creates a WAL sidecar file" do
      File.exists?("#{DB_PATH}-wal").should be_true
    end
  end

  describe "CRUD through AR, verified by CLI" do
    it "inserts and returns the autoincrement id" do
      room = Room.new(name: "Watercooler", kind: "open").tap(&.save!)
      room.id.should eq(1_i64)
      room = Room.new(name: "HQ", kind: "open", archived: true).tap(&.save!)
      room.id.should eq(2_i64)
      Oracle.cli("SELECT count(*) FROM rooms;").should eq("2")
      Oracle.rows("SELECT id, name, kind, archived FROM rooms ORDER BY id;")
        .should eq([["1", "Watercooler", "open", "0"], ["2", "HQ", "open", "1"]])
    end

    it "writes timestamps on create" do
      msg = Message.new(room_id: 1_i64, body: "coffee break",
        client_message_id: "abc-123").tap(&.save!)
      Oracle.cli("SELECT body FROM messages WHERE id = #{msg.id};")
        .should eq("coffee break")
      Oracle.cli("SELECT created_at IS NOT NULL AND updated_at IS NOT NULL FROM messages WHERE id = #{msg.id};")
        .should eq("1")
    end

    it "find by string id (junk strings raise, not crash)" do
      room = Room.new(name: "FindStr", kind: "open").tap(&.save!)
      Room.find(room.id.not_nil!.to_s).id.should eq(room.id)
      Room.find?(room.id.not_nil!.to_s).try(&.id).should eq(room.id)
      expect_raises(ActiveRecord::RecordNotFound, /Couldn't find/) { Room.find("abc") }
      Room.find?("abc").should be_nil
      Room.find?("999999").should be_nil
    end

    it "round-trips booleans as 0/1 integers" do
      msg = Message.new(room_id: 1_i64, body: "pin me", pinned: true).tap(&.save!)
      Oracle.cli("SELECT pinned FROM messages WHERE id = #{msg.id};").should eq("1")
      Message.find(msg.id.not_nil!).pinned?.should be_true
      msg.update!({"pinned" => false})
      Oracle.cli("SELECT pinned FROM messages WHERE id = #{msg.id};").should eq("0")
    end

    it "round-trips json columns (SQLite stores TEXT, reads as JSON::Any)" do
      room = Room.new(name: "JsonRoom", kind: "open").tap(&.save!)
      room.settings = JSON::Any.from_json(%({"restrict_room_creation_to_administrators":true}))
      room.save!
      Oracle.cli("SELECT settings FROM rooms WHERE id = #{room.id};")
        .should eq(%({"restrict_room_creation_to_administrators":true}))
      # re-read: TEXT column must decode to JSON::Any, not String
      reloaded = Room.find(room.id.not_nil!)
      reloaded.settings.should be_a(JSON::Any)
      reloaded.settings.try(&.["restrict_room_creation_to_administrators"].as_bool).should be_true
      # rewrite replaces the whole document
      reloaded.settings = JSON::Any.from_json(%({"other":"x"}))
      reloaded.save!
      Room.find(room.id.not_nil!).settings.try(&.["other"].as_s).should eq("x")
    end

    it "has_json: typed accessors, form-string casting and defaults" do
      pref = Preference.new(name: "Prefs", kind: "open")
      # defaults materialize on read (reverse-merge): real values only,
      # symbol-typed keys stay nil
      pref.settings.restrict_room_creation_to_administrators?.should be_false
      pref.settings.max_invites.should be_nil
      pref.settings.greeting.should eq("Hello!")
      pref.save!
      # before_save materialization persists the defaults the CLI can see
      Oracle.cli("SELECT settings FROM rooms WHERE id = #{pref.id};")
        .should eq(%({"restrict_room_creation_to_administrators":false,"max_invites":null,"greeting":"Hello!"}))

      # accessor writes cast UI strings to their schema type
      pref.settings.restrict_room_creation_to_administrators = "true"
      pref.settings.max_invites = "100"
      pref.settings.restrict_room_creation_to_administrators?.should be_true
      pref.settings.max_invites.should eq(100)
      pref["settings"].as(JSON::Any)["max_invites"].raw.should eq(100_i64)
      pref.save!
      reloaded = Preference.find(pref.id.not_nil!)
      reloaded.settings.restrict_room_creation_to_administrators?.should be_true
      reloaded.settings.max_invites.should eq(100)

      # update! through the column setter: per-key casting, symbol keys stay nil
      reloaded.update!({"settings" => JSON::Any.from_json(
        %({"restrict_room_creation_to_administrators":"false","max_invites":"5"}))})
      fresh = Preference.find(pref.id.not_nil!)
      fresh.settings.restrict_room_creation_to_administrators?.should be_false
      fresh.settings.max_invites.should eq(5)
      fresh.settings.greeting.should eq("Hello!")
      # unassigned keys keep their value (Rails merges per key)
      fresh.update!({"settings" => JSON::Any.from_json(%({"max_invites":"7"}))})
      Preference.find(pref.id.not_nil!).settings.max_invites.should eq(7)

      # unknown keys raise (Rails: NoMethodError from method_missing)
      expect_raises(ArgumentError, /undefined has_json key/) do
        reloaded.update!({"settings" => JSON::Any.from_json(%({"hax":1}))})
      end

      # legacy string values (written before the port) read as booleans
      ActiveRecord::Base.connection.exec(
        %(UPDATE rooms SET settings = '{"restrict_room_creation_to_administrators":"false"}' WHERE id = #{pref.id}))
      Preference.find(pref.id.not_nil!)
        .settings.restrict_room_creation_to_administrators?.should be_false
    end

    it "updates rows the CLI can see" do
      msg = Message.new(room_id: 2_i64, body: "before edit").tap(&.save!)
      msg.update!({"body" => "after edit"})
      Oracle.cli("SELECT body FROM messages WHERE id = #{msg.id};")
        .should eq("after edit")
    end

    it "deletes rows" do
      msg = Message.new(room_id: 2_i64, body: "doomed").tap(&.save!)
      msg.destroy
      Oracle.cli("SELECT count(*) FROM messages WHERE id = #{msg.id};").should eq("0")
    end

    it "reads through where/order/limit matching CLI expectations" do
      Message.new(room_id: 1_i64, body: "one").tap(&.save!)
      Message.new(room_id: 1_i64, body: "two").tap(&.save!)
      Message.new(room_id: 2_i64, body: "three").tap(&.save!)
      ar_ids = Message.where("room_id = ?", 1_i64).order("id DESC").limit(2)
        .map(&.id.not_nil!)
      cli_ids = Oracle.rows(
        "SELECT id FROM messages WHERE room_id = 1 ORDER BY id DESC LIMIT 2;")
        .map { |r| r[0].to_i64 }
      ar_ids.should eq(cli_ids)
      ar_ids.size.should eq(2)
    end
  end

  describe "FTS5 search parity with CLI" do
    it "matches MATCH queries identically" do
      conn = ActiveRecord::Base.connection
      {10_i64, "coffee break now"}.tap do |id, body|
        conn.exec("INSERT INTO message_search_index (rowid, body) VALUES ($1, $2)", id, body)
      end
      {11_i64, "tea time later"}.tap do |id, body|
        conn.exec("INSERT INTO message_search_index (rowid, body) VALUES ($1, $2)", id, body)
      end
      {12_i64, "more coffee please"}.tap do |id, body|
        conn.exec("INSERT INTO message_search_index (rowid, body) VALUES ($1, $2)", id, body)
      end

      ar_ids = conn.query_all(
        "SELECT rowid FROM message_search_index WHERE message_search_index MATCH $1 ORDER BY rowid",
        "coffee", as: Int64)
      cli_ids = Oracle.rows(
        "SELECT rowid FROM message_search_index WHERE message_search_index MATCH 'coffee' ORDER BY rowid;")
        .map { |r| r[0].to_i64 }
      ar_ids.should eq([10_i64, 12_i64])
      ar_ids.should eq(cli_ids)
    end
  end

  describe "string-valued enum (oracle: Membership#involvement)" do
    it "accepts valid values through .new and the setter" do
      m = Member.new(name: "enum1", kind: "open", involvement: "mentions")
      m.involvement.should eq("mentions")
      m.involvement = :everything
      m.involvement.should eq("everything")
    end

    it "raises ArgumentError on invalid values (setter, .new, update)" do
      expect_raises(ArgumentError) do
        Member.new(name: "enum2", kind: "open", involvement: "member")
      end
      m = Member.new(name: "enum3", kind: "open")
      expect_raises(ArgumentError) { m.involvement = "member" }
      expect_raises(ArgumentError) { m.assign_attributes({"involvement" => "member"}) }
    end

    it "round-trips through the database and scopes by value" do
      m = Member.new(name: "enum4", kind: "open", involvement: "everything").tap(&.save!)
      Member.find(m.id.not_nil!).involvement.should eq("everything")
      Member.everything.where("name = 'enum4'").count.should eq(1)
      m.everything?.should be_true
    end

    it "reads legacy junk rows as nil (oracle-verified, no raise)" do
      conn = ActiveRecord::Base.connection
      conn.exec("INSERT INTO rooms (name, kind, involvement) VALUES ('enum5', 'open', 'member')")
      junk = Member.all.where("name = 'enum5'").first.not_nil!
      junk.involvement.should be_nil
    end

    it "exposes the value mapping" do
      Member.involvements.should eq({
        "invisible" => "invisible", "nothing" => "nothing",
        "mentions"  => "mentions",  "everything" => "everything"})
    end
  end

  describe "schema introspection (schema.yml for codegen)" do
    it "dumps tables with normalized udt types" do
      path = File.join(Dir.tempdir, "crails_ar_sqlite_schema_#{Process.pid}.yml")
      begin
        tables = ActiveRecord::SchemaDumper.dump_to_file(path)
        tables.should eq(2) # rooms + messages (fts shadow tables skipped)
        yaml = YAML.parse(File.read(path))
        rooms = yaml["rooms"]["columns"].as_a.map { |c|
          {c["name"].as_s, c["type"].as_s, c["nullable"].as_s}
        }
        rooms.should contain({"name", "text", "NO"})
        rooms.should contain({"kind", "varchar", "NO"})
        rooms.should contain({"archived", "bool", "NO"})
        rooms.should contain({"created_at", "timestamp", "YES"})
        messages = yaml["messages"]["columns"].as_a.map { |c|
          {c["name"].as_s, c["type"].as_s}
        }
        messages.should contain({"room_id", "int4"})
        messages.should contain({"body", "text"})
        messages.should contain({"client_message_id", "varchar"})
      ensure
        FileUtils.rm_f(path)
      end
    end

    it "dumps indexes with unique/where (oracle: sqlite3 CLI)" do
      conn = ActiveRecord::Base.connection
      conn.exec(%(CREATE INDEX "index_messages_on_room_id" ON "messages" ("room_id")))
      conn.exec(%(CREATE UNIQUE INDEX "index_messages_on_client_message_id" ON "messages" ("client_message_id")))
      conn.exec(%(CREATE INDEX "index_messages_on_pinned" ON "messages" ("pinned") WHERE pinned = 1))

      path = File.join(Dir.tempdir, "crails_ar_sqlite_schema_#{Process.pid}.yml")
      begin
        ActiveRecord::SchemaDumper.dump_to_file(path)
        yaml = YAML.parse(File.read(path))

        # CLI oracle: PRAGMA index_list rows (seq|name|unique|origin|partial)
        # for the dumped names/uniques; origin 'pk' would be an implicit PK
        cli = Oracle.rows("PRAGMA index_list(messages);")
               .map(&.[](1..2)) # name, unique flag
               .to_h
        dumped = yaml["messages"]["indexes"].as_a.map { |i|
          {i["name"].as_s, i["unique"].as_bool ? "1" : "0"}
        }.to_h
        dumped.should eq(cli)

        # partial-index predicate straight from sqlite_master via the CLI
        sql = Oracle.cli(
          %(SELECT sql FROM sqlite_master WHERE name = 'index_messages_on_pinned';))
        where = yaml["messages"]["indexes"].as_a
          .find { |i| i["name"].as_s == "index_messages_on_pinned" }
          .not_nil!["where"].as_s
        sql.should contain("WHERE #{where}")

        # rooms has no indexes → no indexes key at all (schema.rb-style)
        yaml["rooms"]["indexes"]?.should be_nil
      ensure
        FileUtils.rm_f(path)
      end
    end
  end

  describe "build_url" do
    it "maps adapter and database into a sqlite3 URL with Rails 8 defaults" do
      url = ActiveRecord::Base.build_url(adapter: "sqlite3", database: "db/production.sqlite3")
      url.should start_with("sqlite3://db/production.sqlite3?")
      url.should contain("journal_mode=WAL")
      url.should contain("synchronous=NORMAL")
      url.should contain("cache_size=2000")
      url.should contain("busy_timeout=5000")
      url.should contain("foreign_keys=ON")
      url.should contain("max_pool_size=5")
    end

    it "forces a single connection for :memory:" do
      url = ActiveRecord::Base.build_url(adapter: "sqlite3", database: ":memory:")
      url.should contain("max_pool_size=1")
    end
  end
end
{% end %}
