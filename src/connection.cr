# Connection management: URL, Rails-style keyword config, database.yml.
# PostgreSQL via crystal-pg (DB::Database with a built-in fiber-safe pool).

module ActiveRecord
  class ConnectionNotEstablished < Exception
  end

  class Base
    @@db : DB::Database?
    @@schema_search_path : String?
    @@adapter_scheme : String?

    def self.establish_connection(url : String) : DB::Database
      scheme = URI.parse(url).scheme.to_s
      db = DB.open(url)
      @@adapter_scheme = scheme
      configure_adapter(db, scheme, url)
      @@db.try(&.close)
      @@db = db
      case scheme
      when "postgres", "postgresql"
        if path = @@schema_search_path
          self.schema_search_path = path
        end
      end
      db
    rescue ex
      raise ConnectionNotEstablished.new(
        "Failed to connect to #{url.gsub(/\/\/[^@]*@/, "//***@")}: #{ex.message}")
    end

    # Adapter of the live connection ("postgres", "sqlite3", ...).
    def self.adapter_name : String
      @@adapter_scheme || ""
    end

    def self.sqlite? : Bool
      @@adapter_scheme == "sqlite3"
    end

    # Adapter tuning applied right after connect. SQLite gets the Rails 8
    # pragma set (WAL, synchronous=NORMAL, journal_size_limit 64 MB,
    # cache_size 2000, mmap off); everything but journal_size_limit rides
    # on the URI (the sqlite3 shard applies those per pooled connection),
    # journal_size_limit needs a per-connection exec.
    #
    # Raw DATABASE_URL (no query params) bypasses build_url's pragma
    # params — Rails merges ENV["DATABASE_URL"] into database.yml config,
    # so the adapter defaults still apply. Mirror that: pragmas missing
    # from the URI get the Rails 8 defaults per pooled connection
    # (journal_mode is persisted in the file; setting WAL here is a
    # no-op for WAL databases and converts rollback-journal ones, the
    # same behavior a Rails deployment has).
    private def self.configure_adapter(db : DB::Database, scheme : String, url : String) : Nil
      return unless scheme == "sqlite3"
      url_params = HTTP::Params.parse(URI.parse(url).query || "")
      default = ->(key : String, value : String) do
        url_params[key]? || value
      end
      db.setup_connection do |conn|
        # busy_timeout обязателен при многопроцессном доступе (serverX
        # workers / jobs): без него конкурентные записи ловят
        # SQLite3::Exception "database is locked".
        conn.exec("PRAGMA busy_timeout=#{default.call("busy_timeout", "10000")}")
        conn.exec("PRAGMA journal_mode=#{default.call("journal_mode", "wal")}")
        conn.exec("PRAGMA synchronous=#{default.call("synchronous", "normal")}")
        conn.exec("PRAGMA cache_size=#{default.call("cache_size", "2000")}")
        conn.exec("PRAGMA foreign_keys=#{default.call("foreign_keys", "on")}")
        conn.exec("PRAGMA journal_size_limit=#{default.call("journal_size_limit", "67108864")}")
        conn.exec("PRAGMA mmap_size=#{default.call("mmap_size", "0")}")
        # Fair busy handler: равномерные 500µs вместо эскалирующих
        # 1→100ms дефолта (см. fair_busy.cr). busy_handler подменяет
        # busy_timeout-хендлер, установленный прагмой выше.
        FairBusy.install(conn.as(SQLite3::Connection))
      end
    end

    # Rails-style config: adapter, host, port, username, password,
    # database, sslmode, schema_search_path, pool. A host starting with
    # "/" is a unix socket directory. `pool` caps the connection pool
    # (Rails semantics, default 5); without it the pool would keep at
    # most 1 idle connection and reconnect on every concurrent request.
    def self.establish_connection(**config) : DB::Database
      @@schema_search_path = config[:schema_search_path]?
      establish_connection(build_url(**config))
    end

    # Reads config/database.yml (Rails format subset, no ERB):
    # `establish_connection_from_yaml("config/database.yml", "development")`
    def self.establish_connection_from_yaml(path : String = "config/database.yml",
                                            env : String = "development") : DB::Database
      unless File.exists?(path)
        raise ConnectionNotEstablished.new("No database config at #{path}")
      end
      conf = YAML.parse(File.read(path))[env]?
      raise ConnectionNotEstablished.new("Missing `#{env}` section in #{path}") unless conf

      establish_connection(
        adapter: conf["adapter"]?.try(&.as_s?) || "postgresql",
        host: conf["host"]?.try(&.as_s?),
        port: conf["port"]?.try(&.as_i?),
        username: conf["username"]?.try(&.as_s?),
        password: conf["password"]?.try(&.as_s?),
        database: conf["database"]?.try(&.as_s?),
        schema_search_path: conf["schema_search_path"]?.try(&.as_s?),
        pool: conf["pool"]?.try(&.as_i?),
      )
    end

    def self.connection : DB::Database
      @@db ||= begin
        url = ENV["DATABASE_URL"]?
        raise ConnectionNotEstablished.new(
          "No connection established. Call ActiveRecord::Base.establish_connection(url), " \
          "establish_connection_from_yaml(...), or set DATABASE_URL.") unless url
        establish_connection(url)
      end
    end

    def self.connected? : Bool
      !@@db.nil?
    end

    def self.build_url(**config) : String
      adapter = config[:adapter]? || "postgresql"
      case adapter
      when "sqlite3", "sqlite"
        scheme = "sqlite3"
        database = config[:database]? || raise(
          ConnectionNotEstablished.new("missing `database:`"))
        # `:memory:` and temp files are per-connection in SQLite: a pool would
        # silently give every connection its own private database (Rails
        # makes the same single-connection choice).
        pool = database == ":memory:" || database.starts_with?("file:") ? 1 : (config[:pool]? || 5)
        params = [] of String
        params << "max_pool_size=#{pool}"
        params << "max_idle_pool_size=#{pool}"
        # Rails 8 sqlite3 pragma defaults; overridable via config keys.
        params << "journal_mode=#{config[:journal_mode]? || "WAL"}"
        params << "synchronous=#{config[:synchronous]? || "NORMAL"}"
        params << "cache_size=#{config[:cache_size]? || 2000}"
        params << "busy_timeout=#{config[:busy_timeout]? || 5000}"
        params << "foreign_keys=#{config[:foreign_keys]? || "ON"}"
        return "#{scheme}://#{URI.encode_path(database)}?#{params.join("&")}"
      end
      scheme = "postgres"
      database = config[:database]? || ENV["PGDATABASE"]? || raise(
        ConnectionNotEstablished.new("missing `database:`"))
      user = config[:username]? || ENV["PGUSER"]?
      password = config[:password]? || ENV["PGPASSWORD"]?

      host = config[:host]? || ENV["PGHOST"]?
      port = config[:port]? || ENV["PGPORT"]?

      params = [] of String
      if host && host.starts_with?('/')          # unix socket directory
        params << "host=#{URI.encode_path(host)}"
        host = nil
      end
      if sslmode = config[:sslmode]?
        params << "sslmode=#{sslmode}"
      end
      # Rails `pool:` — keep up to N connections open instead of
      # reconnecting per request. Default matches Rails (5).
      if pool = config[:pool]? || 5
        params << "max_pool_size=#{pool}"
        params << "max_idle_pool_size=#{pool}"
      end

      String.build do |io|
        io << scheme << "://"
        if user
          io << URI.encode_www_form(user)
          io << ":" << URI.encode_www_form(password) if password
          io << "@"
        end
        io << host if host
        io << ":" << port if host && port
        io << "/" << URI.encode_path(database)
        io << "?" << params.join("&") unless params.empty?
      end
    end

    def self.schema_search_path=(path : String) : Nil
      @@schema_search_path = path
      quoted = path.split(",").map { |part| %("#{part.strip.gsub('"', "")}") }.join(", ")
      connection.exec("SET search_path TO #{quoted}")
    end
  end
end
