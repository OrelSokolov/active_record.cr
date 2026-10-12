# db/schema.cr — the Rails db/schema.rb analog.
#
# SchemaDumper.dump_cr regenerates the file from the database with Rails 8.1
# schema.rb syntax 1:1 (byte-exact against the oracle: oracle/schema.rb run
# with the ORIGINAL activerecord 8.1.4 → oracle/schema_expected.cr).
# `crails db:schema:load` compiles a tiny runner that requires db/schema.cr;
# the DSL executes through the same schema statements as migrations.

module ActiveRecord
  module Schema
    # ActiveRecord::Schema[8.1].define(version: ...) — the version index is
    # accepted for syntax parity and ignored (single ported Rails version).
    def self.[](_version : Float64)
      self
    end

    def self.define(version : Int64, &block) : Nil
      migration = Migration.new(version)
      with migration yield # block body resolves against the migration (DSL)
      assume_migrated_upto(version)
    end

    # Rails' assume_migrated_upto_version: mark everything up to `version`
    # as applied (versions of db/migrate/*.cr files <= version, plus the
    # version itself) so a later `db:migrate` skips them.
    def self.assume_migrated_upto(version : Int64) : Nil
      Base.connection.exec(%(CREATE TABLE IF NOT EXISTS "schema_migrations" (
        "version" bigint NOT NULL PRIMARY KEY)))
      versions = Set{version}
      Dir.glob("db/migrate/*.cr").each do |file|
        v = File.basename(file, ".cr").split('_', 2)[0].to_i64?
        versions << v if v && v <= version
      end
      versions.each do |v|
        Base.connection.exec(
          %(INSERT INTO "schema_migrations" ("version") VALUES ($1) ON CONFLICT DO NOTHING),
          args: [v])
      end
    end
  end
end
