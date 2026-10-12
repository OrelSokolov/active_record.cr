# Synthetic oracle cases for ActiveRecord WRITE slice (Iteration 2).
#
# Run against the ORIGINAL gem on the scratch database:
#   createdb crails_ar_oracle  (see oracle/setup.sql)
#   ruby oracle/cases.rb > oracle/expected.yml
#
# Each line: "<case_id>\t<rendered result>". The same IDs are mirrored
# 1:1 in spec/oracle_spec.cr; the Crystal port must reproduce
# expected.yml exactly (values captured from activerecord 8.1.4).
# The DB is truncated (RESTART IDENTITY) before each run.

require "active_record"

ActiveRecord::Base.establish_connection(
  adapter: "postgresql",
  host: "/var/run/postgresql",
  database: "crails_ar_oracle",
)

ActiveRecord::Base.connection.execute(
  "TRUNCATE posts, comments, authors, profiles RESTART IDENTITY CASCADE")

$log = []

class Post < ActiveRecord::Base
  has_many :comments, dependent: :destroy

  validates :title, presence: true, length: {maximum: 10}
  validates :views, numericality: {only_integer: true, greater_than_or_equal_to: 0}, allow_nil: true

  before_validation :normalize_title
  before_save :upcase_title
  after_create { $log << "after_create" }
  after_update { $log << "after_update" }
  after_destroy { $log << "after_destroy" }
  before_save { $log << "before_save" }

  def normalize_title
    $log << "before_validation"
    self.title = title.strip if title
  end

  def upcase_title
    $log << "skip" if false
  end
end

class Comment < ActiveRecord::Base
  belongs_to :post
  validates :body, presence: true
end

class Author < ActiveRecord::Base
  has_one :profile, dependent: :destroy
  validates :name, presence: true
  validates :email, format: {with: /\A[^@\s]+@[^@\s]+\z/}, uniqueness: true, allow_nil: true
  validates :age, numericality: {only_integer: true, greater_than: 0, less_than: 150}, allow_nil: true
  validates :bio, length: {maximum: 10}
  validate :name_not_forbidden

  def name_not_forbidden
    errors.add(:name, "is forbidden") if name == "admin"
  end
end

class Profile < ActiveRecord::Base
  belongs_to :author
end

def render(v)
  case v
  when true, false, Integer, Float, String then v.inspect
  when Symbol then ":#{v}"
  when nil then "nil"
  when Time then "T" # time-mask: run-time values must not leak into the oracle
  when Array then "A[#{v.map { |e| render(e) }.join(',')}]"
  when Hash then "H{#{v.sort_by { |k, _| k.to_s }.map { |k, val| "#{render(k)}=>#{render(val)}" }.join(',')}}"
  when ActiveRecord::Base then "R:#{v.class.name}:#{v.attributes.slice('id', 'title', 'views', 'published', 'post_id', 'body', 'name', 'nickname', 'age', 'email').map { |k, x| "#{k}=#{render(x)}" }.sort.join(' ')}"
  when ActiveRecord::Errors then "E:#{v.full_messages.inspect}"
  when Exception then "raise:#{v.class.name}"
  else v.inspect
  end
end

def case_run(id)
  puts "#{id}\t#{render(yield)}"
rescue StandardError => e
  puts "#{id}\traise:#{e.class.name}"
end

# === fixtures: posts 1..3, comments, authors ==========================
p1 = Post.create!(title: "first", views: 1)
p2 = Post.create!(title: "second", views: 2, published: true, score: 3.5)
Comment.create!(post: p1, body: "c1", author: "Ada")
Comment.create!(post: p1, body: "c2", author: "Bod")

# --- new / save / create ------------------------------------------------
case_run("crud_new_record")    { Post.new(title: "x").new_record? }
case_run("crud_new_changed")   { Post.new(title: "x").changed? }
case_run("crud_save") do
  p = Post.new(title: "  spaced  ", views: 3)
  result = p.save
  "#{result} #{p.id} #{p.persisted?} #{p.new_record?} #{render(p.title)} #{render(p.created_at.nil?)} #{render(p.updated_at.nil?)}"
end
case_run("crud_save_bang")     { Post.new(title: "bang", views: 0).save! }
case_run("crud_save_invalid") do
  p = Post.new(views: 5)
  result = p.save
  "#{result} #{render(p.id)} #{p.persisted?} #{render(p.errors.full_messages)}"
end
case_run("crud_save_bang_invalid") { Post.new(views: 5).save! }
case_run("crud_create")        { Post.create(title: "created", views: 7) }
case_run("crud_create_bang")   { Post.create!(title: "created!", views: 8).id }
case_run("crud_create_invalid") do
  p = Post.create(title: nil)
  "#{p.persisted?} #{p.new_record?} #{render(p.errors.full_messages)}"
end
case_run("crud_create_bang_invalid") { Post.create!(title: nil) }

# --- update ---------------------------------------------------------------
case_run("crud_update_inst") do
  p = Post.find(1)
  r = p.update(title: "upd", views: 9)
  "#{r} #{render(p.title)} #{render(Post.find(1).title)} #{render(Post.find(1).views)}"
end
case_run("crud_update_invalid") do
  p = Post.find(1)
  r = p.update(title: nil)
  "#{r} #{render(Post.find(1).title)}"
end
case_run("crud_update_bang") do
  Post.find(1).update!(title: "updbang")
  Post.find(1).title
end
case_run("crud_update_class") { Post.update(1, views: 11).id }
case_run("crud_update_class_bang") { Post.update!(1, views: 12).views }
case_run("crud_update_columns") do
  p = Post.find(1)
  p.update_columns(views: 42)
  "#{Post.find(1).views} #{p.changed?}"
end
case_run("crud_update_class_missing") { Post.update(999999, views: 1) }
case_run("crud_touch") do
  p = Post.find(1)
  before = p.updated_at
  sleep 0.05
  p.touch
  "#{p.updated_at > before} #{Post.find(1).updated_at > Post.find(1).created_at ? render('later') : render('same')}"
end
case_run("crud_reload") do
  Post.find(1).update_columns(views: 77)
  stale = Post.find(1)
  Post.find(1).update_columns(views: 88)
  stale.reload.views
end

# --- destroy / delete ------------------------------------------------------
case_run("crud_destroy") do
  victim = Post.create!(title: "todelete", views: 0)
  $log.clear
  result = victim.destroy
  "#{result.id == victim.id} #{Post.exists?(victim.id)} #{$log.inspect}"
end
case_run("crud_destroy_class") do
  victim = Post.create!(title: "todelete2", views: 0)
  ActiveRecord::Base.connection.execute("SELECT 1")
  destroyed = Post.destroy(victim.id)
  "#{destroyed.id == victim.id} #{Post.exists?(victim.id)}"
end
case_run("crud_delete_class") do
  victim = Post.create!(title: "del3", views: 0)
  n = Post.delete(victim.id)
  "#{n} #{Post.exists?(victim.id)}"
end
case_run("crud_destroy_missing") { Post.destroy(999999) }
case_run("crud_destroy_frozen") do
  victim = Post.create!(title: "frozen", views: 0)
  victim.destroy
  victim.frozen?
