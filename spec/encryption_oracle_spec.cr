# Oracle spec: ActiveRecord::Encryption против
# oracle/encryption_expected.yml (rails 8.1.4, снят oracle/
# encryption_cases.rb с pinned-ключами). Те же case-ID, те же ожидания
# (ruby-inspect формат). Реверс: спек пишет порт-ciphertext'ы во
# временный файл → ruby oracle/verify_encryption.rb (Process.run, паттерн
# crypto_oracle_spec.cr) — гем расшифровывает их. Плюс модельные
# postgres-юниты (encrypts-макрос: геттер/сеттер/where_encrypted/save).

require "spec"
require "file_utils"
require "../src/active_record_cr"

ENC_EXPECTED = begin
  hash = {} of String => String
  File.read("#{__DIR__}/../oracle/encryption_expected.yml").each_line do |line|
    next unless line.includes?('\t')
    id, value = line.split('\t', 2)
    hash[id] = value.chomp
  end
  hash
end

PRIMARY_KEY = "primary-pk-test"
DETERMINISTIC_KEY = "deterministic-pk-test"
KEY_DERIVATION_SALT = "salt-test"

ActiveRecord::Encryption.configure(
  primary_key: PRIMARY_KEY,
  deterministic_key: DETERMINISTIC_KEY,
  key_derivation_salt: KEY_DERIVATION_SALT,
)

# --- модели (codegen по db/schema.yml; таблицу создаёт before_all) ----

class SecretNote < ActiveRecord::Base
  encrypts :title
  encrypts :content, deterministic: true
  encrypts :code, deterministic: true, key: "custom-key"
end

ENC_TEST_URL = ENV["AR_TEST_URL"]? ||
               "postgres://root@/crails_ar_test?host=/var/run/postgresql"

# --- чистый Encryptor-слой ------------------------------------------------

private def nd_scheme
  ActiveRecord::Encryption.default_scheme
end

private def det_scheme
  ActiveRecord::Encryption.default_scheme(deterministic: true)
end

