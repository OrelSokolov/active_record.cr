# ar_schema_dump: dumps the public schema of the connected database into
# db/schema.cr (the Rails schema.rb analog — SchemaDumper.dump_cr, 1:1 with
# the activerecord 8.1.4 oracle) plus db/schema.yml (the model-codegen
# fallback). Library twin: ActiveRecord::SchemaDumper (src/schema_dumper.cr),
# used by `crails db:migrate / db:schema:dump / db:schema:load`.
#
#   DATABASE_URL=postgres://... bin/ar_schema_dump [out_prefix_dir]

require "../src/active_record_cr"
require "yaml"

url = ARGV[0]? || ENV["DATABASE_URL"]? || abort "usage: ar_schema_dump [DATABASE_URL] [out_dir]"

ActiveRecord::Base.establish_connection(url)

n = ActiveRecord::SchemaDumper.dump_cr_to_file("db/schema.cr")
puts "dumped #{n} tables -> db/schema.cr"
ActiveRecord::SchemaDumper.dump_to_file("db/schema.yml")
puts "dumped db/schema.yml (model codegen input)"
