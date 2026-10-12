# Oracle: ActiveRecord::Encryption 8.1.4 (activerecord-8.1.4/lib/
# active_record/encryption/**). Standalone (no DB): the Encryptor /
# MessageSerializer / EncryptedAttributeType APIs are exercised directly
# with pinned keys.
#
#   ruby oracle/encryption_cases.rb > oracle/encryption_expected.yml
#
# Fixed keys (mirrored in spec/encryption_oracle_spec.cr):
PRIMARY_KEY = "primary-pk-test"
DETERMINISTIC_KEY = "deterministic-pk-test"
KEY_DERIVATION_SALT = "salt-test"

require "active_record"
require "json"
require "openssl"

ActiveRecord::Encryption.configure(
  primary_key: PRIMARY_KEY,
  deterministic_key: DETERMINISTIC_KEY,
  key_derivation_salt: KEY_DERIVATION_SALT,
)

def emit(id, value)
  puts "#{id}\t#{value}"
end

encryptor = ActiveRecord::Encryption.encryptor
det_scheme = ActiveRecord::Encryption::Scheme.new(deterministic: true)

# --- key derivation ---------------------------------------------------
emit("enc_primary_derived_hex",
     ActiveRecord::Encryption.key_provider.encryption_key.secret.unpack1("H*"))
emit("enc_det_key_hex",
     det_scheme.key_provider.encryption_key.secret.unpack1("H*"))

# --- deterministic encryption (byte-exact) -----------------------------
det_ct = encryptor.encrypt("some secret", key_provider: det_scheme.key_provider,
                                          cipher_options: { deterministic: true })
emit("enc_det_exact", det_ct.inspect)
det_ct2 = encryptor.encrypt("some secret", key_provider: det_scheme.key_provider,
                                           cipher_options: { deterministic: true })
emit("enc_det_stable", (det_ct == det_ct2).inspect)
emit("enc_det_decrypt",
     encryptor.decrypt(det_ct, key_provider: det_scheme.key_provider).inspect)

# deterministic IV = HMAC-SHA256(secret, clear_text)[0, 12]
require "openssl"
det_secret = det_scheme.key_provider.encryption_key.secret
expected_iv = OpenSSL::HMAC.digest("SHA256", det_secret, "some secret")[0, 12]
emit("enc_det_iv_derived", (JSON.parse(det_ct)["h"]["iv"] == [expected_iv].pack("m0")).inspect)

# --- non-deterministic encryption --------------------------------------
kp = ActiveRecord::Encryption.key_provider
nd1 = encryptor.encrypt("some secret", key_provider: kp)
nd2 = encryptor.encrypt("some secret", key_provider: kp)
emit("enc_nondet_different", (nd1 != nd2).inspect)
emit("enc_nondet_roundtrip", encryptor.decrypt(nd1, key_provider: kp).inspect)

# --- wire format (JSON + base64) ---------------------------------------
data = JSON.parse(nd1)
emit("enc_json_keys", data.keys.sort.inspect)
emit("enc_json_header_keys", data["h"].keys.sort.inspect)
emit("enc_json_no_compressed_short", data["h"].key?("c").inspect)

# --- compression (> 140 bytes) ------------------------------------------
long_text = "A pretty long text that goes over the compression threshold of one hundred and forty bytes, for sure. " * 3
long_ct = encryptor.encrypt(long_text, key_provider: kp)
emit("enc_compress_flag", JSON.parse(long_ct)["h"]["c"].inspect)
emit("enc_compress_roundtrip", encryptor.decrypt(long_ct, key_provider: kp).inspect)

# --- empty / utf8 --------------------------------------------------------
emit("enc_empty_roundtrip",
     encryptor.decrypt(encryptor.encrypt("", key_provider: kp), key_provider: kp).inspect)
emit("enc_utf8_roundtrip",
     encryptor.decrypt(encryptor.encrypt("пароль-密码", key_provider: kp), key_provider: kp).inspect)

# --- attribute type layer ------------------------------------------------
type = ActiveRecord::Encryption::EncryptedAttributeType.new(scheme: det_scheme)
emit("enc_type_serialize", type.serialize("some secret").inspect)
emit("enc_type_deserialize", type.deserialize(type.serialize("some secret")).inspect)
emit("enc_type_nil", type.serialize(nil).inspect)

support_type = ActiveRecord::Encryption::EncryptedAttributeType.new(
  scheme: ActiveRecord::Encryption::Scheme.new(deterministic: true, support_unencrypted_data: true))
emit("enc_type_unencrypted_ok", support_type.deserialize("plain text").inspect)

downcase_type = ActiveRecord::Encryption::EncryptedAttributeType.new(
  scheme: ActiveRecord::Encryption::Scheme.new(deterministic: true, downcase: true))
emit("enc_type_downcase", (downcase_type.serialize("ABC") == downcase_type.serialize("abc")).inspect)
emit("enc_type_downcase_value", downcase_type.deserialize(downcase_type.serialize("ABC")).inspect)

# --- errors -----------------------------------------------------------------
begin
  encryptor.decrypt(nd1, key_provider: det_scheme.key_provider)
  emit("enc_wrong_key_class", "no-error")
rescue => e
  emit("enc_wrong_key_class", e.class.name)
end

begin
  ActiveRecord::Encryption::EncryptedAttributeType.new(scheme: det_scheme).deserialize("not-json")
  emit("enc_garbage_class", "no-error")
rescue => e
  emit("enc_garbage_class", e.class.name)
end

begin
  ActiveRecord::Encryption::EncryptedAttributeType.new(
    scheme: ActiveRecord::Encryption::Scheme.new(deterministic: true)).deserialize("plain text")
  emit("enc_unencrypted_class", "no-error")
rescue => e
  emit("enc_unencrypted_class", e.class.name)
end

# --- encrypted? helper -------------------------------------------------------
emit("enc_encrypted_yes", encryptor.encrypted?(nd1).inspect)
emit("enc_encrypted_no", encryptor.encrypted?("garbage").inspect)