end
case_run("crud_destroy_returns_self_attrs") do
  victim = Post.create!(title: "gone", views: 4)
  d = victim.destroy
  "#{d.id} #{render(d.title)}"
end

# --- timestamps ---------------------------------------------------------
case_run("ts_on_create") do
  p = Post.create!(title: "ts", views: 0)
  "#{render(p.created_at.getutc == p.updated_at.getutc)} #{p.created_at.getutc.year >= 2026}"
end
case_run("ts_on_update") do
  p = Post.create!(title: "ts2", views: 0)
  before = p.updated_at
  sleep 0.05
  p.update(views: 1)
  "#{p.updated_at > before} #{p.created_at == Post.find(p.id).created_at}"
end

# --- dirty tracking -------------------------------------------------------
case_run("dirty_loaded_clean") { Post.find(1).changed? }
case_run("dirty_attr_changed") { p = Post.find(1); p.title = "other"; p.title_changed? }
case_run("dirty_attr_was")     { p = Post.find(1); p.title = "other"; p.title_was }
case_run("dirty_changes")      { p = Post.find(1); p.views = 99; p.changes }
case_run("dirty_changed_list") { p = Post.find(1); p.views = 99; p.changed }
case_run("dirty_same_value")   { p = Post.find(1); p.title = p.title; p.changed? }
case_run("dirty_will_save")   { p = Post.find(1); p.title = "zz"; p.will_save_change_to_title? }
case_run("dirty_after_save") do
  p = Post.find(1)
  p.views = 123
  p.save
  "#{p.changed?} #{render(p.saved_changes)} #{p.views_previously_changed?}"
end
case_run("dirty_new_record_changes") { Post.new(title: "n", views: 1).changes }

# --- callbacks order --------------------------------------------------
case_run("cb_save_order") do
  $log.clear
  Post.create!(title: "cb", views: 0)
  $log
end
case_run("cb_update_order") do
  $log.clear
  Post.find(1).update(views: 55)
  $log
end
case_run("cb_destroy_order") do
  victim = Post.create!(title: "cbd", views: 0)
  $log.clear
  victim.destroy
  $log
end
case_run("cb_cancel_chain") do
  klass = Class.new(ActiveRecord::Base) do
    self.table_name = "posts"
    before_save { throw(:abort) }
  end
  p = klass.new(title: "aborted", views: 0)
  "#{p.save} #{p.persisted?}"
end

# --- validations (authors) ------------------------------------------------
case_run("val_valid") { Author.new(name: "Ada", email: "ada@x.io", age: 30).valid? }
case_run("val_presence") do
  a = Author.new(email: "x@y.z")
  "#{a.valid?} #{render(a.errors.full_messages)}"
end
case_run("val_length") do
  a = Author.new(name: "L", bio: "way too long biography")
  "#{a.valid?} #{render(a.errors.full_messages)}"
end
case_run("val_numericality") do
  a = Author.new(name: "L", age: -5)
  "#{a.valid?} #{render(a.errors.full_messages)}"
end
case_run("val_numericality_not_int") do
  # Crystal: статически типизированные атрибуты — строки в Int-колонку
  # не компилируются, кейс непереносим (см. PLAN). Числовой кейс выше
  # покрывает numericality на границах.
  "skipped"
end
case_run("val_format") do
  a = Author.new(name: "L", email: "not-an-email")
  "#{a.valid?} #{render(a.errors.full_messages)}"
end
case_run("val_uniqueness") do
  Author.create!(name: "First", email: "dup@x.io", age: 1)
  second = Author.new(name: "Second", email: "dup@x.io", age: 2)
  "#{second.valid?} #{render(second.errors.full_messages)}"
end
case_run("val_custom_block") do
  a = Author.new(name: "admin")
  "#{a.valid?} #{render(a.errors.full_messages)}"
end
case_run("val_details") do
  a = Author.new
  a.valid?
  a.errors.where(:name).map { |e| e.type }
end
case_run("val_save_false") do
  a = Author.new
  "#{a.save} #{render(a.id)} #{a.persisted?}"
end
case_run("val_update_false") do
  a = Author.create!(name: "Ok", age: 5)
  "#{a.update(name: nil)} #{render(Author.find(a.id).name)}"
end
case_run("val_multiple_errors") do
  a = Author.new(age: -1, bio: "x" * 20)
  a.valid?
  a.errors.full_messages
end

# --- associations --------------------------------------------------------
case_run("assoc_has_many_count") { Post.find(1).comments.count }
case_run("assoc_has_many_order") { Post.find(1).comments.order(:id).pluck(:body) }
case_run("assoc_ids")            { Post.find(1).comment_ids }
case_run("assoc_empty")          { Post.find(2).comments.empty? }
case_run("assoc_belongs_to")     { Comment.order(:id).first.post.title }
case_run("assoc_belongs_to_id")  { Comment.order(:id).first.post_id }
case_run("assoc_build") do
  c = Post.find(2).comments.build(body: "built")
  "#{c.new_record?} #{render(c.post_id)} #{Comment.count}"
end
case_run("assoc_create") do
  c = Post.find(2).comments.create(body: "created", author: "Zoe")
  "#{c.persisted?} #{render(c.post_id)} #{Post.find(2).comments.count}"
end
case_run("assoc_create_invalid") do
  c = Post.find(2).comments.create(body: nil)
  "#{c.persisted?} #{render(c.errors.full_messages)}"
end
case_run("assoc_shovel") do
  c = Comment.new(post_id: 1, body: "shoveled")
  Post.find(1).comments << c
  "#{c.persisted?} #{Post.find(1).comments.count}"
end
case_run("assoc_build_belongs") do
  c = Comment.new(body: "withpost")
  p = c.build_post(title: "viapost")
  "#{p.new_record?} #{render(p.title)} #{render(c.post_id)}"
end
case_run("assoc_create_belongs") do
  c = Comment.new(body: "withpost2")
  c.create_post(title: "viapost2")
  "#{c.persisted?} #{render(c.post_id)} #{render(Post.last.title) rescue render('n/a')}"
end
case_run("assoc_dependent_destroy") do
  host = Post.create!(title: "host", views: 0)
  host.comments.create!(body: "d1")
  host.comments.create!(body: "d2")
  n = host.destroy
  "#{Post.exists?(host.id)} #{Comment.where(post_id: host.id).count}"
end
case_run("assoc_has_one") do
  a = Author.create!(name: "Solo", age: 40)
  "#{render(a.profile)} #{a.profile.nil?}"
end
case_run("assoc_has_one_create") do
  a = Author.create!(name: "Pair", age: 41)
  pr = a.create_profile(nickname: "p2")
  "#{pr.persisted?} #{render(a.profile.nickname)} #{render(pr.author_id)}"
end
case_run("assoc_has_one_build") do
  a = Author.create!(name: "Builder", age: 42)
  pr = a.build_profile(nickname: "b1")
  "#{pr.new_record?} #{render(pr.author_id)} #{Profile.count}"
end
case_run("assoc_has_one_replace") do
  a = Author.create!(name: "Replacer", age: 43)
  a.create_profile(nickname: "old")
  a.create_profile(nickname: "new")
  "#{render(a.profile.nickname)} #{Profile.where(author_id: a.id).count}"
