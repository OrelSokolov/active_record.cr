# Demo: reading the datalake with ActiveRecord.cr, 1:1 Rails API.
#
#   DATABASE_URL='postgres://root@/data_lake_development?host=/var/run/postgresql' \
#     crystal run examples/datalake_read.cr

require "../src/active_record_cr"

# Models generated from db/schema.yml at compile time.
class Player < ActiveRecord::Base
end

class Academy < ActiveRecord::Base
end

class Coach < ActiveRecord::Base
end

class AdminUser < ActiveRecord::Base
end

class PriorityMatch < ActiveRecord::Base
end

class PlayerInjury < ActiveRecord::Base
end

ActiveRecord::Base.establish_connection(
  database: ENV["PGDATABASE"]? || "data_lake_development",
  username: ENV["PGUSER"]? || "root",
  host: "/var/run/postgresql",
)

puts "connected to #{ActiveRecord::Base.connection.query_one("select current_database()", as: String)}"
puts

puts "Players.count            => #{Player.count}"
puts "Academy.count            => #{Academy.count}"
puts "AdminUser.count          => #{AdminUser.count}"
puts "PriorityMatch.count      => #{PriorityMatch.count}"
puts "PlayerInjury.count       => #{PlayerInjury.count}"
puts

puts "Player.table_name        => #{Player.table_name}"
puts "Player.__column_names    => #{Player.__column_names}"
puts

puts "Player.where(gender: \"male\").limit(3).to_sql"
puts "  #{Player.where(gender: "male").limit(3).to_sql}"
puts

# Empty dev database → Rails semantics for missing records.
if player = Player.first
  puts "Player.first             => #{player.inspect}"
else
  puts "Player.first             => nil (dev database is empty)"
end

new_player = Player.new(external_id: "demo-1", first_name: "Demo", last_name: "Player")
puts "Player.new(...).inspect  => #{new_player.inspect}"
