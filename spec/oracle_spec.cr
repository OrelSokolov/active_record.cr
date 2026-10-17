# Oracle spec: 1:1 mirror of oracle/cases.rb. Expected values live in
# oracle/expected.yml — captured from the ORIGINAL activerecord 8.1.4 on
# the same scratch database. The port must reproduce them exactly; the
# tests are never edited on either side (see AGENTS.md).

require "spec"
require "../src/active_record_cr"

LOG = [] of String

# Adapter: Ruby errors.details/group_by_attribute keys are runtime Symbols;
# Crystal symbols are compile-time only (documented deviation) — wrap
# strings to render 1:1 with the oracle.
record Sym, name : String

# --- models (mirror of oracle/cases.rb; Comment first so Post's
# has_many codegen resolves the class) ---------------------------------

class Comment < ActiveRecord::Base
  belongs_to :post
  validates :body, presence: true
end

class Post < ActiveRecord::Base
  has_many :comments, dependent: :destroy

  validates :title, presence: true, length: {maximum: 10}
  validates :views, numericality: {only_integer: true, greater_than_or_equal_to: 0}, allow_nil: true

  before_validation :normalize_title
  before_save { LOG << "before_save" }
  after_create { LOG << "after_create" }
  after_update { LOG << "after_update" }
  after_destroy { LOG << "after_destroy" }

  def normalize_title
    LOG << "before_validation"
    if (t = title)
      self.title = t.strip
    end
    true
  end
end

class Profile < ActiveRecord::Base
  belongs_to :author
end

class Author < ActiveRecord::Base
  has_one :profile, dependent: :destroy
  validates :name, presence: true
  validates :email, format: {with: /\A[^@\s]+@[^@\s]+\z/}, uniqueness: true, allow_nil: true
  validates :age, numericality: {only_integer: true, greater_than: 0, less_than: 150}, allow_nil: true
  validates :bio, length: {maximum: 10}
  validate :name_not_forbidden

  def name_not_forbidden
    errors.add("name", "is forbidden") if name == "admin"
    nil
  end
end

# Anonymous classes with a table override (Ruby oracle uses Class.new):
# set_table_name maps this model onto posts.
class AbortedPost < ActiveRecord::Base
  set_table_name "posts"
  before_save { false }
end

# Mirror of the Ruby oracle TxPost (tx_* cases).
class TxPost < ActiveRecord::Base
  set_table_name "posts"
  after_commit { LOG << "after_commit" }
  after_rollback { LOG << "after_rollback" }
end

class ScopedPost < ActiveRecord::Base
  set_table_name "posts"
  scope :published do
    where(published: true)
  end

  scope :with_views_gt do |n|
    where("views > ?", n)
  end
end

class DSPost < ActiveRecord::Base
  set_table_name "posts"
  default_scope { where(published: true) }
end

# Mirror of the Ruby oracle §3 validation models. Ruby `if:` is a keyword
# in Crystal kwargs position → `condition:` (documented deviation).
class IncAuthor < ActiveRecord::Base
  set_table_name "authors"
  validates :name, inclusion: {in: ["Ada", "Bod"]}, allow_blank: true
  validates :bio, exclusion: {in: ["spam", "ads"]}
end

class CmpAuthor < ActiveRecord::Base
  set_table_name "authors"
  validates :age, comparison: {greater_than_or_equal_to: 18}, allow_nil: true
end

class ConfAuthor < ActiveRecord::Base
  set_table_name "authors"
  validates :email, presence: true, confirmation: true
end

class IfAuthor < ActiveRecord::Base
  set_table_name "authors"
  property strict_mode = false
  validates :bio, length: {maximum: 5}, condition: :strict_mode
end

class CtxAuthor < ActiveRecord::Base
  set_table_name "authors"
  validates :name, presence: true, on: :update
  validates :bio, presence: true, on: :create
end

class AccPost < ActiveRecord::Base
  set_table_name "posts"
  property terms : Bool | String | Nil = nil
  validates :terms, acceptance: true
end

class StrictAuthor < ActiveRecord::Base
  set_table_name "authors"
  validates :name, presence: true, strict: true
end

class ScopedComment < ActiveRecord::Base
  set_table_name "comments"
  validates :body, uniqueness: {scope: :post_id}
end

# Mirror of the Ruby oracle AroundPost (cb2_* cases). Ruby needs the
# method form (yield in class-level blocks is a Ruby syntax error);
# Crystal uses the block form — same callback semantics.
class AroundPost < ActiveRecord::Base
  set_table_name "posts"
  around_save { LOG << "as1"; yield; LOG << "as2" }
  around_create { LOG << "ac1"; yield; LOG << "ac2" }
  around_update { LOG << "au1"; yield; LOG << "au2" }
  around_destroy { LOG << "ad1"; yield; LOG << "ad2" }
  before_save { LOG << "bs" }
  after_save { LOG << "fs" }
  after_create { LOG << "fc" }
  after_update { LOG << "fu" }
  before_destroy { LOG << "bd" }
  after_destroy { LOG << "fd" }
  after_initialize { LOG << "init" }
  after_find { LOG << "find" }
  after_touch { LOG << "touch" }
end

class LegacyPost < ActiveRecord::Base
  set_table_name "posts"
end

# P1 models: custom primary key + `attribute ... default:` (the Ruby oracle
# maps uid onto @id — the port stores the custom pk in @id the same way).
class Widget < ActiveRecord::Base
  set_primary_key "uid"
end

class DefProfile < ActiveRecord::Base
  set_table_name "profiles"
  belongs_to :author
  attribute :nickname, default: "anon"
end

# --- P2 association models (mirror of oracle/cases.rb; TComment first so the
# has_many inverse_of registry lookup in TPost resolves at parse order) -------

class TComment < ActiveRecord::Base
  set_table_name "comments"
  belongs_to :t_post, class_name: "TPost", foreign_key: "post_id", counter_cache: :comments_count, inverse_of: :t_comments
end

class TPost < ActiveRecord::Base
  set_table_name "posts"
  belongs_to :t_author, class_name: "TAuthor", foreign_key: "author_id"
  has_many :t_comments, class_name: "TComment", foreign_key: "post_id", inverse_of: :t_post
end

class TAuthor < ActiveRecord::Base
  set_table_name "authors"
  has_many :t_posts, class_name: "TPost", foreign_key: "author_id"
  has_many :t_comments, through: :t_posts
end

class PolyPost < ActiveRecord::Base
  set_table_name "posts"
  has_many :pictures, as_name: :imageable
end

class PolyAuthor < ActiveRecord::Base
  set_table_name "authors"
  has_many :pictures, as_name: :imageable
end

class Picture < ActiveRecord::Base
  belongs_to :imageable, polymorphic: true
end

class Article < ActiveRecord::Base
  has_and_belongs_to_many :tags
end

class Tag < ActiveRecord::Base
  has_and_belongs_to_many :articles
end

CB_LOG = [] of String

class CbArticle < ActiveRecord::Base
  set_table_name "articles"
  has_and_belongs_to_many :cb_tags, class_name: "CbTag",
    before_add: [:cb_tag_first, :cb_tag_second], after_add: :cb_tag_after_add,
    before_remove: :cb_tag_before_remove, after_remove: :cb_tag_after_remove

  def cb_tag_first(tag : CbTag)
    CB_LOG << "before_add1:#{tag.name.not_nil!}"
  end

  def cb_tag_second(tag : CbTag)
    CB_LOG << "before_add2:#{tag.name.not_nil!}"
  end

  def cb_tag_after_add(tag : CbTag)
    CB_LOG << "after_add:#{tag.name.not_nil!}"
  end

  def cb_tag_before_remove(tag : CbTag)
    CB_LOG << "before_remove:#{tag.name.not_nil!}"
  end

  def cb_tag_after_remove(tag : CbTag)
    CB_LOG << "after_remove:#{tag.name.not_nil!}"
  end
end

class CbTag < ActiveRecord::Base
  set_table_name "tags"
end

class CbPost < ActiveRecord::Base
  set_table_name "posts"
  has_many :cb_comments, class_name: "CbComment", foreign_key: "post_id",
    before_add: :cb_comment_before_add, after_add: :cb_comment_after_add,
    before_remove: :cb_comment_before_remove, after_remove: :cb_comment_after_remove

  def cb_comment_before_add(rec : CbComment)
    CB_LOG << "hm_before_add"
  end

  def cb_comment_after_add(rec : CbComment)
    CB_LOG << "hm_after_add"
  end

  def cb_comment_before_remove(rec : CbComment)
    CB_LOG << "hm_before_remove"
  end

  def cb_comment_after_remove(rec : CbComment)
    CB_LOG << "hm_after_remove"
  end
end

class CbComment < ActiveRecord::Base
  set_table_name "comments"
end


class TouchPost < ActiveRecord::Base
  set_table_name "posts"
  belongs_to :t_author, class_name: "TAuthor", foreign_key: "author_id", touch: true
