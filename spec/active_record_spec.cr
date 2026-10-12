require "spec"
require "../src/active_record_cr"

# --- models (compile-time codegen from db/schema.yml) ---

class Post < ActiveRecord::Base
end

class Comment < ActiveRecord::Base
end

TEST_URL   = ENV["AR_TEST_URL"]? ||
             "postgres://root@/crails_ar_test?host=/var/run/postgresql"
DATALAKE_URL = ENV["DATABASE_URL"]? ||
               "postgres://root@/data_lake_development?host=/var/run/postgresql"

# --- fixtures suite (crails_ar_test) ---

describe "ActiveRecord read API (fixtures)" do
  before_all do
    ActiveRecord::Base.establish_connection(TEST_URL)
  end

  describe "connection" do
    it "connects to the right database" do
      ActiveRecord::Base.connection.query_one("select current_database()", as: String)
        .should eq("crails_ar_test")
    end

    it "counts via raw connection" do
      ActiveRecord::Base.connection.query_one("select count(*) from posts", as: Int64)
        .should eq(5)
    end
  end

  describe "codegen (schema.yml → attributes)" do
    it "generates table_name" do
      Post.table_name.should eq("posts")
      Comment.table_name.should eq("comments")
    end

    it "generates typed attributes with setters" do
      post = Post.new(title: "x", views: 3, published: true)
      post.title.should eq("x")
      post.views.should eq(3)
      post.published?.should be_true
      post.score.should be_nil
      post.id.should be_nil
      post.new_record?.should be_true
      post.persisted?.should be_false
    end

    it "exposes attributes hash and []" do
      post = Post.new(title: "x")
      post.attributes["title"].should eq("x")
      post["views"].should eq(0_i64) # schema defaults ARE applied to new records (activerecord semantics)
    end
  end

  describe "find / find_by" do
    it "find by id" do
      post = Post.find(1)
      post.id.should eq(1)
      post.persisted?.should be_true
      post.title.should eq("Hello")
    end

    it "raises RecordNotFound" do
      expect_raises(ActiveRecord::RecordNotFound, /Couldn't find/) { Post.find(999) }
      Post.find?(999).should be_nil
    end

    it "find_by with attributes" do
      Post.find_by(title: "Hello").try(&.id).should eq(1)
      Post.find_by(title: "nope").should be_nil
      expect_raises(ActiveRecord::RecordNotFound) { Post.find_by!(title: "nope") }
    end
  end

  describe "where" do
    it "hash conditions" do
      Post.where(published: true).count.should eq(3)
      Post.where(published: false, views: 0).count.should eq(1)
    end

    it "string conditions with args" do
      Post.where("views > ?", 10).count.should eq(2)
      Post.where("views > ? AND published = ?", 10, true).count.should eq(2)
    end

    it "nil → IS NULL, ranges → BETWEEN, arrays → IN" do
      Post.where(body: nil).count.should eq(1)
      Post.where(views: 3..42).count.should eq(3) # 3, 10, 42
      Post.where(title: ["Hello", "Fifth"]).order(:id).ids.should eq([1, 5])
      Comment.where(author: nil).count.should eq(2)
    end

    it "where.not" do
      Post.not(published: true).count.should eq(2)
      Comment.not(author: nil).count.should eq(6)
    end
  end

  describe "order / limit / offset" do
    it "orders by symbol and hash" do
      Post.order(:views).ids.should eq([4, 2, 1, 3, 5])
      Post.order(views: :desc).ids.should eq([5, 3, 1, 2, 4])
      Post.order("views DESC").ids.should eq([5, 3, 1, 2, 4])
    end

    it "limits and offsets" do
      Post.order(:id).limit(2).ids.should eq([1, 2])
      Post.order(:id).limit(2).offset(2).ids.should eq([3, 4])
    end
  end

  describe "first / last / take / sole" do
    it "first and last by pk" do
      Post.first.try(&.id).should eq(1)
      Post.last.try(&.id).should eq(5)
    end

    it "sole raises on zero or many" do
      expect_raises(ActiveRecord::RecordNotFound) { Post.where(views: 999).sole }
      Post.where(views: 42).sole.id.should eq(3)
    end
  end

  describe "aggregates" do
    it "count / exists? / empty?" do
      Post.count.should eq(5)
      Comment.count.should eq(8)
      Post.exists?.should be_true
      Post.where(title: "zzz").exists?.should be_false
      Post.where(title: "zzz").empty?.should be_true
    end

    it "pluck / pick / ids" do
      Post.order(:id).pluck(:title).should eq(["Hello", "Second", "Third post", "Fourth", "Fifth"])
      Post.order(:id).pluck(:views).should eq([10_i64, 3_i64, 42_i64, 0_i64, 100_i64])
      Post.where(id: 1).pick(:title).should eq("Hello")
      Post.order(:views).reverse_order.ids.should eq([5, 3, 1, 2, 4])
    end
  end

  describe "find_each" do
    it "batches by pk" do
      ids = [] of Int64
      Post.order(:id).find_each(batch_size: 2) { |p| ids << p.id.not_nil! }
      ids.should eq([1, 2, 3, 4, 5])
    end
  end

  describe "instance API" do
    it "inspect looks like Rails" do
      Post.find(1).inspect.should start_with("#<Post id: 1, title: \"Hello\"")
    end

    it "reload! refreshes attributes" do
      post = Post.find(1)
      post.views = 999
      post.reload!.views.should eq(10)
    end

    it "equality by class and id" do
      (Post.find(1) == Post.find(1)).should be_true
      (Post.find(1) == Post.find(2)).should be_false
    end
  end

  describe "typed reads (jsonb / numeric / timestamps / arrays)" do
    it "reads jsonb" do
      Post.find(1).tags.should be_a(JSON::Any)
      Post.find(1).tags.try(&.as_a.map(&.as_s)).should eq(["news", "hello"])
      Post.find(2).tags.should be_a(JSON::Any) # default '[]'::jsonb → empty array
      Post.find(2).tags.try(&.as_a).should eq([] of JSON::Any)
    end

    it "reads numeric and float" do
      post = Post.find(1)
      post.score.should eq(1.5)
      post.rating.should_not be_nil
    end

    it "reads timestamps" do
      Post.find(1).created_at.should be_a(Time)
      Post.find(1).published_at.should be_a(Time)
      Post.find(2).published_at.should be_nil
    end
  end
end

# --- datalake suite (read-only, real user database schema) ---

class Player < ActiveRecord::Base
end

class Academy < ActiveRecord::Base
end

class AdminUser < ActiveRecord::Base
end

class PlayerInjury < ActiveRecord::Base
end

class CspConfig < ActiveRecord::Base
end

describe "ActiveRecord on the datalake (read-only)" do
  before_all do
    ActiveRecord::Base.establish_connection(DATALAKE_URL)
  end

  it "connects to datalake" do
    ActiveRecord::Base.connection.query_one("select current_database()", as: String)
      .should eq("data_lake_development")
  end

  it "codegen works for real tables" do
    Player.table_name.should eq("players")
    Player.__column_names.first.should eq("id")
    Player.__column_names.should contain("coach_external_ids")
    player = Player.new(external_id: "ext-1", first_name: "A", last_name: "B")
    player.gender.should be_nil
    player.coach_external_ids.should eq([] of Int64) # schema default applied (activerecord semantics)
    player.inspect.should start_with("#<Player id: nil, external_id: \"ext-1\"")
  end

  it "empty tables behave 1:1 (dev db has no rows)" do
    Player.count.should eq(0)
    Player.exists?.should be_false
    Player.first.should be_nil
    Player.find?(1).should be_nil
    expect_raises(ActiveRecord::RecordNotFound) { Player.find(1) }
    Player.where(gender: "male").count.should eq(0)
  end

  it "to_sql references the right table" do
    Player.where(gender: "male").limit(3).to_sql.should contain(%(FROM "players"))
  end
end