end
case_run("assoc_has_one_dependent") do
  a = Author.create!(name: "Dep", age: 44)
  a.create_profile(nickname: "dep")
  a.destroy
  "#{Profile.where(author_id: a.id).count}"
end
case_run("assoc_belongs_to_required") do
  c = Comment.new(body: "nopost")
  "#{c.valid?} #{render(c.errors.full_messages)}"
end

# --- misc write API -----------------------------------------------------
case_run("misc_exists")  { Post.exists?(1) }
case_msg = ActiveRecord::Base.connection.execute("SELECT count(*) AS n FROM posts").first["n"]
case_run("misc_count")   { Post.count }
case_run("misc_first_or_create") do
  p = Post.where(title: "first_or_create").first_or_create(views: 0)
  "#{p.persisted?} #{p.id} #{render(p.title)}"
end
case_run("misc_first_or_create_twice") do
  Post.where(title: "first_or_create").first_or_create(views: 0).id ==
    Post.where(title: "first_or_create").first_or_create(views: 0).id
end
case_run("misc_find_or_create_by") do
  a = Author.find_or_create_by(name: "Finder")
  "#{a.persisted?} #{render(Author.where(name: "Finder").count)}"
end
case_run("misc_insert_all") do
  n = Post.insert_all!([{title: "ia1", views: 0}, {title: "ia2", views: 0}])
  "#{Post.where(title: %w[ia1 ia2]).count}"
end
case_run("misc_upsert") do
  Post.upsert_all([{title: "up1", views: 0, created_at: Time.now.utc, updated_at: Time.now.utc},
                   {title: "up2", views: 0, created_at: Time.now.utc, updated_at: Time.now.utc}])
  Post.where(title: %w[up1 up2]).count
end

# --- transactions (§7) ----------------------------------------------------
class TxPost < ActiveRecord::Base
  self.table_name = "posts"
  after_commit { $log << "after_commit" }
  after_rollback { $log << "after_rollback" }
end

case_run("tx_return_value") { Post.transaction { 42 } }
case_run("tx_commit_create") do
  Post.transaction do
    p = Post.create!(title: "txc", views: 0)
    "#{p.persisted?} #{Post.exists?(p.id)}"
  end
end
case_run("tx_rollback_raise") do
  before = Post.count
  begin
    Post.transaction do
      Post.create!(title: "txr", views: 0)
      raise "boom"
    end
  rescue RuntimeError => e
    "#{e.message} #{Post.count == before}"
  end
end
case_run("tx_rollback_marker") do
  before = Post.count
  result = Post.transaction do
    Post.create!(title: "txm", views: 0)
    raise ActiveRecord::Rollback
    1
  end
  "#{render(result)} #{Post.count == before}"
end
case_run("tx_joined_nested") do
  before = Post.count
  result = Post.transaction do
    Post.transaction do
      Post.create!(title: "txn1", views: 0)
      raise ActiveRecord::Rollback
    end
    Post.create!(title: "txn2", views: 0)
    99
  end
  "#{result} #{Post.count == before}"
end
case_run("tx_requires_new") do
  outer = Post.create!(title: "txo", views: 0)
  result = Post.transaction do
    Post.transaction(requires_new: true) do
      Post.create!(title: "txi", views: 0)
      raise ActiveRecord::Rollback
    end
    "committed"
  end
  "#{result} #{Post.exists?(outer.id)} #{Post.where(title: "txi").count == 0}"
end
case_run("tx_requires_new_exception") do
  begin
    Post.transaction do
      Post.transaction(requires_new: true) do
        Post.create!(title: "txbad", views: 0)
        raise "inner"
      end
    end
  rescue RuntimeError => e
    "#{e.message} #{Post.where(title: "txbad").count == 0}"
  end
end
case_run("tx_after_commit_log") do
  $log.clear
  Post.transaction { TxPost.create!(title: "txac", views: 0) }
  $log.inspect
end
case_run("tx_after_rollback_log") do
  $log.clear
  Post.transaction do
    TxPost.create!(title: "txar", views: 0)
    raise ActiveRecord::Rollback
  end
  $log.inspect
end
case_run("tx_after_rollback_requires_new") do
  $log.clear
  Post.transaction do
    Post.transaction(requires_new: true) do
      TxPost.create!(title: "txsp", views: 0)
      raise ActiveRecord::Rollback
    end
    TxPost.create!(title: "txsp2", views: 0)
  end
  $log.inspect
end
case_run("tx_after_commit_no_tx") do
  $log.clear
  TxPost.create!(title: "txnt", views: 0)
  $log.inspect
end
case_run("tx_after_commit_update_destroy") do
  $log.clear
  p = TxPost.create!(title: "txud", views: 0)
  $log.clear
  p.update(views: 1)
  p.destroy
  $log.inspect
end
case_run("tx_isolation") { Post.transaction(isolation: :serializable) { 7 } }
case_run("tx_with_lock") do
  p = Post.create!(title: "txwl", views: 0)
  p.with_lock { p.update(views: 5) }
  Post.find(p.id).views
end
case_run("tx_lock_bang") do
  p = Post.create!(title: "txlb", views: 0)
  r = Post.transaction { p.lock! }
  "#{r.id == p.id} #{render(r.title)}"
end

# --- relation: scopes, aggregates, or/group/joins/bulk (§2) ---------------
class ScopedPost < ActiveRecord::Base
  self.table_name = "posts"
  scope :published, -> { where(published: true) }
  scope :with_views_gt, ->(n) { where("views > ?", n) }
end

class DSPost < ActiveRecord::Base
  self.table_name = "posts"
  default_scope { where(published: true) }
end

case_run("scope_basic")  { ScopedPost.published.count }
case_run("scope_chain")  { ScopedPost.published.order(:id).pluck(:title) }
case_run("scope_arg")    { ScopedPost.with_views_gt(1).count }
case_run("scope_ds")     { DSPost.count }
case_run("scope_ds_unscoped") { DSPost.unscoped.count }
case_run("scope_ds_where") do
  DSPost.where("views > ?", 100).count
end

case_run("agg_sum")     { Post.sum(:views) }
case_run("agg_minimum") { Post.minimum(:views) }
case_run("agg_maximum") { Post.maximum(:views) }
case_run("agg_average") { Post.average(:views).round(2).to_s("F").sub(/\.?0+$/, "") }

case_run("rel_or") do
  Post.where("views > ?", 100).or(Post.where(published: true)).count
end
case_run("rel_or_kwargs") do
  Post.where(title: "first").or(Post.where(title: "second")).order(:id).pluck(:id)
end

case_run("rel_group_count") { Post.group(:published).count }
case_run("rel_having") do
  Post.group(:published).having("count(*) > 1000").count
end
case_run("rel_distinct_pluck") { Post.distinct.pluck(:published).uniq }

case_run("rel_joins_count") { Post.joins(:comments).count }
case_run("rel_joins_pluck") do
  Post.joins(:comments).order(:id).pluck(:title).uniq
end
case_run("rel_left_joins") do
  Post.left_outer_joins(:comments).where("comments.id IS NULL").count
end

case_run("rel_reorder") do
  Post.order(:title).reorder(:id).limit(3).pluck(:id)
end
case_run("rel_in_order_of") do
  Post.in_order_of(:id, [3, 1, 2]).pluck(:id).first(3)
end