describe "ActiveRecord::Encryption (rails 8.1.4 oracle)" do
  it "enc_primary_derived_hex / enc_det_key_hex (PBKDF2-SHA1)" do
    nd_scheme.key_provider.encryption_key.secret.hexstring
      .should eq ENC_EXPECTED["enc_primary_derived_hex"]
    det_scheme.key_provider.encryption_key.secret.hexstring
      .should eq ENC_EXPECTED["enc_det_key_hex"]
  end

  it "enc_det_exact — deterministic ciphertext byte-exact" do
    det_scheme.serialize("some secret").inspect
      .should eq ENC_EXPECTED["enc_det_exact"]
  end

  it "enc_det_stable / enc_det_decrypt" do
    a = det_scheme.serialize("some secret")
    b = det_scheme.serialize("some secret")
    (a == b).inspect.should eq ENC_EXPECTED["enc_det_stable"]
    det_scheme.deserialize(a).inspect.should eq ENC_EXPECTED["enc_det_decrypt"]
  end

  it "enc_det_long_exact — deterministic + compression byte-exact" do
    long = "A pretty long text that goes over the compression threshold of one hundred and forty bytes, for sure. " * 3
    det_scheme.serialize(long).inspect.should eq ENC_EXPECTED["enc_det_long_exact"]
  end

  it "enc_det_iv_derived — iv = HMAC-SHA256(secret, text)[0,12]" do
    ct = det_scheme.serialize("some secret").not_nil!
    headers = JSON.parse(ct)["h"].as_h
    secret = det_scheme.key_provider.encryption_key.secret
    expected_iv = OpenSSL::HMAC.digest(:sha256, secret, "some secret")[0, 12]
    (Base64.strict_encode(expected_iv) == headers["iv"].as_s).inspect
      .should eq ENC_EXPECTED["enc_det_iv_derived"]
  end

  it "enc_nondet_different / enc_nondet_roundtrip" do
    a = nd_scheme.serialize("some secret").not_nil!
    b = nd_scheme.serialize("some secret").not_nil!
    (a != b).inspect.should eq ENC_EXPECTED["enc_nondet_different"]
    nd_scheme.deserialize(a).inspect.should eq ENC_EXPECTED["enc_nondet_roundtrip"]
  end

  it "enc_json_keys / enc_json_header_keys / enc_json_no_compressed_short" do
    ct = nd_scheme.serialize("some secret").not_nil!
    data = JSON.parse(ct)
    data.as_h.keys.sort.inspect.should eq ENC_EXPECTED["enc_json_keys"]
    data["h"].as_h.keys.sort.inspect.should eq ENC_EXPECTED["enc_json_header_keys"]
    data["h"].as_h.has_key?("c").inspect
      .should eq ENC_EXPECTED["enc_json_no_compressed_short"]
  end

  it "enc_compress_flag / enc_compress_roundtrip (>140 bytes → zlib)" do
    long = "A pretty long text that goes over the compression threshold of one hundred and forty bytes, for sure. " * 3
    ct = nd_scheme.serialize(long).not_nil!
    JSON.parse(ct)["h"].as_h["c"]?.try(&.raw).inspect
      .should eq ENC_EXPECTED["enc_compress_flag"]
    nd_scheme.deserialize(ct).inspect.should eq ENC_EXPECTED["enc_compress_roundtrip"]
  end

  it "enc_empty_roundtrip / enc_utf8_roundtrip" do
    nd_scheme.deserialize(nd_scheme.serialize("").not_nil!).inspect
      .should eq ENC_EXPECTED["enc_empty_roundtrip"]
    nd_scheme.deserialize(nd_scheme.serialize("пароль-密码").not_nil!).inspect
      .should eq ENC_EXPECTED["enc_utf8_roundtrip"]
  end

  it "enc_type_serialize / deserialize / nil (Scheme layer)" do
    det_scheme.serialize("some secret").inspect
      .should eq ENC_EXPECTED["enc_type_serialize"]
    det_scheme.deserialize(det_scheme.serialize("some secret")).inspect
      .should eq ENC_EXPECTED["enc_type_deserialize"]
    det_scheme.serialize(nil).inspect.should eq ENC_EXPECTED["enc_type_nil"]
  end

  it "enc_type_unencrypted_ok (support_unencrypted_data)" do
    scheme = ActiveRecord::Encryption.default_scheme(
      deterministic: true, support_unencrypted_data: true)
    scheme.deserialize("plain text").inspect
      .should eq ENC_EXPECTED["enc_type_unencrypted_ok"]
  end

  it "enc_type_downcase / enc_type_downcase_value" do
    scheme = ActiveRecord::Encryption.default_scheme(deterministic: true, downcase: true)
    (scheme.serialize("ABC") == scheme.serialize("abc")).inspect
      .should eq ENC_EXPECTED["enc_type_downcase"]
    scheme.deserialize(scheme.serialize("ABC")).inspect
      .should eq ENC_EXPECTED["enc_type_downcase_value"]
  end

  it "enc_wrong_key_class / enc_garbage_class / enc_unencrypted_class" do
    begin
      det_scheme.deserialize(nd_scheme.serialize("some secret"))
      fail("expected Decryption")
    rescue ex : ActiveRecord::Encryption::Errors::Decryption
      ex.class.name.should eq ENC_EXPECTED["enc_wrong_key_class"]
    end

    begin
      det_scheme.deserialize("not-json")
      fail("expected Decryption")
    rescue ex : ActiveRecord::Encryption::Errors::Decryption
      ex.class.name.should eq ENC_EXPECTED["enc_garbage_class"]
    end

    begin
      det_scheme.deserialize("plain text")
      fail("expected Decryption")
    rescue ex : ActiveRecord::Encryption::Errors::Decryption
      ex.class.name.should eq ENC_EXPECTED["enc_unencrypted_class"]
    end
  end

  it "enc_encrypted_yes / enc_encrypted_no" do
    ct = nd_scheme.serialize("some secret").not_nil!
    ActiveRecord::Encryption.encryptor.encrypted?(ct).inspect
      .should eq ENC_EXPECTED["enc_encrypted_yes"]
    ActiveRecord::Encryption.encryptor.encrypted?("garbage").inspect
      .should eq ENC_EXPECTED["enc_encrypted_no"]
  end
end

# --- реверс: гем читает порт-ciphertext'ы ---------------------------------

