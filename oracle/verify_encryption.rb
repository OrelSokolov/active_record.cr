# Reverse oracle: the real ActiveRecord::Encryption 8.1.4 reads the
# ciphertexts written by the Crystal port.
# Input file: lines of "case_id\tdet|nd\tciphertext".
#   ruby oracle/verify_encryption.rb FILE
# Output: "case_id\tdecrypted.inspect" (or the error class name).

PRIMARY_KEY = "primary-pk-test"
DETERMINISTIC_KEY = "deterministic-pk-test"
KEY_DERIVATION_SALT = "salt-test"

require "active_record"
require "json" # MessageSerializer autoload does not require it itself

ActiveRecord::Encryption.configure(
  primary_key: PRIMARY_KEY,
  deterministic_key: DETERMINISTIC_KEY,
  key_derivation_salt: KEY_DERIVATION_SALT,
)

encryptor = ActiveRecord::Encryption.encryptor
det_kp = ActiveRecord::Encryption::Scheme.new(deterministic: true).key_provider
kp = ActiveRecord::Encryption.key_provider
custom_kp = ActiveRecord::Encryption::DerivedSecretKeyProvider.new("custom-key")

File.foreach(ARGV[0]) do |line|
  next if line.strip.empty?
  id, mode, ct = line.chomp.split("\t", 3)
  provider =
    case mode
    when "det"    then det_kp
    when "custom" then custom_kp
    else kp
    end
  begin
    puts "#{id}\t#{encryptor.decrypt(ct, key_provider: provider).inspect}"
  rescue => e
    puts "#{id}\t#{e.class.name}"
  end
end