case_run("rel_update_all") do
  n = Post.where(published: true).update_all(views: 777)
  "#{n} #{Post.where(published: true).pluck(:views).uniq.inspect}"
end
case_run("rel_touch_all") do
  Post.where(published: true).touch_all
  Post.where(published: true).pluck(:updated_at).map { |t| t.to_i }.uniq.size == 1
end
case_run("rel_destroy_all") do
  Post.create!(title: "dels1", views: 0)
  Post.create!(title: "dels2", views: 0)
  arr = Post.where("title LIKE ?", "dels%").destroy_all
  "#{arr.size} #{Post.where("title LIKE ?", "dels%").count}"
end
case_run("rel_delete_all") do
  Post.create!(title: "deld1", views: 0)
  n = Post.where("title LIKE ?", "deld%").delete_all
  "#{n} #{Post.where("title LIKE ?", "deld%").count}"
end

case_run("rel_find_in_batches") do
  5.times { |i| Post.create!(title: "fib#{i}", views: 888) }
  batches = []
  Post.where(views: 888).find_in_batches(batch_size: 2) { |bs| batches << bs.map(&:id) }
  batches
end
case_run("rel_in_batches") do
  sizes = []
  Post.where(views: 888).in_batches(of: 2) { |rel| sizes << rel.size }
  sizes
end

case_run("rel_none") { "#{Post.none.count} #{Post.none.to_a.size}" }
case_run("rel_except") do
  Post.where(published: true).limit(5).except(:limit).count ==
    Post.where(published: true).count
end
case_run("rel_only") do
  Post.where(published: true).limit(5).only(:where).count ==
    Post.where(published: true).count
end
case_run("rel_merge") do
  Post.where(published: true).merge(Post.where("views > ?", 700)).count
end
case_run("rel_annotate") do
  Post.where(id: 1).annotate("hi there").to_sql.include?("/* hi there */")
end

# --- validations tail (§3) ------------------------------------------------
class IncAuthor < ActiveRecord::Base
  self.table_name = "authors"
  validates :name, inclusion: {in: %w[Ada Bod]}, allow_blank: true
  validates :bio, exclusion: {in: %w[spam ads]}
end

class CmpAuthor < ActiveRecord::Base
  self.table_name = "authors"
  validates :age, comparison: {greater_than_or_equal_to: 18}, allow_nil: true
end

class ConfAuthor < ActiveRecord::Base
  self.table_name = "authors"
  validates :email, presence: true, confirmation: true
end

class IfAuthor < ActiveRecord::Base
  self.table_name = "authors"
  attr_accessor :strict_mode
  validates :bio, length: {maximum: 5}, if: :strict_mode
end

class CtxAuthor < ActiveRecord::Base
  self.table_name = "authors"
  validates :name, presence: true, on: :update
  validates :bio, presence: true, on: :create
end

class AccPost < ActiveRecord::Base
  self.table_name = "posts"
  attr_accessor :terms
  validates :terms, acceptance: true
end

class StrictAuthor < ActiveRecord::Base
  self.table_name = "authors"
  validates :name, presence: true, strict: true
end

class ScopedComment < ActiveRecord::Base
  self.table_name = "comments"
  validates :body, uniqueness: {scope: :post_id}
end

case_run("val2_inclusion_bad") do
  a = IncAuthor.new(name: "Zoe")
  "#{a.valid?} #{render(a.errors.full_messages)}"
end
case_run("val2_inclusion_blank") { IncAuthor.new(name: "").valid? }
case_run("val2_inclusion_ok")    { IncAuthor.new(name: "Ada").valid? }
case_run("val2_exclusion") do
  a = IncAuthor.new(name: "Ada", bio: "spam")
  "#{a.valid?} #{render(a.errors.full_messages)}"
end
case_run("val2_comparison_lt") do
  a = CmpAuthor.new(name: "x", age: 10)
  "#{a.valid?} #{render(a.errors.full_messages)}"
end
case_run("val2_comparison_ok") { CmpAuthor.new(name: "x", age: 18).valid? }
case_run("val2_confirmation_bad") do
  a = ConfAuthor.new(email: "a@b.c", email_confirmation: "other@x.y")
  "#{a.valid?} #{render(a.errors.full_messages)}"
end
case_run("val2_confirmation_ok") do
  ConfAuthor.new(email: "a@b.c", email_confirmation: "a@b.c").valid?
end
case_run("val2_acceptance_false") do
  a = AccPost.new(title: "t", views: 0)
  "#{a.valid?} #{render(a.errors.full_messages)}"
end
case_run("val2_acceptance_true") do
  a = AccPost.new(title: "t", views: 0)
  a.terms = true
  a.valid?
end
case_run("val2_if_skipped") { IfAuthor.new(bio: "way too long bio").valid? }
case_run("val2_if_applied") do
  a = IfAuthor.new(bio: "way too long bio")
  a.strict_mode = true
  "#{a.valid?} #{render(a.errors.full_messages)}"
end
case_run("val2_on_create_ok") do
  CtxAuthor.new(bio: "b").valid?
end
case_run("val2_on_create_missing") do
  a = CtxAuthor.new
  "#{a.valid?} #{render(a.errors.full_messages)}"
end
case_run("val2_on_update_ctx") do
  a = CtxAuthor.new(bio: "b")
  "#{a.valid?(:update)} #{render(a.errors.full_messages)}"
end
case_run("val2_uniqueness_scope") do
  ScopedComment.create!(post_id: 1, body: "sc1")
  dup = ScopedComment.new(post_id: 1, body: "sc1")
  other = ScopedComment.new(post_id: 2, body: "sc1")
  "#{dup.valid?} #{other.valid?}"
end
case_run("val2_details") do
  a = IncAuthor.new(name: "Zoe")
  a.valid?
  a.errors.details
end
case_run("val2_where_typed") do
  a = IncAuthor.new(name: "Zoe")
  a.valid?
  "#{a.errors.where(:name, :inclusion).size} #{a.errors.where(:name, :blank).size}"
end
case_run("val2_group_by") do
  a = IncAuthor.new(name: "Zoe", bio: "spam")
  a.valid?
  a.errors.group_by_attribute.keys.sort
end
case_run("val2_strict") do
  StrictAuthor.new.valid?
rescue StandardError => e
  "raise:#{e.class.name.split('::').last}"
end

# --- around callbacks + after_initialize/find/touch (§4) ------------------
# (around_* use the method form: `yield` is a syntax error inside blocks
# defined at Ruby class level)
class AroundPost < ActiveRecord::Base
  self.table_name = "posts"
  around_save :ar_save
  around_create :ar_create
  around_update :ar_update
  around_destroy :ar_destroy
  before_save { $log << "bs" }
  after_save { $log << "fs" }
  after_create { $log << "fc" }
  after_update { $log << "fu" }
  before_destroy { $log << "bd" }
  after_destroy { $log << "fd" }
  after_initialize { $log << "init" }
  after_find { $log << "find" }
  after_touch { $log << "touch" }

  def ar_save
    $log << "as1"
    yield
    $log << "as2"
  end

  def ar_create
    $log << "ac1"
    yield
    $log << "ac2"
  end

  def ar_update
    $log << "au1"
    yield
    $log << "au2"
  end

  def ar_destroy
    $log << "ad1"
    yield
    $log << "ad2"
  end