end

# --- P3 models: optimistic locking (Gadget) + STI (Vehicle/Car/Motorbike) -----

class Gadget < ActiveRecord::Base
end

class Vehicle < ActiveRecord::Base
end

class Car < Vehicle
end

class Motorbike < Vehicle
end

# --- P4 models: enum / store / secure_token / attr_readonly / alias -----------

class Badge < ActiveRecord::Base
  # Ruby's `enum` is a Crystal keyword → `ar_enum` (documented deviation);
  # Rails 8.1 getters return String (oracle-verified).
  ar_enum :status, {draft: 0, active: 1, archived: 2}
  store :settings, accessors: [:theme]
  has_secure_token
end

class RBadge < ActiveRecord::Base
  set_table_name "badges"
  attr_readonly :name
end

class ABadge < ActiveRecord::Base
  set_table_name "badges"
  alias_attribute :title, :name
end

ORACLE_URL = ENV["AR_ORACLE_URL"]? ||
             "postgres://root@/crails_ar_oracle?host=/var/run/postgresql"

# --- rendering (mirror of oracle/cases.rb) ------------------------------

def r(v) : String
  case v
  when Nil             then "nil"
  when Time            then "T" # time-mask, mirrors the Ruby oracle
  when Symbol          then ":#{v}"
  when Sym             then ":#{v.name}"
  when Bool, Int32, Int64, Float64, String then v.inspect
  when Array(String)   then "A[#{v.map(&.inspect).join(",")}]"
  when Array           then "A[#{v.map { |e| r(e) }.join(",")}]"
  when Tuple           then "A[#{v.map { |e| r(e) }.join(",")}]"
  when Hash            then "H{#{v.to_a.sort_by { |p| p[0].to_s }.map { |k, val| "#{r(k)}=>#{r(val)}" }.join(",")}}"
  when ActiveRecord::Errors then "E:#{v.full_messages.inspect}"
  when ActiveRecord::Base
    keys = ["id", "title", "views", "published", "post_id", "body", "name", "nickname", "age", "email"]
    parts = v.attributes.select { |k, _| keys.includes?(k) }
      .map { |k, av| "#{k}=#{r(av)}" }.sort
    "R:#{v.class.name}:#{parts.join(" ")}"
  else v.inspect
  end
end

# === case registry ======================================================

cases = {} of String => Proc(String)

def render_record_snapshot(record) : String
  "#{record.persisted?} #{record.id} #{r(record.title)}"
end

# fixtures (mirror order): posts 1..2, comments 1..2
P1 = -> { Post.create!({"title" => "first", "views" => 1_i64}) }
P2 = -> { Post.create!({"title" => "second", "views" => 2_i64, "published" => true, "score" => 3.5}) }

# --- new / save / create ------------------------------------------------
cases["crud_new_record"]    = -> { r(Post.new(title: "x").new_record?) }
cases["crud_new_changed"]   = -> { r(Post.new(title: "x").changed?) }
cases["crud_save"] = -> do
  p = Post.new(title: "  spaced  ", views: 3)
  result = p.save
  r("#{result} #{p.id} #{p.persisted?} #{p.new_record?} #{r(p.title)} #{r(p.created_at.nil?)} #{r(p.updated_at.nil?)}")
end
cases["crud_save_bang"]     = -> { r(Post.new(title: "bang", views: 0).save!) }
cases["crud_save_invalid"] = -> do
  p = Post.new(views: 5)
  result = p.save
  r("#{result} #{r(p.id)} #{p.persisted?} #{r(p.errors.full_messages)}")
end
cases["crud_save_bang_invalid"] = -> { r(Post.new(views: 5).save!) }
cases["crud_create"]        = -> { r(Post.create({"title" => "created", "views" => 7_i64})) }
cases["crud_create_bang"]   = -> { r(Post.create!({"title" => "created!", "views" => 8_i64}).id) }
cases["crud_create_invalid"] = -> do
  p = Post.create({"title" => nil.as(ActiveRecord::Value)})
  r("#{p.persisted?} #{p.new_record?} #{r(p.errors.full_messages)}")
end
cases["crud_create_bang_invalid"] = -> { r(Post.create!({"title" => nil.as(ActiveRecord::Value)}).id) }

# --- update ---------------------------------------------------------------
cases["crud_update_inst"] = -> do
  p = Post.find(1)
  result = p.update({"title" => "upd", "views" => 9_i64})
  r("#{result} #{r(p.title)} #{r(Post.find(1).title)} #{r(Post.find(1).views)}")
end
cases["crud_update_invalid"] = -> do
  p = Post.find(1)
  result = p.update({"title" => nil.as(ActiveRecord::Value)})
  r("#{result} #{r(Post.find(1).title)}")
end
cases["crud_update_bang"] = -> do
  Post.find(1).update!({"title" => "updbang"})
  r(Post.find(1).title)
end
cases["crud_update_class"] = -> { r(Post.update(1, {"views" => 11_i64}).id) }
cases["crud_update_class_bang"] = -> { r(Post.update!(1, {"views" => 12_i64}).views) }
cases["crud_update_columns"] = -> do
  p = Post.find(1)
  p.update_columns({"views" => 42_i64})
  r("#{Post.find(1).views} #{p.changed?}")
end
cases["crud_update_class_missing"] = -> { r(Post.update(999_999, {"views" => 1_i64}).id) }
cases["crud_touch"] = -> do
  p = Post.find(1)
  before = p.updated_at.not_nil!
  sleep 50.milliseconds
  p.touch
  later = Post.find(1).updated_at.not_nil! > Post.find(1).created_at.not_nil!
  r("#{p.updated_at.not_nil! > before} #{r(later ? "later" : "same")}")
end
cases["crud_reload"] = -> do
  Post.find(1).update_columns({"views" => 77_i64})
  stale = Post.find(1)
  Post.find(1).update_columns({"views" => 88_i64})
  r(stale.reload!.views)
end

# --- destroy / delete --------------------------------------------------
cases["crud_destroy"] = -> do
  victim = Post.create!({"title" => "todelete", "views" => 0_i64})
  LOG.clear
  result = victim.destroy
  r("#{result.id == victim.id} #{Post.exists?(victim.id.not_nil!)} #{LOG.inspect}")
end
cases["crud_destroy_class"] = -> do
  victim = Post.create!({"title" => "todelete2", "views" => 0_i64})
  destroyed = Post.destroy(victim.id.not_nil!)
  r("#{destroyed.id == victim.id} #{Post.exists?(victim.id.not_nil!)}")
end
cases["crud_delete_class"] = -> do
  victim = Post.create!({"title" => "del3", "views" => 0_i64})
  n = Post.delete(victim.id.not_nil!)
  r("#{n} #{Post.exists?(victim.id.not_nil!)}")
end
cases["crud_destroy_missing"] = -> { r(Post.destroy(999_999).id) }
cases["crud_destroy_frozen"] = -> do
  victim = Post.create!({"title" => "frozen", "views" => 0_i64})
  victim.destroy
  r(victim.destroyed?)
end
cases["crud_destroy_returns_self_attrs"] = -> do
  victim = Post.create!({"title" => "gone", "views" => 4_i64})
  d = victim.destroy
  r("#{d.id} #{r(d.title)}")
end

# --- timestamps ---------------------------------------------------------
cases["ts_on_create"] = -> do
  p = Post.create!({"title" => "ts", "views" => 0_i64})
  r("#{r(p.created_at.not_nil! == p.updated_at.not_nil!)} #{p.created_at.not_nil!.year >= 2026}")
end
cases["ts_on_update"] = -> do
  p = Post.create!({"title" => "ts2", "views" => 0_i64})
  before = p.updated_at.not_nil!
  sleep 50.milliseconds
  p.update({"views" => 1_i64})
  r("#{p.updated_at.not_nil! > before} #{p.created_at.not_nil! == Post.find(p.id.not_nil!).created_at.not_nil!}")
end

# --- dirty tracking ------------------------------------------------------
cases["dirty_loaded_clean"] = -> { r(Post.find(1).changed?) }
cases["dirty_attr_changed"] = -> do
  p = Post.find(1)
  p.title = "other"
  r(p.title_changed?)
end
cases["dirty_attr_was"] = -> do
  p = Post.find(1)
  p.title = "other"
  r(p.title_was)
end
cases["dirty_changes"] = -> do
  p = Post.find(1)
  p.views = 99
  r(p.changes)
end
cases["dirty_changed_list"] = -> do
  p = Post.find(1)
  p.views = 99
  r(p.changed)
end
cases["dirty_same_value"] = -> do
  p = Post.find(1)
  p.title = p.title
  r(p.changed?)
end
cases["dirty_will_save"] = -> do
  p = Post.find(1)
  p.title = "zz"
  r(p.will_save_change_to_title?)
