# SQLite immediate transactions (Rails 8.1 sqlite3_adapter#
# begin_db_transaction → BEGIN IMMEDIATE TRANSACTION): внешний BEGIN
# берёт write-lock сразу и упирается в занятый lock мгновенно, а не
# молча проходит (deferred) и не ловит SQLITE_BUSY в первом UPDATE.
#
# Детерминированный оракул: сырое соединение держит write-lock
# (BEGIN IMMEDIATE), AR-транзакция с read-only блоком стартует с
# busy_timeout=0 — deferred BEGIN прошёл бы без ошибки.

require "spec"
require "file_utils"
require "process"
require "../src/active_record_cr"

DB_PATH = File.join(Dir.tempdir, "crails_ar_sqlite_immediate_#{Process.pid}.sqlite3")

describe "ActiveRecord SQLite immediate transactions" do
  before_all do
    FileUtils.rm_f(DB_PATH)
    FileUtils.rm_f("#{DB_PATH}-wal")
    FileUtils.rm_f("#{DB_PATH}-shm")
    # Raw URL без pragma-параметров (как DATABASE_URL в проде) —
    # Rails 8 дефолты должен применить адаптер, а не URL.
    ActiveRecord::Base.establish_connection(
      "sqlite3://#{DB_PATH}?max_pool_size=1")
    ActiveRecord::Base.connection.exec(<<-SQL)
      CREATE TABLE rooms (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL
      )
    SQL
  end

  after_all do
    FileUtils.rm_f(DB_PATH)
    FileUtils.rm_f("#{DB_PATH}-wal")
    FileUtils.rm_f("#{DB_PATH}-shm")
  end

  it "applies Rails 8 pragma defaults to a raw DATABASE_URL" do
    conn = ActiveRecord::Base.connection
    conn.query_one("PRAGMA journal_mode", as: String).downcase.should eq("wal")
    conn.query_one("PRAGMA synchronous", as: Int64).should eq(1_i64) # NORMAL
    conn.query_one("PRAGMA busy_timeout", as: Int64).should eq(10_000_i64)
  end

  it "begins the outermost transaction IMMEDIATE (write-lock at BEGIN)" do
    conn = ActiveRecord::Base.connection
    conn.exec("PRAGMA busy_timeout=0")
    locker = DB.open("sqlite3://#{DB_PATH}?busy_timeout=0")
    begin
      locker.exec("BEGIN IMMEDIATE") # держим write-lock
      # Deferred BEGIN без записей в блоке прошёл бы молча — IMMEDIATE
      # натыкается на занятый lock сразу (busy_timeout=0).
      expect_raises(SQLite3::Exception, /locked|busy/i) do
        ActiveRecord::Base.transaction { 1 }
      end
    ensure
      locker.exec("ROLLBACK") rescue nil
      locker.close
      conn.exec("PRAGMA busy_timeout=5000")
    end
  end

  it "commits normally when the write-lock is free" do
    ActiveRecord::Base.transaction do
      # Внутри транзакции — только через pinned-соединение (Base.__session):
      # прямой Base.connection.exec ждёт свободное соединение пула.
      ActiveRecord::Base.__session.exec("INSERT INTO rooms (name) VALUES ('watercooler')")
    end
    ActiveRecord::Base.connection.query_one("SELECT count(*) FROM rooms", as: Int64).should eq(1_i64)
  end

  it "rolls back writes on exception inside the transaction" do
    expect_raises(Exception, "boom") do
      ActiveRecord::Base.transaction do
        ActiveRecord::Base.__session.exec("INSERT INTO rooms (name) VALUES ('ghost')")
        raise Exception.new("boom")
      end
    end
    ActiveRecord::Base.connection.query_one("SELECT count(*) FROM rooms", as: Int64).should eq(1_i64)
  end
end