describe "encryption reverse (gem reads the port's ciphertexts)" do
  it "decrypts nd / det / custom-key ciphertexts" do
    file = File.join(Dir.tempdir, "crails_enc_rev_#{Random::Secure.hex(4)}.txt")
    lines = [] of {String, String, String}
    lines << {"rev_nd", "nd", nd_scheme.serialize("reverse payload").not_nil!}
    lines << {"rev_det", "det", det_scheme.serialize("reverse payload").not_nil!}
    custom = ActiveRecord::Encryption.default_scheme(deterministic: true, key: "custom-key")
    lines << {"rev_custom", "custom", custom.serialize("custom payload").not_nil!}
    File.write(file, lines.map { |l| l.join('\t') }.join('\n') + '\n')

    env = {"GEM_HOME" => ENV["GEM_HOME"]? || "", "PATH" => ENV["PATH"]? || ""}
    status = Process.run(
      "ruby", ["#{__DIR__}/../oracle/verify_encryption.rb", file],
      output: output = IO::Memory.new, error: STDERR, env: env)
    status.success?.should be_true
    got = {} of String => String
    output.to_s.each_line do |l|
      id, v = l.split('\t', 2)
      got[id] = v.chomp
    end
    got["rev_nd"].should eq %("reverse payload")
    got["rev_det"].should eq %("reverse payload")
    got["rev_custom"].should eq %("custom payload")
  ensure
    File.delete(file) if file && File.exists?(file)
  end
end

# --- модельный слой (postgres) ----------------------------------------------

describe "encrypts macro (postgres)" do
  before_all do
    ActiveRecord::Base.establish_connection(ENC_TEST_URL)
    ActiveRecord::Base.connection.exec("DROP TABLE IF EXISTS secret_notes")
    ActiveRecord::Base.connection.exec(<<-SQL)
      CREATE TABLE secret_notes (
        id bigserial PRIMARY KEY,
        title text,
        content text,
        code text
      )
    SQL
  end

  after_each do
    ActiveRecord::Base.connection.exec("DELETE FROM secret_notes")
  end

  it "stores ciphertext, reads cleartext (nd + det + custom key)" do
    note = SecretNote.new
    note.title = "plain title"
    note.content = "deterministic body"
    note.code = "CODE-1"
    note.save

    raw = ActiveRecord::Base.connection.query_one(
      "select title, content, code from secret_notes limit 1",
      as: {String?, String?, String?}).not_nil!
    # в БД — JSON-conверт, не открытый текст
    raw_title, raw_content, raw_code = raw
    raw_title.not_nil!.should start_with(%({"p":))
    raw_content.not_nil!.should start_with(%({"p":))
    raw_code.not_nil!.should start_with(%({"p":))
    raw_title.not_nil!.should_not contain("plain title")

    loaded = SecretNote.find?(note.id.not_nil!).not_nil!
    loaded.title.should eq("plain title")
    loaded.content.should eq("deterministic body")
    loaded.code.should eq("CODE-1")
  end

  it "deterministic attribute is byte-stable and searchable" do
    a = SecretNote.create({"content" => "same-secret"})
    b = SecretNote.create({"content" => "same-secret"})
    a.ciphertext_for("content").should eq b.ciphertext_for("content")

    found = SecretNote.where_encrypted("content", "same-secret").to_a
    found.size.should eq(2)

    SecretNote.where_encrypted("content", "other").to_a.size.should eq(0)
  end

  it "deterministic ciphertext matches the gem oracle byte-exact" do
    # enc_det_exact уже сверен в чистом слое; тут — тот же ciphertext
    # через модельный путь (encrypts-сеттер)
    SecretNote.new(content: "some secret").ciphertext_for("content")
      .should eq(det_scheme.serialize("some secret"))
  end

  it "encrypted_attributes / nil roundtrip / unencrypted raises" do
    SecretNote.encrypted_attributes.should eq(["title", "content", "code"])

    note = SecretNote.new
    note.title = nil
    note.save
    SecretNote.find?(note.id.not_nil!).not_nil!.title.should be_nil

    # голая строка в колонке без support_unencrypted_data → Decryption
    ActiveRecord::Base.connection.exec(
      "insert into secret_notes (title) values ('plain')")
    id = ActiveRecord::Base.connection.query_one(
      "select max(id) from secret_notes", as: Int64)
    begin
      SecretNote.find?(id).not_nil!.title
      fail("expected Decryption")
    rescue ex : ActiveRecord::Encryption::Errors::Decryption
      ex.class.name.should eq("ActiveRecord::Encryption::Errors::Decryption")
    end
  end

  it "where_encrypted raises on non-deterministic attribute" do
    begin
      SecretNote.where_encrypted("title", "x").to_a
      fail("expected ArgumentError")
    rescue ex : ArgumentError
      ex.message.not_nil!.should contain("not a deterministic encrypted attribute")
    end
  end
end