end
cases["dirty_after_save"] = -> do
  p = Post.find(1)
  p.views = 123
  p.save
  r("#{p.changed?} #{r(p.saved_changes)} #{p.views_previously_changed?}")
end
cases["dirty_new_record_changes"] = -> { r(Post.new(title: "n", views: 1).changes) }

# --- callbacks order -----------------------------------------------------
cases["cb_save_order"] = -> do
  LOG.clear
  Post.create!({"title" => "cb", "views" => 0_i64})
  r(LOG)
end
cases["cb_update_order"] = -> do
  LOG.clear
  Post.find(1).update({"views" => 55_i64})
  r(LOG)
end
cases["cb_destroy_order"] = -> do
  victim = Post.create!({"title" => "cbd", "views" => 0_i64})
  LOG.clear
  victim.destroy
  r(LOG)
end
cases["cb_cancel_chain"] = -> do
  p = AbortedPost.new(title: "aborted", views: 0)
  r("#{p.save} #{p.persisted?}")
end

# --- validations (authors) ------------------------------------------------
cases["val_valid"] = -> { r(Author.new(name: "Ada", email: "ada@x.io", age: 30).valid?) }
cases["val_presence"] = -> do
  a = Author.new(email: "x@y.z")
  r("#{a.valid?} #{r(a.errors.full_messages)}")
end
cases["val_length"] = -> do
  a = Author.new(name: "L", bio: "way too long biography")
  r("#{a.valid?} #{r(a.errors.full_messages)}")
end
cases["val_numericality"] = -> do
  a = Author.new(name: "L", age: -5)
  r("#{a.valid?} #{r(a.errors.full_messages)}")
end
cases["val_numericality_not_int"] = -> { r("skipped") }
cases["val_format"] = -> do
  a = Author.new(name: "L", email: "not-an-email")
  r("#{a.valid?} #{r(a.errors.full_messages)}")
end
cases["val_uniqueness"] = -> do
  Author.create!({"name" => "First", "email" => "dup@x.io", "age" => 1_i64})
  second = Author.new(name: "Second", email: "dup@x.io", age: 2)
  r("#{second.valid?} #{r(second.errors.full_messages)}")
end
cases["val_custom_block"] = -> do
  a = Author.new(name: "admin")
  r("#{a.valid?} #{r(a.errors.full_messages)}")
end
cases["val_details"] = -> do
  a = Author.new
  a.valid?
  r(a.errors.where("name").map(&.type))
end
cases["val_save_false"] = -> do
  a = Author.new
  r("#{a.save} #{r(a.id)} #{a.persisted?}")
end
cases["val_update_false"] = -> do
  a = Author.create!({"name" => "Ok", "age" => 5_i64})
  r("#{a.update({"name" => nil.as(ActiveRecord::Value)})} #{r(Author.find(a.id.not_nil!).name)}")
end
cases["val_multiple_errors"] = -> do
  a = Author.new(age: -1, bio: "x" * 20)
  a.valid?
  r(a.errors.full_messages)
end

# --- associations ----------------------------------------------------------
cases["assoc_has_many_count"] = -> { r(Post.find(1).comments.count) }
cases["assoc_has_many_order"] = -> { r(Post.find(1).comments.order(:id).pluck(:body)) }
cases["assoc_ids"]            = -> { r(Post.find(1).comment_ids) }
cases["assoc_empty"]          = -> { r(Post.find(2).comments.empty?) }
cases["assoc_belongs_to"]     = -> { r(Comment.all.order(:id).first.not_nil!.post.not_nil!.title) }
cases["assoc_belongs_to_id"]  = -> { r(Comment.all.order(:id).first.not_nil!.post_id) }
cases["assoc_build"] = -> do
  c = Post.find(2).comments.build({"body" => "built"})
  r("#{c.new_record?} #{r(c.post_id)} #{Comment.count}")
end
cases["assoc_create"] = -> do
  c = Post.find(2).comments.create({"body" => "created", "author" => "Zoe"})
  r("#{c.persisted?} #{r(c.post_id)} #{Post.find(2).comments.count}")
end
cases["assoc_create_invalid"] = -> do
  c = Post.find(2).comments.create({"body" => nil.as(ActiveRecord::Value)})
  r("#{c.persisted?} #{r(c.errors.full_messages)}")
end
cases["assoc_shovel"] = -> do
  c = Comment.new(post_id: 1_i64, body: "shoveled")
  Post.find(1).comments << c
  r("#{c.persisted?} #{Post.find(1).comments.count}")
end
cases["assoc_build_belongs"] = -> do
  c = Comment.new(body: "withpost")
  p = c.build_post({"title" => "viapost"})
  r("#{p.new_record?} #{r(p.title)} #{r(c.post_id)}")
end
cases["assoc_create_belongs"] = -> do
  c = Comment.new(body: "withpost2")
  c.create_post({"title" => "viapost2"})
  last = Post.all.order(:id).to_a.last
  r("#{c.persisted?} #{c.post_id} #{r(last ? last.title : "n/a")}")
end
cases["assoc_dependent_destroy"] = -> do
  host = Post.create!({"title" => "host", "views" => 0_i64})
  host.comments.create!({"body" => "d1"})
  host.comments.create!({"body" => "d2"})
  host.destroy
  r("#{Post.exists?(host.id.not_nil!)} #{Comment.where("post_id = ?", host.id.not_nil!).count}")
end
cases["assoc_has_one"] = -> do
  a = Author.create!({"name" => "Solo", "age" => 40_i64})
  r("#{r(a.profile)} #{a.profile.nil?}")
end
cases["assoc_has_one_create"] = -> do
  a = Author.create!({"name" => "Pair", "age" => 41_i64})
  pr = a.create_profile({"nickname" => "p2"})
  r("#{pr.persisted?} #{r(a.profile.not_nil!.nickname)} #{r(pr.author_id)}")
end
cases["assoc_has_one_build"] = -> do
  a = Author.create!({"name" => "Builder", "age" => 42_i64})
  pr = a.build_profile({"nickname" => "b1"})
  r("#{pr.new_record?} #{r(pr.author_id)} #{Profile.count}")
end
cases["assoc_has_one_replace"] = -> do
  a = Author.create!({"name" => "Replacer", "age" => 43_i64})
  a.create_profile({"nickname" => "old"})
  a.create_profile({"nickname" => "new"})
  r("raise-checked")
end
cases["assoc_has_one_dependent"] = -> do
  a = Author.create!({"name" => "Dep", "age" => 44_i64})
  a.create_profile({"nickname" => "dep"})
  a.destroy
  r("#{Profile.where("author_id = ?", a.id.not_nil!).count}")
end
cases["assoc_belongs_to_required"] = -> do
  c = Comment.new(body: "nopost")
  r("#{c.valid?} #{r(c.errors.full_messages)}")
end

# --- misc write API --------------------------------------------------------
cases["misc_exists"] = -> { r(Post.exists?(1)) }
cases["misc_any"] = -> { r("#{Post.any?} #{Post.where(title: "zzz").any?} #{Post.none.any?}") }
cases["misc_count"]  = -> { r(Post.count) }
cases["misc_first_or_create"] = -> do
  p = Post.where(title: "first_or_create").first_or_create({"views" => 0_i64})
  r("#{p.persisted?} #{p.id.nil? ? "" : p.id} #{r(p.title)}")
end
cases["misc_first_or_create_twice"] = -> do
  a = Post.where(title: "first_or_create").first_or_create({"views" => 0_i64}).id
  b = Post.where(title: "first_or_create").first_or_create({"views" => 0_i64}).id
  r(a == b)
end
cases["misc_find_or_create_by"] = -> do
  a = Author.find_or_create_by({"name" => "Finder"})
  r("#{a.persisted?} #{r(Author.where("name = ?", "Finder").count)}")
end
cases["misc_insert_all"] = -> do
  rows = [{"title" => "ia1", "views" => 0_i64} of String => ActiveRecord::Value,
          {"title" => "ia2", "views" => 0_i64} of String => ActiveRecord::Value]
  Post.insert_all!(rows)
  r("#{Post.where("title IN (?, ?)", "ia1", "ia2").count}")
end
cases["misc_upsert"] = -> do
  now = Time.utc
  rows = [{"title" => "up1", "views" => 0_i64, "created_at" => now, "updated_at" => now} of String => ActiveRecord::Value,
          {"title" => "up2", "views" => 0_i64, "created_at" => now, "updated_at" => now} of String => ActiveRecord::Value]
  Post.upsert_all(rows)
  r(Post.where("title IN (?, ?)", "up1", "up2").count)
end

# --- transactions (mirror of oracle/cases.rb) -----------------------------

cases["tx_return_value"] = -> { r(Post.transaction { 42 }) }
cases["tx_commit_create"] = -> do
  result = Post.transaction do
    p = Post.create!({"title" => "txc", "views" => 0_i64})
    "#{p.persisted?} #{Post.exists?(p.id.not_nil!)}"
  end
  r(result)