end

case_run("cb2_create_order") do
  $log.clear
  AroundPost.create!(title: "cb2c", views: 0)
  $log
end
case_run("cb2_after_find") do
  $log.clear
  AroundPost.first
  $log
end
case_run("cb2_update_order") do
  p = AroundPost.create!(title: "cb2u", views: 0)
  $log.clear
  p.update(views: 1)
  $log
end
case_run("cb2_destroy_order") do
  p = AroundPost.create!(title: "cb2d", views: 0)
  $log.clear
  p.destroy
  $log
end
case_run("cb2_touch") do
  p = AroundPost.create!(title: "cb2t", views: 0)
  $log.clear
  p.touch
  $log
end

# --- persistence tail (§6) -------------------------------------------------
class LegacyPost < ActiveRecord::Base
  self.table_name = "posts"
end

case_run("p3_reload") do
  p = Post.create!(title: "rl", views: 1)
  Post.find(p.id).update_columns(views: 9)
  "#{p.reload.views} #{p.reload.changed?}"
end
case_run("p3_update_attribute") do
  p = Post.create!(title: "ua", views: 1)
  result = p.update_attribute(:title, "ua2")
  "#{result == p} #{Post.find(p.id).title}"
end
case_run("p3_update_attribute_skips_validations") do
  p = Post.create!(title: "skipval", views: 1)
  p.update_attribute(:views, -5)
  Post.find(p.id).views
end
case_run("p3_increment") do
  p = Post.create!(title: "inc", views: 5)
  p.increment(:views)
  "#{p.views} #{Post.find(p.id).views}"
end
case_run("p3_increment_bang") do
  p = Post.create!(title: "incb", views: 5)
  p.increment!(:views)
  "#{p.views} #{Post.find(p.id).views}"
end
case_run("p3_decrement") do
  p = Post.create!(title: "dec", views: 5)
  "#{p.decrement(:views).views} #{Post.find(p.id).views}"
end
case_run("p3_toggle") do
  # toggle returns self (in-memory flip only); toggle! returns the save Bool
  p = Post.create!(title: "tog", views: 0, published: true)
  p.toggle(:published)
  s1 = "#{p.published} #{Post.find(p.id).published}"
  r2 = p.toggle!(:published)
  "#{s1} #{r2} #{p.published} #{Post.find(p.id).published}"
end
case_run("p3_restore_attributes") do
  p = Post.create!(title: "ra", views: 1)
  p.views = 99
  p.restore_attributes
  "#{p.changed?} #{p.views}"
end
case_run("p3_previous_changes") do
  p = Post.create!(title: "pc", views: 1)
  p.update(views: 2)
  p.previous_changes.keys.include?("views")
end
case_run("p3_instance_delete") do
  p = Post.create!(title: "pdel", views: 1)
  $log.clear
  p.delete
  "#{$log.empty?} #{Post.exists?(p.id)}"
end
case_run("p3_becomes") do
  p = Post.create!(title: "bm", views: 3)
  l = p.becomes(LegacyPost)
  "#{l.class.name} #{l.title} #{l.views} #{l.persisted?}"
end

# --- CollectionProxy tail (§5) ---------------------------------------------
case_run("proxy_concat") do
  host = Post.create!(title: "pc1", views: 0)
  c1 = Comment.new(body: "cc1")
  c2 = Comment.new(body: "cc2")
  res = host.comments.concat([c1, c2])
  "#{c1.persisted?} #{c2.persisted?} #{res.class.name.end_with?('CollectionProxy')} #{host.comments.count}"
end
case_run("proxy_include") do
  host = Post.create!(title: "pc2", views: 0)
  c = host.comments.create!(body: "ic1")
  other = Post.first.comments.create!(body: "not-mine")
  "#{host.comments.include?(c)} #{host.comments.include?(other)}"
end
case_run("proxy_destroy_one") do
  host = Post.create!(title: "pc4", views: 0)
  c = host.comments.create!(body: "dso1")
  host.comments.destroy(c)
  "#{host.comments.count} #{Comment.exists?(c.id)}"
end

# --- P1 tail: exists?/select/lock/readonly/strict_loading/pk/attribute ------
ActiveRecord::Base.connection.execute(<<~SQL)
  CREATE TABLE IF NOT EXISTS widgets (
    uid bigserial PRIMARY KEY,
    name character varying,
    stock integer DEFAULT 3
  )
SQL
ActiveRecord::Base.connection.execute("TRUNCATE widgets RESTART IDENTITY")

class Widget < ActiveRecord::Base
  self.primary_key = "uid"
end

class DefProfile < ActiveRecord::Base
  self.table_name = "profiles"
  belongs_to :author
  attribute :nickname, :string, default: "anon"
end

case_run("p1_exists_hash")    { Post.exists?(title: "first") }
case_run("p1_exists_hash_no") { Post.exists?(title: "zzz-none") }
case_run("p1_exists_nil")     { Post.exists?(score: nil) }
case_run("p1_exists_id")      { "#{Post.exists?(2)} #{Post.exists?(9999)}" }

case_run("p1_select_map") do
  Post.select(:id, :title).order(:id).map(&:title).last
end
case_run("p1_select_append") do
  Post.select(:id).select(:title).order(:id).first.title
end
case_run("p1_select_reselect") do
  Post.select(:id, :views).reselect(:title).order(:id).map(&:title).last
end

case_run("p1_lock_first") { Post.lock.order(:id).first.title }
case_run("p1_lock_share") { Post.lock("FOR SHARE").order(:id).first.title }

case_run("p1_readonly_flag")    { Post.readonly.order(:id).first.readonly? }
case_run("p1_readonly_save")    { Post.readonly.order(:id).first.update(title: "ro") }
case_run("p1_readonly_destroy") { Post.readonly.order(:id).first.destroy }

case_run("p1_strict_load_ok")    { Post.strict_loading.order(:id).first.title }
case_run("p1_strict_violation")  { Post.strict_loading.order(:id).first.comments.to_a }

case_run("p1_pk_create_find") do
  w = Widget.create!(name: "w1")
  "#{w.uid} #{Widget.find(w.uid).name} #{Widget.exists?(w.uid)}"
end
case_run("p1_pk_first_ids") do
  Widget.create!(name: "a")
  Widget.create!(name: "b")
  "#{Widget.first.name} #{Widget.ids.inspect} #{Widget.order(:uid).last.name}"
end
case_run("p1_pk_stock_default") { Widget.new.stock }
case_run("p1_pk_destroy") do
  w = Widget.create!(name: "d")
  w.destroy
  Widget.exists?(w.uid)
end

case_run("p1_attr_default_new")      { DefProfile.new.nickname }
case_run("p1_attr_default_changed")  { DefProfile.new.changed? }
case_run("p1_attr_default_override") { DefProfile.new(nickname: "zed").nickname }
case_run("p1_attr_default_saved") do
  a = Author.create!(name: "P1sv")
  p = DefProfile.create!(author: a)
  "#{p.nickname} #{p.reload.nickname}"
end
case_run("p1_attr_default_db_null") do
  a = Author.create!(name: "P1dn")
  p = DefProfile.create!(author: a)
  p.update_columns(nickname: nil)
  p.reload.nickname
end

