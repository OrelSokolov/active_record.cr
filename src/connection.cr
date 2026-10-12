# Connection management: URL, Rails-style keyword config, database.yml.
# PostgreSQL via crystal-pg (DB::Database with a built-in fiber-safe pool).

module ActiveRecord
  class ConnectionNotEstablished < Exception
  end

  class Base
    @@db : DB::Database?
    @@schema_search_path : String?

    def self.establish_connection(url : String) : DB::Database
      db = DB.open(url)
      @@db.try(&.close)
      @@db = db
      if path = @@schema_search_path
        self.schema_search_path = path
      end
      db
    rescue ex
      raise ConnectionNotEstablished.new(
        "Failed to connect to #{url.gsub(/\/\/[^@]*@/, "//***@")}: #{ex.message}")
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
      scheme = adapter == "postgres" ? "postgres" : "postgres"
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