end
cases["tx_rollback_raise"] = -> do
  before = Post.count
  outcome = "no-raise"
  begin
    Post.transaction do
      Post.create!({"title" => "txr", "views" => 0_i64})
      raise RuntimeError.new("boom")
    end
  rescue e : RuntimeError
    outcome = "#{e.message} #{Post.count == before}"
  end
  r(outcome)
end
cases["tx_rollback_marker"] = -> do
  before = Post.count
  result = Post.transaction do
    Post.create!({"title" => "txm", "views" => 0_i64})
    raise ActiveRecord::Rollback.new
    1
  end
  r("#{result.inspect} #{Post.count == before}")
end
cases["tx_joined_nested"] = -> do
  before = Post.count
  result = Post.transaction do
    Post.transaction do
      Post.create!({"title" => "txn1", "views" => 0_i64})
      raise ActiveRecord::Rollback.new
    end
    Post.create!({"title" => "txn2", "views" => 0_i64})
    99
  end
  r("#{result.inspect} #{Post.count == before}")
end
cases["tx_requires_new"] = -> do
  outer = Post.create!({"title" => "txo", "views" => 0_i64})
  result = Post.transaction do
    Post.transaction(requires_new: true) do
      Post.create!({"title" => "txi", "views" => 0_i64})
      raise ActiveRecord::Rollback.new
    end
    "committed"
  end
  r("#{result} #{Post.exists?(outer.id.not_nil!)} #{Post.where(title: "txi").count == 0}")
end
cases["tx_requires_new_exception"] = -> do
  outcome = "no-raise"
  begin
    Post.transaction do
      Post.transaction(requires_new: true) do
        Post.create!({"title" => "txbad", "views" => 0_i64})
        raise RuntimeError.new("inner")
      end
    end
  rescue e : RuntimeError
    outcome = "#{e.message} #{Post.where(title: "txbad").count == 0}"
  end
  r(outcome)
end
cases["tx_after_commit_log"] = -> do
  LOG.clear
  Post.transaction { TxPost.create!({"title" => "txac", "views" => 0_i64}) }
  r(LOG.inspect)
end
cases["tx_after_rollback_log"] = -> do
  LOG.clear
  Post.transaction do
    TxPost.create!({"title" => "txar", "views" => 0_i64})
    raise ActiveRecord::Rollback.new
  end
  r(LOG.inspect)
end
cases["tx_after_rollback_requires_new"] = -> do
  LOG.clear
  Post.transaction do
    Post.transaction(requires_new: true) do
      TxPost.create!({"title" => "txsp", "views" => 0_i64})
      raise ActiveRecord::Rollback.new
    end
    TxPost.create!({"title" => "txsp2", "views" => 0_i64})
  end
  r(LOG.inspect)
end
cases["tx_after_commit_no_tx"] = -> do
  LOG.clear
  TxPost.create!({"title" => "txnt", "views" => 0_i64})
  r(LOG.inspect)
end
cases["tx_after_commit_update_destroy"] = -> do
  LOG.clear
  p = TxPost.create!({"title" => "txud", "views" => 0_i64})
  LOG.clear
  p.update({"views" => 1_i64})
  p.destroy
  r(LOG.inspect)
end
cases["tx_isolation"] = -> { r(Post.transaction(isolation: :serializable) { 7 }) }
cases["tx_with_lock"] = -> do
  p = Post.create!({"title" => "txwl", "views" => 0_i64})
  p.with_lock { p.update({"views" => 5_i64}) }
  r(Post.find(p.id.not_nil!).views)
end
cases["tx_lock_bang"] = -> do
  p = Post.create!({"title" => "txlb", "views" => 0_i64})
  locked = Post.transaction { p.lock! }.not_nil!
  r("#{locked.id == p.id} #{r(locked.title)}")
end

# --- relation §2 (mirror of oracle/cases.rb) --------------------------------

cases["scope_basic"]      = -> { r(ScopedPost.published.count) }
cases["scope_chain"]      = -> { r(ScopedPost.published.order(:id).pluck(:title)) }
cases["scope_arg"]        = -> { r(ScopedPost.with_views_gt(1).count) }
cases["scope_ds"]         = -> { r(DSPost.count) }
cases["scope_ds_unscoped"] = -> { r(DSPost.unscoped.count) }
cases["scope_ds_where"] = -> do
  r(DSPost.where("views > ?", 100).count)
end

cases["agg_sum"]     = -> { r(Post.sum(:views)) }
cases["agg_minimum"] = -> { r(Post.minimum(:views)) }
cases["agg_maximum"] = -> { r(Post.maximum(:views)) }
cases["agg_average"] = -> { r(Post.average(:views).not_nil!.to_s.sub(/\.?0+$/, "")) }

cases["rel_or"] = -> do
  r(Post.where("views > ?", 100).or(Post.where(published: true)).count)
end
cases["rel_or_kwargs"] = -> do
  r(Post.where(title: "first").or(Post.where(title: "second")).order(:id).pluck(:id))
end

cases["rel_group_count"] = -> { r(Post.group(:published).count) }
cases["rel_having"] = -> do
  r(Post.group(:published).having("count(*) > 1000").count)
end
cases["rel_distinct_pluck"] = -> { r(Post.distinct.pluck(:published).uniq) }

cases["rel_joins_count"] = -> { r(Post.joins(:comments).count) }
cases["rel_joins_pluck"] = -> do
  r(Post.joins(:comments).order(:id).pluck(:title).uniq)
end
cases["rel_left_joins"] = -> do
  r(Post.left_outer_joins(:comments).where("comments.id IS NULL").count)
end

cases["rel_reorder"] = -> do
  r(Post.order(:title).reorder(:id).limit(3).pluck(:id))
end
cases["rel_in_order_of"] = -> do
  r(Post.in_order_of(:id, [3_i64, 1_i64, 2_i64]).pluck(:id).first(3))
end

cases["rel_update_all"] = -> do
  n = Post.where(published: true).update_all({"views" => 777_i64})
  r("#{n} #{Post.where(published: true).pluck(:views).uniq.inspect}")
end
cases["rel_touch_all"] = -> do
  Post.where(published: true).touch_all
  r(Post.where(published: true).pluck(:updated_at).map(&.as(Time).to_unix).uniq.size == 1)
end
cases["rel_destroy_all"] = -> do
  Post.create!({"title" => "dels1", "views" => 0_i64})
  Post.create!({"title" => "dels2", "views" => 0_i64})
  arr = Post.where("title LIKE ?", "dels%").destroy_all
  r("#{arr.size} #{Post.where("title LIKE ?", "dels%").count}")
end
cases["rel_delete_all"] = -> do
  Post.create!({"title" => "deld1", "views" => 0_i64})
  n = Post.where("title LIKE ?", "deld%").delete_all
  r("#{n} #{Post.where("title LIKE ?", "deld%").count}")
end

cases["rel_find_in_batches"] = -> do
  5.times { |i| Post.create!({"title" => "fib#{i}", "views" => 888_i64}) }
  batches = [] of Array(Int64)
  Post.where(views: 888).find_in_batches(batch_size: 2) { |bs| batches << bs.map(&.id.not_nil!) }
  r(batches)
end
cases["rel_in_batches"] = -> do
  sizes = [] of Int64 | Hash(ActiveRecord::Value, Int64)
  Post.where(views: 888).in_batches(of: 2) { |rel| sizes << rel.size }
  r(sizes)
end

cases["rel_none"] = -> { r("#{Post.none.count} #{Post.none.to_a.size}") }
cases["rel_except"] = -> do
  r(Post.where(published: true).limit(5).except(:limit).count ==
    Post.where(published: true).count)
end
cases["rel_only"] = -> do
  r(Post.where(published: true).limit(5).only(:where).count ==
    Post.where(published: true).count)
end
cases["rel_merge"] = -> do
  r(Post.where(published: true).merge(Post.where("views > ?", 700)).count)
end
cases["rel_annotate"] = -> do
  r(Post.where(id: 1).annotate("hi there").to_sql.includes?("/* hi there */"))
end

# --- validations tail (mirror of oracle/cases.rb) ---------------------------

cases["val2_inclusion_bad"] = -> do
  a = IncAuthor.new(name: "Zoe")
  r("#{a.valid?} #{r(a.errors.full_messages)}")
end
cases["val2_inclusion_blank"] = -> { r(IncAuthor.new(name: "").valid?) }
cases["val2_inclusion_ok"]    = -> { r(IncAuthor.new(name: "Ada").valid?) }
cases["val2_exclusion"] = -> do
  a = IncAuthor.new(name: "Ada", bio: "spam")
  r("#{a.valid?} #{r(a.errors.full_messages)}")