# --- P2: through / polymorphic / HABTM / counter_cache / touch ---------------
ActiveRecord::Base.connection.execute(<<~SQL)
  ALTER TABLE posts ADD COLUMN IF NOT EXISTS author_id bigint
SQL
ActiveRecord::Base.connection.execute(<<~SQL)
  ALTER TABLE posts ADD COLUMN IF NOT EXISTS comments_count integer NOT NULL DEFAULT 0
SQL
ActiveRecord::Base.connection.execute(<<~SQL)
  CREATE TABLE IF NOT EXISTS tags (
    id bigserial PRIMARY KEY,
    name character varying NOT NULL
  )
SQL
ActiveRecord::Base.connection.execute(<<~SQL)
  CREATE TABLE IF NOT EXISTS articles (
    id bigserial PRIMARY KEY,
    title character varying NOT NULL
  )
SQL
ActiveRecord::Base.connection.execute(<<~SQL)
  CREATE TABLE IF NOT EXISTS articles_tags (
    article_id bigint NOT NULL,
    tag_id bigint NOT NULL
  )
SQL
ActiveRecord::Base.connection.execute(<<~SQL)
  CREATE TABLE IF NOT EXISTS pictures (
    id bigserial PRIMARY KEY,
    imageable_type character varying NOT NULL,
    imageable_id bigint NOT NULL,
    caption character varying
  )
SQL
ActiveRecord::Base.connection.execute("TRUNCATE tags, articles_tags, articles, pictures RESTART IDENTITY")
ActiveRecord::Base.connection.schema_cache.clear!

class TAuthor < ActiveRecord::Base
  self.table_name = "authors"
  has_many :t_posts, class_name: "TPost", foreign_key: "author_id"
  has_many :t_comments, through: :t_posts
end

class TPost < ActiveRecord::Base
  self.table_name = "posts"
  belongs_to :t_author, class_name: "TAuthor", foreign_key: "author_id", optional: true
  has_many :t_comments, class_name: "TComment", foreign_key: "post_id", inverse_of: :t_post
end

class TComment < ActiveRecord::Base
  self.table_name = "comments"
  belongs_to :t_post, class_name: "TPost", foreign_key: "post_id",
             counter_cache: :comments_count, inverse_of: :t_comments
end

class PolyPost < ActiveRecord::Base
  self.table_name = "posts"
  has_many :pictures, as: :imageable
end

class PolyAuthor < ActiveRecord::Base
  self.table_name = "authors"
  has_many :pictures, as: :imageable
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

class TouchPost < ActiveRecord::Base
  self.table_name = "posts"
  belongs_to :t_author, class_name: "TAuthor", foreign_key: "author_id",
             touch: true, optional: true
end

case_run("p2_setup") do
  conn = ActiveRecord::Base.connection
  conn.execute("UPDATE posts SET author_id = NULL, comments_count = 0")
  conn.execute(<<~SQL)
    UPDATE posts SET comments_count = (SELECT count(*) FROM comments WHERE comments.post_id = posts.id)
  SQL
  "#{Post.where("comments_count > 0").count} #{Post.count}"
end

case_run("p2_through") do
  a = TAuthor.create!(name: "TA1")
  p1 = TPost.create!(title: "tp1", t_author: a)
  p2 = TPost.create!(title: "tp2", t_author: a)
  TComment.create!(t_post: p1, body: "tc1")
  TComment.create!(t_post: p1, body: "tc2")
  TComment.create!(t_post: p2, body: "tc3")
  TPost.create!(title: "other")
  "#{a.t_posts.count} #{a.t_comments.count} #{a.t_comments.map(&:body).sort.inspect} #{a.t_comment_ids.sort.inspect}"
end

case_run("p2_counter_cache") do
  a = TAuthor.create!(name: "TA2")
  p = TPost.create!(title: "ccp", t_author: a)
  c1 = TComment.create!(t_post: p, body: "cc1")
  c2 = TComment.create!(t_post: p, body: "cc2")
  mid = TPost.find(p.id).comments_count
  c1.destroy
  "#{mid} #{TPost.find(p.id).comments_count}"
end

case_run("p2_inverse_of") do
  a = TAuthor.create!(name: "TInv")
  p = TPost.create!(title: "inv", t_author: a)
  c = p.t_comments.build(body: "ic")
  "#{c.t_post.equal?(p)} #{c.post_id == p.id} #{c.new_record?}"
end

case_run("p2_polymorphic") do
  pp = PolyPost.create!(title: "poly")
  pa = PolyAuthor.create!(name: "PA")
  Picture.create!(imageable: pp, caption: "cap1")
  Picture.create!(imageable: pa, caption: "cap2")
  "#{pp.pictures.count} #{pa.pictures.count} #{pp.pictures.order(:id).first.caption} #{Picture.order(:id).first.imageable.class.name} #{Picture.order(:id).last.imageable.class.name}"
end

case_run("p2_habtm") do
  hp = Article.create!(title: "habtm")
  t1 = Tag.create!(name: "red")
  t2 = Tag.create!(name: "blue")
  hp.tags << t1
  hp.tags << t2
  "#{hp.tags.count} #{hp.tags.map(&:name).sort.inspect} #{hp.tag_ids.sort.inspect} #{t1.articles.count}"
end

case_run("p2_habtm_delete") do
  hp = Article.create!(title: "hdel")
  t1 = Tag.create!(name: "green")
  t2 = Tag.create!(name: "white")
  hp.tags << t1
  hp.tags << t2
  hp.tags.delete(t1)
  "#{hp.tags.count} #{Tag.count} #{t1.articles.count}"
end

case_run("p2_belongs_to_touch") do
  a = TAuthor.create!(name: "TTo")
  a.update_columns(updated_at: Time.utc(2020, 1, 1))
  p = TouchPost.create!(title: "tp", t_author: a)
  after_create = (a.reload.updated_at.year == 2020)
  p.update!(title: "tp2")
  after_update = (a.reload.updated_at.year == 2020)
  p.destroy
  after_destroy = (a.reload.updated_at.year == 2020)
  "#{after_create} #{after_update} #{after_destroy}"
end

# --- P2: eager loading (includes/preload), query-count oracle ----------------
$qc = 0
ActiveSupport::Notifications.subscribe("sql.active_record") { $qc += 1 }

def qc
  before = $qc
  out = yield
  "#{render(out)} #{$qc - before}"
end

case_run("p2_includes_to_a")  { qc { Post.includes(:comments).to_a.size } }
case_run("p2_includes_first") { qc { Post.where(views: 1).includes(:comments).first.comments.size } }
case_run("p2_includes_bt")    { qc { Comment.includes(:post).where(body: "c1").to_a.map(&:post_id).inspect } }
case_run("p2_lazy_control")   { qc { Comment.where(body: "c2").first.post.class.name } }

# --- P3: optimistic locking + STI ---------------------------------------------
ActiveRecord::Base.connection.execute(<<~SQL)
  CREATE TABLE IF NOT EXISTS gadgets (
    id bigserial PRIMARY KEY,
    name character varying,
    lock_version integer NOT NULL DEFAULT 0
  )
SQL
ActiveRecord::Base.connection.execute(<<~SQL)
  CREATE TABLE IF NOT EXISTS vehicles (
    id bigserial PRIMARY KEY,
    type character varying,
    name character varying,
    wheels integer
  )
