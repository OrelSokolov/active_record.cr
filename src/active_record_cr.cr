require "db"
require "pg"
require "sqlite3"
require "yaml"
require "json"
require "active_support_cr"
require "action_view_cr"

require "./connection"
require "./fair_busy"
require "./relation"
require "./encryption"
require "./base"
require "./callbacks"
require "./transactions"
require "./validations"
require "./associations"
require "./action_text"
require "./attachments"
require "./persistence"
require "./migrations"
require "./schema"
require "./schema_dumper"
require "./global_id"
require "attr_reader_cr"

module ActiveRecord
  VERSION = "0.1.0"

  # Union of all attribute types (query args use DB::Any).
  alias Value = Nil | Bool | Int64 | Float64 | String | Time | JSON::Any |
                Array(String) | Array(Int64) | Bytes | PG::Numeric

  # errors.details values carry validator types (:blank etc).
  alias DetailValue = Value | Symbol
end