end
cases["val2_comparison_lt"] = -> do
  a = CmpAuthor.new(name: "x", age: 10)
  r("#{a.valid?} #{r(a.errors.full_messages)}")
end
cases["val2_comparison_ok"] = -> { r(CmpAuthor.new(name: "x", age: 18).valid?) }
cases["val2_confirmation_bad"] = -> do
  a = ConfAuthor.new(email: "a@b.c")
  a.email_confirmation = "other@x.y"
  r("#{a.valid?} #{r(a.errors.full_messages)}")
end
cases["val2_confirmation_ok"] = -> do
  a = ConfAuthor.new(email: "a@b.c")
  a.email_confirmation = "a@b.c"
  r(a.valid?)
end
cases["val2_acceptance_false"] = -> do
  a = AccPost.new(title: "t", views: 0)
  r("#{a.valid?} #{r(a.errors.full_messages)}")
end
cases["val2_acceptance_true"] = -> do
  a = AccPost.new(title: "t", views: 0)
  a.terms = true
  r(a.valid?)
end
cases["val2_if_skipped"] = -> { r(IfAuthor.new(bio: "way too long bio").valid?) }
cases["val2_if_applied"] = -> do
  a = IfAuthor.new(bio: "way too long bio")
  a.strict_mode = true
  r("#{a.valid?} #{r(a.errors.full_messages)}")
end
cases["val2_on_create_ok"] = -> { r(CtxAuthor.new(bio: "b").valid?) }
cases["val2_on_create_missing"] = -> do
  a = CtxAuthor.new
  r("#{a.valid?} #{r(a.errors.full_messages)}")
end
cases["val2_on_update_ctx"] = -> do
  a = CtxAuthor.new(bio: "b")
  r("#{a.valid?(:update)} #{r(a.errors.full_messages)}")
end
cases["val2_uniqueness_scope"] = -> do
  ScopedComment.create!({"post_id" => 1_i64, "body" => "sc1"})
  dup = ScopedComment.new(post_id: 1, body: "sc1")
  other = ScopedComment.new(post_id: 2, body: "sc1")
  r("#{dup.valid?} #{other.valid?}")
end
cases["val2_details"] = -> do
  a = IncAuthor.new(name: "Zoe")
  a.valid?
  r(a.errors.details.transform_keys { |k| Sym.new(k) })
end
cases["val2_where_typed"] = -> do
  a = IncAuthor.new(name: "Zoe")
  a.valid?
  r("#{a.errors.where("name", :inclusion).size} #{a.errors.where("name", :blank).size}")
end
cases["val2_group_by"] = -> do
  a = IncAuthor.new(name: "Zoe", bio: "spam")
  a.valid?
  r(a.errors.group_by_attribute.keys.sort.map { |k| Sym.new(k) })
end
cases["val2_strict"] = -> do
  begin
    StrictAuthor.new.valid?
    r("no-raise")
  rescue e : ActiveRecord::StrictValidationFailed
    r("raise:#{e.class.name.split("::").last}")
  end
end

# --- around callbacks + lifecycle (mirror of oracle/cases.rb) ---------------

cases["cb2_create_order"] = -> do
  LOG.clear
  AroundPost.create!({"title" => "cb2c", "views" => 0_i64})
  r(LOG)
end
cases["cb2_after_find"] = -> do
  LOG.clear
  AroundPost.first
  r(LOG)
end
cases["cb2_update_order"] = -> do
  p = AroundPost.create!({"title" => "cb2u", "views" => 0_i64})
  LOG.clear
  p.update({"views" => 1_i64})
  r(LOG)
end
cases["cb2_destroy_order"] = -> do
  p = AroundPost.create!({"title" => "cb2d", "views" => 0_i64})
  LOG.clear
  p.destroy
  r(LOG)
end
cases["cb2_touch"] = -> do
  p = AroundPost.create!({"title" => "cb2t", "views" => 0_i64})
  LOG.clear
  p.touch
  r(LOG)
end

# --- persistence tail (mirror of oracle/cases.rb) ----------------------------

cases["p3_reload"] = -> do
  p = Post.create!({"title" => "rl", "views" => 1_i64})
  Post.find(p.id.not_nil!).update_columns({"views" => 9_i64})
  r("#{p.reload.views} #{p.reload.changed?}")
end
cases["p3_update_attribute"] = -> do
  p = Post.create!({"title" => "ua", "views" => 1_i64})
  result = p.update_attribute("title", "ua2")
  r("#{result == p} #{Post.find(p.id.not_nil!).title}")
end
cases["p3_update_attribute_skips_validations"] = -> do
  p = Post.create!({"title" => "skipval", "views" => 1_i64})
  p.update_attribute("views", -5_i64)
  r(Post.find(p.id.not_nil!).views)
end
cases["p3_increment"] = -> do
  p = Post.create!({"title" => "inc", "views" => 5_i64})
  p.increment("views")
  r("#{p.views} #{Post.find(p.id.not_nil!).views}")
end
cases["p3_increment_bang"] = -> do
  p = Post.create!({"title" => "incb", "views" => 5_i64})
  p.increment!("views")
  r("#{p.views} #{Post.find(p.id.not_nil!).views}")
end
cases["p3_decrement"] = -> do
  p = Post.create!({"title" => "dec", "views" => 5_i64})
  r("#{p.decrement("views").views} #{Post.find(p.id.not_nil!).views}")
end
cases["p3_toggle"] = -> do
  p = Post.create!({"title" => "tog", "views" => 0_i64, "published" => true})
  p.toggle("published")
  s1 = "#{p.published} #{Post.find(p.id.not_nil!).published}"
  r2 = p.toggle!("published")
  r("#{s1} #{r2} #{p.published} #{Post.find(p.id.not_nil!).published}")
end
cases["p3_restore_attributes"] = -> do
  p = Post.create!({"title" => "ra", "views" => 1_i64})
  p.views = 99
  p.restore_attributes
  r("#{p.changed?} #{p.views}")
end
cases["p3_previous_changes"] = -> do
  p = Post.create!({"title" => "pc", "views" => 1_i64})
  p.update({"views" => 2_i64})
  r(p.previous_changes.keys.includes?("views"))
end
cases["p3_instance_delete"] = -> do
  p = Post.create!({"title" => "pdel", "views" => 1_i64})
  LOG.clear
  p.delete
  r("#{LOG.empty?} #{Post.exists?(p.id.not_nil!)}")
end
cases["p3_becomes"] = -> do
  p = Post.create!({"title" => "bm", "views" => 3_i64})
  l = p.becomes(LegacyPost)
  r("#{l.class.name} #{l.title} #{l.views} #{l.persisted?}")
end

# --- CollectionProxy tail (mirror of oracle/cases.rb) ------------------------

cases["proxy_concat"] = -> do
  host = Post.create!({"title" => "pc1", "views" => 0_i64})
  c1 = Comment.new(body: "cc1")
  c2 = Comment.new(body: "cc2")
  res = host.comments.concat([c1, c2])
  r("#{c1.persisted?} #{c2.persisted?} #{res.is_a?(ActiveRecord::CollectionProxy(Comment))} #{host.comments.count}")
end
cases["proxy_include"] = -> do
  host = Post.create!({"title" => "pc2", "views" => 0_i64})
  c = host.comments.create!({"body" => "ic1"})
  other = Post.first.not_nil!.comments.create!({"body" => "not-mine"})
  r("#{host.comments.include?(c)} #{host.comments.include?(other)}")
end
cases["proxy_destroy_one"] = -> do
  host = Post.create!({"title" => "pc4", "views" => 0_i64})
  c = host.comments.create!({"body" => "dso1"})
  host.comments.destroy(c)
  r("#{host.comments.count} #{Comment.exists?(c.id.not_nil!)}")
end

# --- P1 tail (mirror of oracle/cases.rb) -------------------------------------

cases["p1_exists_hash"]    = -> { r(Post.exists?(title: "first")) }
cases["p1_exists_hash_no"] = -> { r(Post.exists?(title: "zzz-none")) }
cases["p1_exists_nil"]     = -> { r(Post.exists?(score: nil)) }
cases["p1_exists_id"]      = -> { r("#{Post.exists?(2)} #{Post.exists?(9999)}") }

cases["p1_select_map"] = -> do
  r(Post.select(:id, :title).order(:id).map(&.title).last)
end
cases["p1_select_append"] = -> do
  r(Post.select(:id).select(:title).order(:id).first.not_nil!.title)
end
cases["p1_select_reselect"] = -> do
  r(Post.select(:id, :views).reselect(:title).order(:id).map(&.title).last)
end

cases["p1_lock_first"] = -> { r(Post.lock.order(:id).first.not_nil!.title) }
cases["p1_lock_share"] = -> { r(Post.lock("FOR SHARE").order(:id).first.not_nil!.title) }

cases["p1_readonly_flag"] = -> { r(Post.readonly.order(:id).first.not_nil!.readonly?) }
cases["p1_readonly_save"] = -> do
  p = Post.readonly.order(:id).first.not_nil!
  p.update({"title" => "ro"})
  r(true)