SQL
ActiveRecord::Base.connection.execute("TRUNCATE gadgets, vehicles RESTART IDENTITY")
ActiveRecord::Base.connection.schema_cache.clear!

class Gadget < ActiveRecord::Base
end

class Vehicle < ActiveRecord::Base
end

class Car < Vehicle
end

class Motorbike < Vehicle
end

case_run("p3_lock_version_incr") do
  g = Gadget.create!(name: "g2")
  v1 = g.lock_version
  g.update!(name: "g2b")
  "#{v1} #{g.lock_version} #{Gadget.find(g.id).lock_version}"
end

case_run("p3_stale_object") do
  g1 = Gadget.create!(name: "g1")
  g2 = Gadget.find(g1.id)
  g1.update!(name: "g1a")
  g2.update!(name: "g1b")
end

case_run("p3_sti_create_find") do
  v = Vehicle.create!(name: "generic")
  c = Car.create!(name: "sedan", wheels: 4)
  m = Motorbike.create!(name: "fast", wheels: 2)
  "#{Vehicle.count} #{Car.count} #{Motorbike.count} #{Vehicle.order(:id).map(&:type).compact.inspect} #{Vehicle.find(c.id).class.name} #{c.type}"
end

case_run("p3_sti_scopes") do
  "#{Car.where(wheels: 4).count} #{Car.first.class.name} #{Car.first.name}"
end

# --- P4: enum / store / secure_token / cache_key / attr_readonly / alias ------
ActiveRecord::Base.connection.execute(<<~SQL)
  CREATE TABLE IF NOT EXISTS badges (
    id bigserial PRIMARY KEY,
    name character varying,
    status integer,
    settings jsonb,
    token character varying
  )
SQL
ActiveRecord::Base.connection.execute("TRUNCATE badges RESTART IDENTITY")
ActiveRecord::Base.connection.schema_cache.clear!

class Badge < ActiveRecord::Base
  enum :status, { draft: 0, active: 1, archived: 2 }
  store :settings, accessors: [:theme]
  has_secure_token
end

class RBadge < ActiveRecord::Base
  self.table_name = "badges"
  attr_readonly :name
end

class ABadge < ActiveRecord::Base
  self.table_name = "badges"
  alias_attribute :title, :name
end

case_run("p4_enum") do
  b = Badge.create!(name: "b1", status: "active")
  "#{b.status.inspect} #{b.active?} #{b.draft?} #{Badge.active.count} #{Badge.where(status: :active).count}"
end

case_run("p4_enum_bang") do
  b = Badge.create!(name: "b2", status: :draft)
  b.archived!
  "#{b.status.inspect} #{Badge.find(b.id).status.inspect} #{Badge.statuses.inspect}"
end

case_run("p4_store") do
  b = Badge.create!(name: "b3")
  b.theme = "dark"
  b.save!
  "#{Badge.find(b.id).theme.inspect} #{Badge.find(b.id).settings["theme"].inspect}"
end

case_run("p4_secure_token") do
  b = Badge.create!(name: "b4")
  "#{b.token.size} #{Badge.find(b.id).token == b.token}"
end

case_run("p4_cache_key") do
  b = Badge.create!(name: "b5")
  "#{b.cache_key.split("-").first.inspect} #{Badge.new.cache_key} #{Post.first.cache_key.split("-").first.inspect}"
end

case_run("p4_attr_readonly") do
  b = RBadge.create!(name: "ro1")
  result = b.update!(name: "ro2")
  "#{result} #{RBadge.find(b.id).name.inspect}"
end

case_run("p4_alias_attribute") do
  b = ABadge.create!(title: "alias-me")
  "#{b.title.inspect} #{ABadge.where(title: "alias-me").count} #{b.name.inspect}"
end

class NAuthor < ActiveRecord::Base
  self.table_name = "authors"
  has_many :n_posts, class_name: "NPost", foreign_key: "author_id"
  accepts_nested_attributes_for :n_posts, allow_destroy: true, reject_if: :all_blank
end

class NPost < ActiveRecord::Base
  self.table_name = "posts"
  belongs_to :n_author, class_name: "NAuthor", foreign_key: "author_id", optional: true
  validates :title, presence: true, length: { maximum: 5 }
end

case_run("p5_nested_create") do
  a = NAuthor.create!(name: "NA1", n_posts_attributes: [{ title: "np1" }, { title: "np2" }])
  "#{a.persisted?} #{a.n_posts.count} #{a.n_posts.map(&:title).sort.inspect}"
end

case_run("p5_nested_update_add") do
  a = NAuthor.create!(name: "NA2")
  p = NPost.create!(title: "base", n_author: a)
  a.update!(n_posts_attributes: [{ id: p.id, title: "upd" }, { title: "added" }])
  "#{NPost.find(p.id).title.inspect} #{a.reload.n_posts.count}"
end

case_run("p5_nested_destroy") do
  a = NAuthor.create!(name: "NA3")
  p1 = NPost.create!(title: "d1", n_author: a)
  p2 = NPost.create!(title: "d2", n_author: a)
  a.update!(n_posts_attributes: [{ id: p2.id, _destroy: true }])
  "#{a.reload.n_posts.count} #{NPost.exists?(p2.id)}"
end

case_run("p5_nested_reject") do
  a = NAuthor.create!(name: "NA4")
  a.update!(n_posts_attributes: [{ title: "" }, { title: "kept" }])
  "#{a.reload.n_posts.count} #{a.n_posts.map(&:title).inspect}"
end

case_run("p5_nested_invalid") do
  a = NAuthor.create(name: "NA5", n_posts_attributes: [{ title: "waytoolong" }])
  "#{a.persisted?} #{NAuthor.where(name: "NA5").count} #{a.errors.full_messages.inspect}"
end

# --- P2: eager_load (single LEFT OUTER JOIN query) + references -------------
case_run("p2_eager_load_hm") do
  a = TAuthor.create!(name: "EL1")
  TPost.create!(title: "ep1", t_author: a)
  TPost.create!(title: "ep2", t_author: a)
  TAuthor.create!(name: "EL2") # no posts
  qc do
    authors = TAuthor.where(name: ["EL1", "EL2"]).eager_load(:t_posts).order(:name).to_a
    "#{authors.size} #{authors.map { |x| x.t_posts.map(&:title).sort }.inspect} #{authors.map(&:name).inspect}"
  end
end

case_run("p2_eager_load_bt") do
  qc do
    posts = TPost.where(title: ["ep1", "ep2"]).eager_load(:t_author).order(:title).to_a
    "#{posts.size} #{posts.map { |p| p.t_author.name }.uniq.inspect}"
  end
end

case_run("p2_eager_load_where") do
  qc do
    posts = TPost.eager_load(:t_author).where("authors.name = ?", "EL1").order("posts.title").to_a
    "#{posts.size} #{posts.map(&:title).inspect} #{posts.map { |p| p.t_author.name }.uniq.inspect}"
  end
end

case_run("p2_eager_load_references") do
  qc do
    posts = TPost.where("authors.name = ?", "EL1").includes(:t_author).references(:authors).order(:title).to_a
    "#{posts.size} #{posts.map { |p| p.t_author.name }.uniq.inspect}"
  end
