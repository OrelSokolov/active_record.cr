# Callback conditions (if:/unless:), after_*_commit sugar, dirty API
# (previously_new_record?, attribute_previously_changed?,
# <attr>_previously_changed?(from:, to:)) and enum options
# (prefix:, default:, ArrayLiteral auto-numbering).
#
# Runs as its own compilation with the fixture schema pinned:
#
#   CRAILS_SCHEMA=spec/fixtures/callbacks_enum_schema.yml \
#     crystal spec spec/callbacks_enum_spec.cr
{% if env("CRAILS_SCHEMA") %}
require "spec"
require "file_utils"
require "../src/active_record_cr"

DB_PATH = File.join(Dir.tempdir, "crails_ar_cb_enum_spec_#{Process.pid}.sqlite3")

class Gadget < ActiveRecord::Base
  ar_enum :status, {active: 0, retired: 1}, default: :active
  ar_enum :kind, [:standard, :premium, :legacy], prefix: :gadget_kind

  before_create { self.name = "anon" if name.nil? }
  after_save :log_save, if: :previously_new_record?
  after_create_commit -> { GadgetLog << "created-commit" }
  after_update_commit :log_update_commit
  after_destroy_commit { GadgetLog << "destroyed-commit" }
  after_save_commit :log_save_commit, unless: :never

  private def log_save : Nil
    GadgetLog << "saved-new"
  end

  private def log_update_commit : Nil
    GadgetLog << "updated-commit"
  end

  private def log_save_commit : Nil
    GadgetLog << "save-commit"
  end

  private def never : Bool
    false
  end
end

class GadgetLog
  class_property entries = [] of String

  def self.<<(entry : String)
    entries << entry
  end
end

describe "callback conditions and commit sugar" do
  before_all do
    FileUtils.rm_f(DB_PATH)
    FileUtils.rm_f("#{DB_PATH}-wal")
    FileUtils.rm_f("#{DB_PATH}-shm")
    ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: DB_PATH)
    ActiveRecord::Base.connection.exec(<<-SQL)
      CREATE TABLE gadgets (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name VARCHAR,
        status INTEGER,
        kind INTEGER,
        widgets_count INTEGER DEFAULT 0,
        created_at DATETIME,
        updated_at DATETIME
      )
    SQL
  end

  it "before_create block fires and enum default applies" do
    g = Gadget.create
    g.name.should eq("anon")
    g.status.should eq("active")
    Gadget.find?(g.id.not_nil!).not_nil!.status.should eq("active")
  end

  it "after_save with if: previously_new_record? fires on create only" do
    GadgetLog.entries.clear
    g = Gadget.create({"name" => "x"})
    GadgetLog.entries.should contain("saved-new")
    GadgetLog.entries.clear
    g.name = "y"
    g.save
    GadgetLog.entries.should_not contain("saved-new")
  end

  it "after_create_commit fires via lambda on create" do
    GadgetLog.entries.clear
    Gadget.create({"name" => "c"})
    GadgetLog.entries.should contain("created-commit")
    GadgetLog.entries.clear
    g = Gadget.last.not_nil!
    g.name = "c2"
    g.save
    GadgetLog.entries.should_not contain("created-commit")
    GadgetLog.entries.should contain("updated-commit")
  end

  it "after_destroy_commit fires on destroy" do
    GadgetLog.entries.clear
    g = Gadget.create({"name" => "d"})
    g.destroy
    GadgetLog.entries.should contain("destroyed-commit")
  end

  it "unless: skips the callback" do
    GadgetLog.entries.clear
    Gadget.create({"name" => "u"})
    GadgetLog.entries.should contain("save-commit")
  end

  it "previously_new_record? is true only on the creating save" do
    g = Gadget.create({"name" => "p"})
    g.previously_new_record?.should be_true
    g.name = "p2"
    g.save
    g.previously_new_record?.should be_false
  end

  it "attribute_previously_changed? with from:/to:" do
    g = Gadget.create({"name" => "a"})
    g.name = "b"
    g.save
    g.name_previously_changed?.should be_true
    g.name_previously_changed?(to: "b").should be_true
    g.name_previously_changed?(to: "a").should be_false
    g.name_previously_changed?(from: "a", to: "b").should be_true
    g.name_previously_changed?(from: "b").should be_false
    g.widgets_count_previously_changed?.should be_false
  end

  it "enum with auto-numbered array and prefix" do
    g = Gadget.create({"name" => "e", "kind" => "premium"})
    g.gadget_kind_premium?.should be_true
    g.gadget_kind_standard?.should be_false
    g.gadget_kind_premium!.should be_true # bang with prefix
    g.reload.kind.should eq("premium")
    Gadget.gadget_kind_premium.where("name = ?", "e").count.should eq(1)
  end

  it "enum columns accept Symbol/String names in .new (Rails Model.new(status: :retired))" do
    g = Gadget.new(name: "s", status: :retired, kind: :premium)
    g.status.should eq("retired")
    g.gadget_kind_premium?.should be_true
    g2 = Gadget.new(name: "s2", status: "active", kind: 2)
    g2.status.should eq("active")
    g2.kind.should eq("legacy")
    g3 = Gadget.new(name: "s3", status: 1)
    g3.status.should eq("retired")
    expect_raises(ArgumentError) { Gadget.new(name: "x", status: "junk") }
  end
end
{% end %}