end
cases["p1_readonly_destroy"] = -> do
  Post.readonly.order(:id).first.not_nil!.destroy
  r(true)
end

cases["p1_strict_load_ok"] = -> { r(Post.strict_loading.order(:id).first.not_nil!.title) }
cases["p1_strict_violation"] = -> do
  Post.strict_loading.order(:id).first.not_nil!.comments.to_a
  r(true)
end

cases["p1_pk_create_find"] = -> do
  w = Widget.create!({"name" => "w1"})
  r("#{w.id} #{Widget.find(w.id.not_nil!).name} #{Widget.exists?(w.id.not_nil!)}")
end
cases["p1_pk_first_ids"] = -> do
  Widget.create!({"name" => "a"})
  Widget.create!({"name" => "b"})
  r("#{Widget.first.not_nil!.name} #{Widget.ids.inspect} #{Widget.order(:uid).last.not_nil!.name}")
end
cases["p1_pk_stock_default"] = -> { r(Widget.new.stock) }
cases["p1_pk_destroy"] = -> do
  w = Widget.create!({"name" => "d"})
  w.destroy
  r(Widget.exists?(w.id.not_nil!))
end

cases["p1_attr_default_new"]      = -> { r(DefProfile.new.nickname) }
cases["p1_attr_default_changed"]  = -> { r(DefProfile.new.changed?) }
cases["p1_attr_default_override"] = -> { r(DefProfile.new(nickname: "zed").nickname) }
cases["p1_attr_default_saved"] = -> do
  a = Author.create!({"name" => "P1sv"})
  p = DefProfile.create!({"author_id" => a.id.not_nil!})
  r("#{p.nickname} #{p.reload.nickname}")
end
cases["p1_attr_default_db_null"] = -> do
  a = Author.create!({"name" => "P1dn"})
  p = DefProfile.create!({"author_id" => a.id.not_nil!})
  p.update_columns({"nickname" => nil})
  r(p.reload.nickname)
end

# --- P2 associations (mirror of oracle/cases.rb) ------------------------------

cases["p2_setup"] = -> do
  conn = ActiveRecord::Base.connection
  conn.exec("UPDATE posts SET author_id = NULL, comments_count = 0")
  conn.exec("UPDATE posts SET comments_count = (SELECT count(*) FROM comments WHERE comments.post_id = posts.id)")
  r("#{Post.where("comments_count > 0").count} #{Post.count}")
end

cases["p2_through"] = -> do
  a = TAuthor.create!({"name" => "TA1"})
  p1 = TPost.new(title: "tp1"); p1.t_author = a; p1.save!
  p2 = TPost.new(title: "tp2"); p2.t_author = a; p2.save!
  c1 = TComment.new(body: "tc1"); c1.t_post = p1; c1.save!
  c2 = TComment.new(body: "tc2"); c2.t_post = p1; c2.save!
  c3 = TComment.new(body: "tc3"); c3.t_post = p2; c3.save!
  TPost.new(title: "other").save!
  r("#{a.t_posts.count} #{a.t_comments.count} #{a.t_comments.map(&.body.not_nil!).sort.inspect} #{a.t_comment_ids.sort.inspect}")
end

cases["p2_counter_cache"] = -> do
  a = TAuthor.create!({"name" => "TA2"})
  p = TPost.new(title: "ccp"); p.t_author = a; p.save!
  c1 = TComment.new(body: "cc1"); c1.t_post = p; c1.save!
  c2 = TComment.new(body: "cc2"); c2.t_post = p; c2.save!
  mid = TPost.find(p.id.not_nil!).comments_count
  c1.destroy
  r("#{mid} #{TPost.find(p.id.not_nil!).comments_count}")
end

cases["p2_inverse_of"] = -> do
  a = TAuthor.create!({"name" => "TInv"})
  p = TPost.new(title: "inv"); p.t_author = a; p.save!
  c = p.t_comments.build({"body" => "ic"})
  r("#{c.t_post.not_nil!.same?(p)} #{c.post_id == p.id} #{c.new_record?}")
end

cases["p2_polymorphic"] = -> do
  pp = PolyPost.create!({"title" => "poly"})
  pa = PolyAuthor.create!({"name" => "PA"})
  pic1 = Picture.new(caption: "cap1"); pic1.imageable = pp; pic1.save!
  pic2 = Picture.new(caption: "cap2"); pic2.imageable = pa; pic2.save!
  r("#{pp.pictures.count} #{pa.pictures.count} #{pp.pictures.order(:id).first.not_nil!.caption} #{Picture.order(:id).first.not_nil!.imageable.not_nil!.class.name} #{Picture.order(:id).last.not_nil!.imageable.not_nil!.class.name}")
end

cases["p2_habtm"] = -> do
  hp = Article.create!({"title" => "habtm"})
  t1 = Tag.create!({"name" => "red"})
  t2 = Tag.create!({"name" => "blue"})
  hp.tags << t1
  hp.tags << t2
  r("#{hp.tags.count} #{hp.tags.map(&.name.not_nil!).sort.inspect} #{hp.tag_ids.sort.inspect} #{t1.articles.count}")
end

cases["p2_habtm_delete"] = -> do
  hp = Article.create!({"title" => "hdel"})
  t1 = Tag.create!({"name" => "green"})
  t2 = Tag.create!({"name" => "white"})
  hp.tags << t1
  hp.tags << t2
  hp.tags.delete(t1)
  r("#{hp.tags.count} #{Tag.count} #{t1.articles.count}")
end

cases["p2_belongs_to_touch"] = -> do
  a = TAuthor.create!({"name" => "TTo"})
  a.update_columns({"updated_at" => Time.utc(2020, 1, 1)})
  p = TouchPost.new(title: "tp"); p.t_author = a; p.save!
  after_create = a.reload.updated_at.not_nil!.year == 2020
  p.update({"title" => "tp2"})
  after_update = a.reload.updated_at.not_nil!.year == 2020
  p.destroy
  after_destroy = a.reload.updated_at.not_nil!.year == 2020
  r("#{after_create} #{after_update} #{after_destroy}")
end

# --- P2 eager loading (query-count oracle; qc mirrors the Ruby helper) --------

def qc(&) : String
  before = ActiveRecord::Base.__query_count
  result = yield
  r("#{r(result)} #{ActiveRecord::Base.__query_count - before}")
end

cases["p2_includes_to_a"] = -> { qc { Post.includes(:comments).to_a.size } }
cases["p2_includes_first"] = -> do
  qc { Post.where(views: 1).includes(:comments).first.not_nil!.comments.size }
end
cases["p2_includes_bt"] = -> do
  qc { Comment.includes(:post).where(body: "c1").to_a.map(&.post_id).inspect }
end
cases["p2_lazy_control"] = -> do
  qc { Comment.where(body: "c2").first.not_nil!.post.not_nil!.class.name }
end

# --- P3: optimistic locking + STI (mirror of oracle/cases.rb) -----------------

cases["p3_lock_version_incr"] = -> do
  g = Gadget.create!({"name" => "g2"})
  v1 = g.lock_version
  g.update!({"name" => "g2b"})
  r("#{v1} #{g.lock_version} #{Gadget.find(g.id.not_nil!).lock_version}")
end

cases["p3_stale_object"] = -> do
  g1 = Gadget.create!({"name" => "g1"})
  g2 = Gadget.find(g1.id.not_nil!)
  g1.update!({"name" => "g1a"})
  g2.update!({"name" => "g1b"})
  r(true)
end

cases["p3_sti_create_find"] = -> do
  Vehicle.create!({"name" => "generic"})
  c = Car.create!({"name" => "sedan", "wheels" => 4_i64})
  Motorbike.create!({"name" => "fast", "wheels" => 2_i64})
  r("#{Vehicle.count} #{Car.count} #{Motorbike.count} #{Vehicle.order(:id).map(&.type).compact.inspect} #{Vehicle.find(c.id.not_nil!).class.name} #{c.type}")
end

cases["p3_sti_scopes"] = -> do
  r("#{Car.where(wheels: 4).count} #{Car.first.not_nil!.class.name} #{Car.first.not_nil!.name}")
end

# --- P4 (mirror of oracle/cases.rb) -------------------------------------------

cases["p4_enum"] = -> do
  b = Badge.new(name: "b1")
  b.status = "active"
  b.save!
  r("#{b.status.inspect} #{b.active?} #{b.draft?} #{Badge.active.count} #{Badge.where(status: 1).count}")
end

cases["p4_enum_bang"] = -> do
  b = Badge.new(name: "b2")
  b.status = :draft
  b.save!
  b.archived!
  r("#{b.status.inspect} #{Badge.find(b.id.not_nil!).status.inspect} #{Badge.statuses.inspect}")
end

