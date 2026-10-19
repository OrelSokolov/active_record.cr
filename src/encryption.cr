# ActiveRecord::Encryption — порт Rails 8.1.4
# (lib/active_record/encryption/*: encryptor.rb, cipher.rb + cipher/aes256_gcm.rb,
# message.rb, message_serializer.rb, properties.rb, scheme.rb, config.rb,
# key.rb, key_provider.rb, derived_secret_key_provider.rb,
# deterministic_key_provider.rb, key_generator.rb, encryptable_record.rb).
#
# Wire-формат 1:1 с гемом — Message сериализуется в JSON
#   {"p":<b64 payload>,"h":{"iv":<b64>,"at":<b64>[:,"c":true]}}
# (порядок ключей — вставки, как Ruby JSON.dump). Детерминированный режим
# побайтово совместим: iv = HMAC-SHA256(key, clear_text)[0,12]; компрессия
# Zlib (порог 140 байт, дефолтный уровень Ruby = 6).
#
# Ключи: как гем, PBKDF2-HMAC-SHA1 (2**16 итераций, AS::KeyGenerator)
# от пароля (primary_key / deterministic_key) с солью key_derivation_salt.
# Отклонение (расширение): если ключи не configure-нуты, читаются из ENV
# ACTIVE_RECORD_ENCRYPTION_{PRIMARY_KEY,DETERMINISTIC_KEY,KEY_DERIVATION_SALT}
# (гем standalone кидает Errors::Configuration).
#
# Отклонения: envelope encryption / key references (k/i-заголовки),
# previous:-схемы, ignore_case-колонки original_* и NullEncryptor-контексты
# не портированы; encrypts-макрос — deterministic/support_unencrypted_data/
# downcase/key (previous/compressor-опции игнорируются); поиск —
# Model.where_encrypted(attr, value) вместо where-врезки.
#
# Оракулы: oracle/encryption_cases.rb → oracle/encryption_expected.yml
# (enc_*), реверс — oracle/verify_encryption.rb.

require "base64"
require "json"
require "compress/zlib"
require "openssl/lib_crypto"
require "openssl/hmac"

# GCM ctrl-константы и evp_cipherctx_ctrl уже привязаны в
# active_support_cr/src/message_encryptor.cr (тот же LibCrypto).