end

# --- P6: serialize (JSON coder) ---------------------------------------------
ActiveRecord::Base.connection.execute(<<~SQL)
  CREATE TABLE IF NOT EXISTS prefs (
    id bigserial PRIMARY KEY,
    name character varying,
    settings text,
    tags text
  )
SQL
ActiveRecord::Base.connection.execute("TRUNCATE prefs RESTART IDENTITY")
ActiveRecord::Base.connection.schema_cache.clear!

class Pref < ActiveRecord::Base
  serialize :settings, coder: JSON
  serialize :tags, type: Array, coder: JSON
end

case_run("p6_ser_assign_read") do
  p = Pref.new(name: "s1")
  p.settings = {"theme" => "dark", "count" => 2}
  "#{render(p.settings["theme"])} #{render(p.settings["count"])} #{p.changed?}"
end

case_run("p6_ser_roundtrip") do
  p = Pref.create!(name: "s2")
  p.settings = {"theme" => "dark", "count" => 2}
  p.save!
  fresh = Pref.find(p.id)
  "#{render(fresh.settings["theme"])} #{render(fresh.settings["count"])} #{fresh.settings.keys.sort.inspect} #{render(p.reload.settings["count"])}"
end

case_run("p6_ser_update") do
  p = Pref.create!(name: "s3", settings: {"theme" => "light"})
  p.settings = {"theme" => "dark", "count" => 7}
  p.save!
  raw = ActiveRecord::Base.connection.select_value(
    "SELECT settings FROM prefs WHERE id = #{p.id}").to_s
  "#{render(JSON.parse(raw)["theme"])} #{render(JSON.parse(raw)["count"])} #{render(Pref.find(p.id).settings["theme"])}"
end

case_run("p6_ser_array") do
  p = Pref.new(name: "s4")
  p.tags = ["a", "b"]
  p.save!
  "#{render(Pref.find(p.id).tags)} #{render(p.reload.tags)}"
end

case_run("p6_ser_array_default") do
  "#{render(Pref.new.tags)} #{render(Pref.create!(name: "s5").reload.tags)}"
end

case_run("p6_ser_array_update") do
  p = Pref.create!(name: "s6", tags: ["x"])
  p.tags << "y"
  p.save!
  render(Pref.find(p.id).tags)
end

# --- P6: association autosave ------------------------------------------------
class AutoComment < ActiveRecord::Base
  self.table_name = "comments"
  belongs_to :auto_post, class_name: "AutoPost", foreign_key: "post_id", optional: true
  validates :body, presence: true
end

class AutoPost < ActiveRecord::Base
  self.table_name = "posts"
  has_many :auto_comments, class_name: "AutoComment", foreign_key: "post_id", autosave: true
end

class AutoReply < ActiveRecord::Base
  self.table_name = "comments"
  belongs_to :auto_thread, class_name: "AutoThread", foreign_key: "post_id",
                           autosave: true, optional: true
  validates :body, presence: true
end

class AutoThread < ActiveRecord::Base
  self.table_name = "posts"
  validates :title, presence: true
end

case_run("p6_autosave_hm_new") do
  ap = AutoPost.create!(title: "ap1")
  ap.auto_comments.build(body: "ac1")
  ap.save
  "#{AutoComment.where(post_id: ap.id).count} #{render(ap.auto_comments.order(:id).first.body)}"
end

case_run("p6_autosave_hm_dirty") do
  ap = AutoPost.create!(title: "ap2")
  c = ap.auto_comments.create!(body: "dirty1")
  ap.auto_comments.to_a # load the target (Rails: mutations stick on loaded records)
  ap.auto_comments.first.body = "dirty2"
  ap.save
  render(AutoComment.find(c.id).body)
end

case_run("p6_autosave_hm_invalid") do
  ap = AutoPost.create!(title: "ap3")
  ap.auto_comments.build(body: nil)
  valid = ap.valid?
  messages = ap.errors.full_messages.inspect
  saved = ap.save
  "#{valid} #{messages} #{saved} #{AutoComment.where(post_id: ap.id).count}"
end

case_run("p6_autosave_bt_new") do
  r = AutoReply.new(body: "btc1")
  r.auto_thread = AutoThread.new(title: "btp")
  saved = r.save
  "#{saved} #{render(r.post_id)} #{r.persisted?} #{render(AutoThread.where(title: "btp").count)}"
end

case_run("p6_autosave_bt_dirty") do
  t = AutoThread.create!(title: "btp2")
  r = AutoReply.create!(body: "btc2", auto_thread: t)
  r.auto_thread.title = "btp2u"
  r.save
  render(AutoThread.find(t.id).title)
end

case_run("p6_autosave_bt_invalid") do
  r = AutoReply.new(body: "btc3")
  r.auto_thread = AutoThread.new(title: nil)
  valid = r.valid?
  "#{valid} #{r.errors.full_messages.inspect} #{r.save} #{r.persisted?} #{AutoThread.where(title: nil).count}"
end

# --- association callbacks (before_add/after_add/before_remove/after_remove) -

$cb_log = []

class CbArticle < ActiveRecord::Base
  self.table_name = "articles"
  has_and_belongs_to_many :cb_tags, class_name: "CbTag", join_table: :articles_tags,
    foreign_key: :article_id, association_foreign_key: :tag_id,
    before_add: [:cb_tag_first, :cb_tag_second], after_add: :cb_tag_after_add,
    before_remove: :cb_tag_before_remove, after_remove: :cb_tag_after_remove

  def cb_tag_first(tag)  = $cb_log << "before_add1:#{tag.name}"
  def cb_tag_second(tag) = $cb_log << "before_add2:#{tag.name}"
  def cb_tag_after_add(tag) = $cb_log << "after_add:#{tag.name}"
  def cb_tag_before_remove(tag) = $cb_log << "before_remove:#{tag.name}"
  def cb_tag_after_remove(tag) = $cb_log << "after_remove:#{tag.name}"
end

class CbTag < ActiveRecord::Base
  self.table_name = "tags"
end

class CbPost < ActiveRecord::Base
  self.table_name = "posts"
  has_many :cb_comments, class_name: "CbComment", foreign_key: "post_id",
    before_add: :cb_comment_before_add, after_add: :cb_comment_after_add,
    before_remove: :cb_comment_before_remove, after_remove: :cb_comment_after_remove

  def cb_comment_before_add(rec) = $cb_log << "hm_before_add"
  def cb_comment_after_add(rec) = $cb_log << "hm_after_add"
  def cb_comment_before_remove(rec) = $cb_log << "hm_before_remove"
  def cb_comment_after_remove(rec) = $cb_log << "hm_after_remove"
end

class CbComment < ActiveRecord::Base
  self.table_name = "comments"
end

case_run("p2_assoc_cb_habtm") do
  a = CbArticle.create!(title: "cba")
  t = CbTag.create!(name: "cbgold")
  a.cb_tags << t
  a.cb_tags.delete(t)
  "#{$cb_log.join(',')} #{a.cb_tags.count}"
end

case_run("p2_assoc_cb_has_many") do
  p = CbPost.create!(title: "cbp")
  p.cb_comments << CbComment.new(body: "cbc")
  p.cb_comments.destroy(p.cb_comments.first)
  $cb_log.join(",")
end