cases["p4_store"] = -> do
  b = Badge.create!({"name" => "b3"})
  b.theme = "dark"
  b.save!
  r("#{Badge.find(b.id.not_nil!).theme.inspect} #{Badge.find(b.id.not_nil!).settings.not_nil!["theme"].inspect}")
end

cases["p4_secure_token"] = -> do
  b = Badge.create!({"name" => "b4"})
  r("#{b.token.not_nil!.size} #{Badge.find(b.id.not_nil!).token == b.token}")
end

cases["p4_cache_key"] = -> do
  b = Badge.create!({"name" => "b5"})
  r("#{b.cache_key.split("-").first.inspect} #{Badge.new.cache_key} #{Post.first.not_nil!.cache_key.split("-").first.inspect}")
end

cases["p4_attr_readonly"] = -> do
  b = RBadge.create!({"name" => "ro1"})
  result = b.update!({"name" => "ro2"})
  r("#{result} #{RBadge.find(b.id.not_nil!).name.inspect}")
end

cases["p4_alias_attribute"] = -> do
  b = ABadge.new
  b.title = "alias-me"
  b.save!
  r("#{b.title.inspect} #{ABadge.where(title: "alias-me").count} #{b.name.inspect}")
end

# --- P5: accepts_nested_attributes_for ----------------------------------

class NPost < ActiveRecord::Base
  set_table_name "posts"
  belongs_to :n_author, class_name: "NAuthor", foreign_key: "author_id", optional: true
  validates :title, presence: true, length: {maximum: 5}
end

class NAuthor < ActiveRecord::Base
  set_table_name "authors"
  has_many :n_posts, class_name: "NPost", foreign_key: "author_id"
  accepts_nested_attributes_for :n_posts, allow_destroy: true, reject_if: :all_blank
end

# Ruby: `create!(name: ..., n_posts_attributes: [...])` — the kwargs value
# is an Array, which cannot ride the Hash(String, Value) pipeline; the
# setter is invoked directly instead (same deferred-save semantics).
cases["p5_nested_create"] = -> do
  a = NAuthor.new(name: "NA1")
  a.n_posts_attributes = [{"title" => "np1"}, {"title" => "np2"}]
  a.save!
  r("#{a.persisted?} #{a.n_posts.count} #{a.n_posts.map(&.title.not_nil!).sort.inspect}")
end

cases["p5_nested_update_add"] = -> do
  a = NAuthor.create!({"name" => "NA2"})
  p = NPost.new(title: "base"); p.n_author = a; p.save!
  a.n_posts_attributes = [{"id" => p.id.not_nil!, "title" => "upd"}, {"title" => "added"}]
  a.save!
  r("#{NPost.find(p.id.not_nil!).title.inspect} #{a.reload.n_posts.count}")
end

cases["p5_nested_destroy"] = -> do
  a = NAuthor.create!({"name" => "NA3"})
  p1 = NPost.new(title: "d1"); p1.n_author = a; p1.save!
  p2 = NPost.new(title: "d2"); p2.n_author = a; p2.save!
  a.n_posts_attributes = [{"id" => p2.id.not_nil!, "_destroy" => true}]
  a.save!
  r("#{a.reload.n_posts.count} #{NPost.exists?(p2.id.not_nil!)}")
end

cases["p5_nested_reject"] = -> do
  a = NAuthor.create!({"name" => "NA4"})
  a.n_posts_attributes = [{"title" => ""}, {"title" => "kept"}]
  a.save!
  r("#{a.reload.n_posts.count} #{a.n_posts.map(&.title.not_nil!).inspect}")
end

cases["p5_nested_invalid"] = -> do
  a = NAuthor.new(name: "NA5")
  a.n_posts_attributes = [{"title" => "waytoolong"}]
  a.save
  r("#{a.persisted?} #{NAuthor.where(name: "NA5").count} #{a.errors.full_messages.inspect}")
end

# --- P2: eager_load (single LEFT OUTER JOIN query) + references ------------

cases["p2_eager_load_hm"] = -> do
  a = TAuthor.create!({"name" => "EL1"})
  p1 = TPost.new(title: "ep1"); p1.t_author = a; p1.save!
  p2 = TPost.new(title: "ep2"); p2.t_author = a; p2.save!
  TAuthor.create!({"name" => "EL2"}) # no posts
  qc do
    authors = TAuthor.where(name: ["EL1", "EL2"]).eager_load(:t_posts).order(:name).to_a
    "#{authors.size} #{authors.map { |x| x.t_posts.map(&.title.not_nil!).sort }.inspect} #{authors.map(&.name.not_nil!).inspect}"
  end
end

cases["p2_eager_load_bt"] = -> do
  qc do
    posts = TPost.where(title: ["ep1", "ep2"]).eager_load(:t_author).order(:title).to_a
    "#{posts.size} #{posts.map { |p| p.t_author.not_nil!.name.not_nil! }.uniq.inspect}"
  end
end

cases["p2_eager_load_where"] = -> do
  qc do
    posts = TPost.eager_load(:t_author).where("authors.name = ?", "EL1").order(:title).to_a
    "#{posts.size} #{posts.map(&.title.not_nil!).inspect} #{posts.map { |p| p.t_author.not_nil!.name.not_nil! }.uniq.inspect}"
  end
end

cases["p2_eager_load_references"] = -> do
  qc do
    posts = TPost.where("authors.name = ?", "EL1").includes(:t_author).references(:authors).order(:title).to_a
    "#{posts.size} #{posts.map { |p| p.t_author.not_nil!.name.not_nil! }.uniq.inspect}"
  end
end

# --- P6: serialize + association autosave (mirror of oracle/cases.rb) --------

class Pref < ActiveRecord::Base
  # Ruby: `serialize :settings, coder: JSON` — the port takes the :json
  # symbol (JSON coder only; Rails' default YAML coder is not ported).
  serialize :settings, coder: :json
  serialize :tags, type: Array, coder: :json
end

class AutoComment < ActiveRecord::Base
  set_table_name "comments"
  belongs_to :auto_post, class_name: "AutoPost", foreign_key: "post_id", optional: true
  validates :body, presence: true
end

class AutoPost < ActiveRecord::Base
  set_table_name "posts"
  has_many :auto_comments, class_name: "AutoComment", foreign_key: "post_id", autosave: true
end

class AutoReply < ActiveRecord::Base
  set_table_name "comments"
  belongs_to :auto_thread, class_name: "AutoThread", foreign_key: "post_id", autosave: true, optional: true
  validates :body, presence: true
end

class AutoThread < ActiveRecord::Base
  set_table_name "posts"
  validates :title, presence: true
end

# Ruby assigns plain Hash/Array literals (dynamic typing); the port's typed
# setters take JSON::Any / Array values (documented deviation).
cases["p6_ser_assign_read"] = -> do
  p = Pref.new(name: "s1")
  p.settings = JSON.parse(%({"theme": "dark", "count": 2}))
  r("#{r(p.settings.not_nil!["theme"].as_s)} #{r(p.settings.not_nil!["count"].as_i64)} #{p.changed?}")
end

cases["p6_ser_roundtrip"] = -> do
  p = Pref.create!({"name" => "s2"})
  p.settings = JSON.parse(%({"theme": "dark", "count": 2}))
  p.save!
  fresh = Pref.find(p.id.not_nil!)
  r("#{r(fresh.settings.not_nil!["theme"].as_s)} #{r(fresh.settings.not_nil!["count"].as_i64)} #{fresh.settings.not_nil!.as_h.keys.sort.inspect} #{r(p.reload!.settings.not_nil!["count"].as_i64)}")
end

cases["p6_ser_update"] = -> do
  p = Pref.new(name: "s3")
  p.settings = JSON.parse(%({"theme": "light"}))
  p.save!
  p.settings = JSON.parse(%({"theme": "dark", "count": 7}))
  p.save!
  raw = ActiveRecord::Base.__session.query_one(
    "SELECT settings FROM prefs WHERE id = $1", args: [p.id.not_nil!], as: String)
  r("#{r(JSON.parse(raw)["theme"].as_s)} #{r(JSON.parse(raw)["count"].as_i64)} #{r(Pref.find(p.id.not_nil!).settings.not_nil!["theme"].as_s)}")
end

cases["p6_ser_array"] = -> do
  p = Pref.new(name: "s4")
  p.tags = ["a", "b"]
  p.save!
  r("#{r(Pref.find(p.id.not_nil!).tags.map(&.as_s))} #{r(p.reload!.tags.map(&.as_s))}")
end

cases["p6_ser_array_default"] = -> do
  r("#{r(Pref.new.tags)} #{r(Pref.create!({"name" => "s5"}).reload!.tags)}")
end

cases["p6_ser_array_update"] = -> do
  p = Pref.new(name: "s6")
  p.tags = ["x"]
  p.save!
  # Ruby mutates the cached array (p.tags << "y"); the port has no
  # deserialized-value cache — assign the updated container instead.
  p.tags = ["x", "y"]
  p.save!
  r(r(Pref.find(p.id.not_nil!).tags.map(&.as_s)))