module ActiveRecord
  module Encryption
    # This threshold cannot be changed (the gem's Encryptor): searches on
    # deterministic columns rely on compression being applied
    # deterministically above it.
    THRESHOLD_TO_JUSTIFY_COMPRESSION = 140

    AUTH_TAG_LENGTH = 16
    IV_LENGTH       = 12
    KEY_LENGTH      = 32

    module Errors
      class Base < Exception
      end

      class Encoding < Base
      end

      class Decryption < Base
      end

      class Configuration < Base
      end

      class EncryptionError < Base
      end

      class ForbiddenClass < Base
      end

      class EncryptedContentIntegrity < Base
      end
    end

    # --- config (Config + Context defaults) ------------------------------

    @@primary_key : String?
    @@deterministic_key : String?
    @@key_derivation_salt : String?

    def self.configure(*, primary_key = nil, deterministic_key = nil,
                       key_derivation_salt = nil) : Nil
      @@primary_key = primary_key
      @@deterministic_key = deterministic_key
      @@key_derivation_salt = key_derivation_salt
    end

    def self.primary_key : String
      credential(:primary_key, @@primary_key,
        ENV["ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY"]? || ENV["AR_ENCRYPTION_PRIMARY_KEY"]?)
    end

    def self.deterministic_key : String
      credential(:deterministic_key, @@deterministic_key,
        ENV["ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY"]? || ENV["AR_ENCRYPTION_DETERMINISTIC_KEY"]?)
    end

    def self.key_derivation_salt : String
      credential(:key_derivation_salt, @@key_derivation_salt,
        ENV["ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT"]? || ENV["AR_ENCRYPTION_KEY_DERIVATION_SALT"]?)
    end

    private def self.credential(name : Symbol, configured : String?, env : String?) : String
      value = configured.presence || env.presence
      raise Errors::Configuration.new(
        "Missing Active Record encryption credential: active_record_encryption.#{name}") unless value
      value
    end

    # --- Properties / Message / serializer --------------------------------

    # Wrapper for a hash of encryption properties (message headers).
    # Insertion order is preserved — it IS the wire order. Short keys per
    # the gem's DEFAULT_PROPERTIES ("iv", "at", "c", ...).
    class Properties
      alias Value = Bytes | Int64 | Bool | Nil

      attr_reader data = {} of String => Value

      def []=(key : String, value : Value) : Nil
        if @data.has_key?(key)
          raise Errors::EncryptedContentIntegrity.new(
            "Properties can't be overridden: #{key}")
        end
        @data[key] = value
      end

      def [](key : String) : Value
        @data[key]
      end

      def []?(key : String) : Value?
        @data[key]?
      end

      def key?(key : String) : Bool
        @data.has_key?(key)
      end

      def each(& : {String, Value} ->) : Nil
        @data.each { |k, v| yield({k, v}) }
      end

      def iv : Bytes?
        self["iv"].as?(Bytes)
      end

      def iv=(value : Bytes) : Nil
        self["iv"] = value
      end

      def auth_tag : Bytes?
        self["at"].as?(Bytes)
      end

      def auth_tag=(value : Bytes) : Nil
        self["at"] = value
      end

      def compressed? : Bool
        self["c"]? == true
      end

      def compressed=(value : Bool) : Nil
        self["c"] = value
      end
    end

    # An encrypted payload + unencrypted headers.
    class Message
      attr_accessor payload : Bytes
      attr_accessor headers : Properties

      def initialize(payload : Bytes? = nil)
        @payload = payload || Bytes.new(0)
        @headers = Properties.new
      end
    end

    # Serializes Messages with JSON; payload and binary header values are
    # Base64-strict encoded (the gem's MessageSerializer).
    module MessageSerializer
      def self.dump(message : Message) : String
        String.build do |io|
          io << %({"p":") << Base64.strict_encode(message.payload) << %(","h":{)
          first = true
          message.headers.each do |k, v|
            io << "," unless first
            first = false
            case v
            when Bytes then io << '"' << k << %(":") << Base64.strict_encode(v) << '"'
            when Bool  then io << '"' << k << %(":) << v
            when Int64  then io << '"' << k << %(:) << v
            when Nil    then io << '"' << k << %(":null)
            end
          end
          io << "}}"
        end
      end

      def self.load(serialized : String) : Message
        hash = JSON.parse(serialized).as_h?
        raise Errors::Decryption.new("Invalid data format: hash without payload") \
          unless hash && hash.has_key?("p")
        message = Message.new(decode_if_needed(hash["p"]))
        if headers = hash["h"]?.try(&.as_h?)
          headers.each do |key, value|
            raw = value.raw
            message.headers[key] =
              raw.is_a?(String) ? decode_if_needed(value) : scalar(raw)
          end
        end
        message
      rescue ex : JSON::ParseException
        raise Errors::Encoding.new(ex.message)
      rescue ex : Base64::Error | ArgumentError
        raise Errors::Encoding.new(ex.message)
      end

      private def self.decode_if_needed(value : JSON::Any) : Bytes
        Base64.decode(value.as_s)
      rescue ex : Base64::Error | ArgumentError
        raise Errors::Encoding.new(ex.message)
      end

      private def self.scalar(raw) : Properties::Value
        case raw
        when Bool  then raw
        when Int64 then raw
        when Int32 then raw.to_i64
        else            nil
        end
      end
    end

    # --- keys --------------------------------------------------------------

    # A key is a container for a secret (+ public tags in the gem; the port
    # stores none — envelope encryption is out of scope).
    class Key
      attr_reader secret : Bytes

      def initialize(@secret : Bytes)
      end
    end

    # KeyGenerator: PBKDF2-HMAC-SHA1 (2**16) via ActiveSupport::KeyGenerator.
    module KeyGenerator
      def self.derive_key_from(password : String, length : Int32 = KEY_LENGTH) : Bytes
        ActiveSupport::KeyGenerator.new(password, iterations: 2**16, digest: :sha1)
          .generate_key(Encryption.key_derivation_salt, length)
      end
    end

    # A KeyProvider serving derivation keys (all passwords decrypt, the
    # first one encrypts).
    class DerivedSecretKeyProvider
      attr_reader keys : Array(Key)

      def initialize(passwords : Array(String))
        @keys = passwords.map { |p| Key.new(KeyGenerator.derive_key_from(p)) }
      end

      def initialize(password : String)
        @keys = [Key.new(KeyGenerator.derive_key_from(password))]
      end

      def encryption_key : Key
        @keys.first
      end

      def decryption_keys : Array(Key)
        @keys
      end
    end

    class DeterministicKeyProvider < DerivedSecretKeyProvider
    end

    # --- cipher --------------------------------------------------------------

    # Aes256Gcm via EVP (OpenSSL::Cipher in Crystal has no auth_tag/auth_data —
    # ctrl binding, same approach as active_support.cr MessageEncryptor).
    # Deterministic mode: iv = HMAC-SHA256(secret, clear_text)[0,12].
    module Aes256Gcm
      def self.encrypt(secret : Bytes, clear_text : Bytes,
                       deterministic : Bool) : Message
        cipher = new_ctx
        iv = deterministic ? deterministic_iv(secret, clear_text) : Random::Secure.random_bytes(IV_LENGTH)
        buf = Bytes.new(clear_text.size + 16)
        outl = 0
        begin
          ok = LibCrypto.evp_cipherinit_ex(cipher, evp_cipher, nil, secret, iv, 1)
          ok = LibCrypto.evp_cipherupdate(cipher, buf, pointerof(outl),
            clear_text, clear_text.size) if ok == 1
          finl = 0
          ok = LibCrypto.evp_cipherfinal_ex(cipher, buf + outl, pointerof(finl)) if ok == 1
          tag = Bytes.new(AUTH_TAG_LENGTH)
          ok = LibCrypto.evp_cipherctx_ctrl(cipher, LibCrypto::CTRL_GCM_GET_TAG,
            AUTH_TAG_LENGTH, tag) if ok == 1
          raise Errors::EncryptionError.new("encrypt failed") unless ok == 1
          message = Message.new(buf[0, outl + finl])
          message.headers.iv = iv
          message.headers.auth_tag = tag
          message
        ensure
          LibCrypto.evp_cipher_ctx_free(cipher)
        end
      end

      def self.decrypt(secret : Bytes, message : Message) : Bytes
        tag = message.headers.auth_tag
        unless tag && tag.size == AUTH_TAG_LENGTH
          raise Errors::EncryptedContentIntegrity.new
        end
        iv = message.headers.iv || Bytes.new(0)
        cipher = new_ctx
        buf = Bytes.new(message.payload.size + 16)
        outl = 0
        begin
          ok = LibCrypto.evp_cipherinit_ex(cipher, evp_cipher, nil, secret, iv, 0)
          ok = LibCrypto.evp_cipherctx_ctrl(cipher, LibCrypto::CTRL_GCM_SET_TAG,
            tag.size, tag.to_unsafe.as(Void*)) if ok == 1
          ok = LibCrypto.evp_cipherupdate(cipher, buf, pointerof(outl),
            message.payload, message.payload.size) if ok == 1
          finl = 0
          ok = LibCrypto.evp_cipherfinal_ex(cipher, buf + outl, pointerof(finl)) if ok == 1
          raise Errors::Decryption.new unless ok == 1
          buf[0, outl + finl]
        ensure
          LibCrypto.evp_cipher_ctx_free(cipher)
        end
      end

      private def self.deterministic_iv(secret : Bytes, clear_text : Bytes) : Bytes
        OpenSSL::HMAC.digest(:sha256, secret, clear_text)[0, IV_LENGTH]
      end

      private def self.evp_cipher
        evp = LibCrypto.evp_get_cipherbyname("aes-256-gcm")
        raise Errors::Configuration.new("aes-256-gcm unavailable") unless evp
        evp
      end

      private def self.new_ctx
        LibCrypto.evp_cipher_ctx_new
      end
    end

    # --- encryptor -------------------------------------------------------------

    # Zlib-обёртка: порог-компрессияEncryptor'а (уровень Ruby-дефолт =
    # DEFAULT_COMPRESSION → 6; вывод байтово совпадает, oracle-проверено
    # кейсом enc_det_long_exact).
    module ZlibHelper
      def self.deflate(data : Bytes) : Bytes
        sink = IO::Memory.new
        writer = Compress::Zlib::Writer.new(sink)
        writer.write(data)
        writer.close
        sink.to_slice
      end

      def self.inflate(data : Bytes) : Bytes
        Compress::Zlib::Reader.open(IO::Memory.new(data)) do |reader|
          sink = IO::Memory.new
          IO.copy(reader, sink)
          sink.to_slice
        end
      end
    end

    class Encryptor
      def encrypt(clear_text : String, key_provider : DerivedSecretKeyProvider,
                  deterministic : Bool = false) : String
        key = key_provider.encryption_key
        payload = clear_text.to_slice
        compressed = false
        if payload.size > THRESHOLD_TO_JUSTIFY_COMPRESSION
          payload = ZlibHelper.deflate(payload)
          compressed = true
        end
        message = Aes256Gcm.encrypt(key.secret, payload, deterministic)
        message.headers.compressed = true if compressed
        MessageSerializer.dump(message)
      end

      def decrypt(encrypted_text : String,
                  key_provider : DerivedSecretKeyProvider) : String
        message = MessageSerializer.load(encrypted_text)
        data : Bytes? = nil
        error : Exception? = nil
        key_provider.decryption_keys.each do |key|
          begin
            data = Aes256Gcm.decrypt(key.secret, message)
            break
          rescue ex : Errors::Base
            error = ex
          end
        end
        raise (error || Errors::Decryption.new) unless data
        data = ZlibHelper.inflate(data) if message.headers.compressed?
        String.new(data)
      rescue ex : Errors::Base
        raise Errors::Decryption.new
      end

      def encrypted?(text : String) : Bool
        MessageSerializer.load(text)
        true
      rescue Errors::Base
        false
      end
    end

    # --- scheme ------------------------------------------------------------------

    # A container of attribute encryption options (Scheme в gem).
    class Scheme
      property? deterministic : Bool
      property? downcase : Bool
      property? support_unencrypted_data : Bool
      attr_accessor key : String?

      def initialize(@deterministic = false, @downcase = false,
                     @support_unencrypted_data = false, @key = nil)
        if @downcase && !@deterministic
          raise Errors::Configuration.new(
            "ignore_case: can only be used with deterministic encryption")
        end
      end

      def key_provider : DerivedSecretKeyProvider
        if key = @key
          DerivedSecretKeyProvider.new(key)
        elsif @deterministic
          DeterministicKeyProvider.new(Encryption.deterministic_key)
        else
          DerivedSecretKeyProvider.new(Encryption.primary_key)
        end
      end

      # Encrypts a clear-text value for storage (nil-safe; downcase-aware).
      def serialize(value : String?) : String?
        return nil if value.nil?
        value = value.downcase if @downcase
        Encryptor.new.encrypt(value, key_provider, @deterministic)
      end

      # Decrypts a stored ciphertext (nil-safe; bare strings pass through
      # with support_unencrypted_data, else Decryption).
      def deserialize(value : String?) : String?
        return nil if value.nil?
        Encryptor.new.decrypt(value, key_provider)
      rescue ex : Errors::Decryption
        raise ex unless @support_unencrypted_data
        value
      end
    end

    # --- module-level helpers (the encrypts macro builds on these) ---------------

    def self.encryptor : Encryptor
      @@encryptor ||= Encryptor.new
    end

    def self.default_scheme(deterministic : Bool = false, downcase : Bool = false,
                            support_unencrypted_data : Bool = false,
                            key : String? = nil) : Scheme
      Scheme.new(deterministic, downcase, support_unencrypted_data, key)
    end
  end
end