end

cases["p6_autosave_hm_new"] = -> do
  ap = AutoPost.create!({"title" => "ap1"})
  ap.auto_comments.build({"body" => "ac1"})
  ap.save
  r("#{AutoComment.where("post_id = ?", ap.id.not_nil!).count} #{r(ap.auto_comments.order(:id).first.not_nil!.body.not_nil!)}")
end

cases["p6_autosave_hm_dirty"] = -> do
  ap = AutoPost.create!({"title" => "ap2"})
  c = ap.auto_comments.create!({"body" => "dirty1"})
  ap.auto_comments.to_a # load the target (mutations stick on loaded records)
  ap.auto_comments.first.not_nil!.body = "dirty2"
  ap.save
  r(r(AutoComment.find(c.id.not_nil!).body))
end

cases["p6_autosave_hm_invalid"] = -> do
  ap = AutoPost.create!({"title" => "ap3"})
  ap.auto_comments.build({"body" => nil.as(ActiveRecord::Value)})
  valid = ap.valid?
  messages = ap.errors.full_messages.inspect
  saved = ap.save
  r("#{valid} #{messages} #{saved} #{AutoComment.where("post_id = ?", ap.id.not_nil!).count}")
end

cases["p6_autosave_bt_new"] = -> do
  reply = AutoReply.new(body: "btc1")
  reply.auto_thread = AutoThread.new(title: "btp")
  saved = reply.save
  r("#{saved} #{r(reply.post_id)} #{reply.persisted?} #{r(AutoThread.where("title = ?", "btp").count)}")
end

cases["p6_autosave_bt_dirty"] = -> do
  t = AutoThread.create!({"title" => "btp2"})
  reply = AutoReply.new(body: "btc2")
  reply.auto_thread = t
  reply.save!
  reply.auto_thread.not_nil!.title = "btp2u"
  reply.save
  r(r(AutoThread.find(t.id.not_nil!).title))
end

cases["p6_autosave_bt_invalid"] = -> do
  reply = AutoReply.new(body: "btc3")
  reply.auto_thread = AutoThread.new
  valid = reply.valid?
  messages = reply.errors.full_messages.inspect
  saved = reply.save
  r("#{valid} #{messages} #{saved} #{reply.persisted?} #{AutoThread.where("title IS NULL").count}")
end

cases["p2_assoc_cb_habtm"] = -> do
  a = CbArticle.create!({"title" => "cba"})
  t = CbTag.create!({"name" => "cbgold"})
  a.cb_tags << t
  a.cb_tags.delete(t)
  r("#{CB_LOG.join(",")} #{a.cb_tags.count}")
end

cases["p2_assoc_cb_has_many"] = -> do
  p = CbPost.create!({"title" => "cbp"})
  p.cb_comments << CbComment.new(body: "cbc")
  p.cb_comments.destroy(p.cb_comments.first.not_nil!)
  r(CB_LOG.join(","))
end

# === runner =============================================================

describe "ActiveRecord write oracle (expected.yml from activerecord 8.1.4)" do
  before_all do
    ActiveRecord::Base.establish_connection(ORACLE_URL)
    conn = ActiveRecord::Base.connection
    conn.exec(%(
      CREATE TABLE IF NOT EXISTS widgets (
        uid bigserial PRIMARY KEY,
        name character varying,
        stock integer DEFAULT 3
      )))
    conn.exec("TRUNCATE widgets RESTART IDENTITY")
    conn.exec("ALTER TABLE posts ADD COLUMN IF NOT EXISTS author_id bigint")
    conn.exec("ALTER TABLE posts ADD COLUMN IF NOT EXISTS comments_count integer NOT NULL DEFAULT 0")
    conn.exec(%(CREATE TABLE IF NOT EXISTS tags (
      id bigserial PRIMARY KEY,
      name character varying NOT NULL
    )))
    conn.exec(%(CREATE TABLE IF NOT EXISTS articles (
      id bigserial PRIMARY KEY,
      title character varying NOT NULL
    )))
    conn.exec(%(CREATE TABLE IF NOT EXISTS articles_tags (
      article_id bigint NOT NULL,
      tag_id bigint NOT NULL
    )))
    conn.exec(%(CREATE TABLE IF NOT EXISTS pictures (
      id bigserial PRIMARY KEY,
      imageable_type character varying NOT NULL,
      imageable_id bigint NOT NULL,
      caption character varying
    )))
    conn.exec("TRUNCATE tags, articles_tags, articles, pictures RESTART IDENTITY")
    conn.exec(%(CREATE TABLE IF NOT EXISTS gadgets (
      id bigserial PRIMARY KEY,
      name character varying,
      lock_version integer NOT NULL DEFAULT 0
    )))
    conn.exec(%(CREATE TABLE IF NOT EXISTS vehicles (
      id bigserial PRIMARY KEY,
      type character varying,
      name character varying,
      wheels integer
    )))
    conn.exec(%(CREATE TABLE IF NOT EXISTS badges (
      id bigserial PRIMARY KEY,
      name character varying,
      status integer,
      settings jsonb,
      token character varying
    )))
    conn.exec(%(CREATE TABLE IF NOT EXISTS prefs (
      id bigserial PRIMARY KEY,
      name character varying,
      settings text,
      tags text
    )))
    conn.exec("TRUNCATE badges RESTART IDENTITY")
    conn.exec("TRUNCATE prefs RESTART IDENTITY")
    conn.exec("TRUNCATE gadgets, vehicles RESTART IDENTITY")
    conn.exec(
      "TRUNCATE posts, comments, authors, profiles RESTART IDENTITY CASCADE")
    # fixtures (in oracle/cases.rb order)
    p1 = P1.call
    p2 = P2.call
    Comment.create!({"post_id" => p1.id.not_nil!, "body" => "c1", "author" => "Ada"})
    Comment.create!({"post_id" => p1.id.not_nil!, "body" => "c2", "author" => "Bod"})
  end

  expected = Hash(String, String).new
  File.read_lines(File.join(__DIR__, "..", "oracle", "expected.yml")).each do |line|
    id, value = line.split('\t', 2)
    expected[id] = value
  end

  # assoc_has_one_replace: the Ruby oracle captures the RecordNotUnique
  # raise — checked separately below (rescue context differs in specs).
  cases.each do |id, block|
    next if id == "assoc_has_one_replace"

    it id do
      actual = begin
        block.call
      rescue e : ActiveRecord::RecordInvalid
        "raise:ActiveRecord::RecordInvalid"
      rescue e : ActiveRecord::RecordNotFound
        "raise:ActiveRecord::RecordNotFound"
      rescue e : ActiveRecord::RecordNotUnique
        "raise:ActiveRecord::RecordNotUnique"
      rescue e : Exception
        "raise:#{e.class.name}"
      end
      actual.should eq(expected[id]), "#{id}: got #{actual.inspect}, want #{expected[id].inspect}"
    end
  end

  it "assoc_has_one_replace" do
    a = Author.create!({"name" => "Replacer2", "age" => 45_i64})
    a.create_profile({"nickname" => "old"})
    raised = false
    begin
      a.create_profile({"nickname" => "new"})
    rescue e : ActiveRecord::RecordNotUnique
      raised = true
    end
    raised.should be_true
  end
end

# --- regression: STI record loaded from DB, update via save/save! -------------
# (campfire bug: save on a loaded STI subclass returned false with empty
# errors — a codegen workaround in Base#save fixed it; see persistence.cr.
# Not an oracle-mirror case: plain true/false assertions against Rails 8.1.4
# semantics — activerecord returns true from save when the UPDATE succeeds.)
describe "STI update via save (regression)" do
  before_all do
    ActiveRecord::Base.establish_connection(ORACLE_URL)
    conn = ActiveRecord::Base.connection
    conn.exec("TRUNCATE vehicles RESTART IDENTITY")
  end

  it "loaded STI subclass saves with validations on update" do
    Car.create!({"name" => "sedan", "wheels" => 4_i64})
    car = Vehicle.all.where("name = ?", "sedan").first.not_nil!
    car.class.name.should eq("Car")
    car.name = "coupe"
    car.save.should be_true
    car.errors.full_messages.should eq([] of String)
    Vehicle.all.where("name = ?", "coupe").first.not_nil!.class.name.should eq("Car")
  end

  it "loaded STI subclass update! raises nothing and persists" do
    Motorbike.create!({"name" => "fast", "wheels" => 2_i64})
    mb = Vehicle.all.where("name = ?", "fast").first.not_nil!
    mb.class.name.should eq("Motorbike")
    mb.update!({"name" => "turbo"}).should be_true
    Motorbike.all.where("name = ?", "turbo").count.should eq(1)
  end
end
