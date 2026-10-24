# globalid-lite (Rails globalid gem): GlobalID::Locator.locate(gid_param)
# resolves a record from its gid param — urlsafe-b64 of
# "gid://<app>/<Class>/<id>" (the same shape to_gid_param in turbo_cr and
# serialize_broadcasting in action_cable_cr produce).
#
# Deviations from the gem:
#   * URI-composition helpers (GlobalID.new / to_s / find) are not ported —
#     only the locate surface the reference app uses.
#   * locate(..., only:) loads through the `only:` class when the gid names
#     an STI descendant of it: the port stores STI type columns in two
#     spellings ("Rooms::Open" from seeds, "Open" from the port), so a
#     subclass-scoped query would miss rows of the other spelling.

require "base64"

module GlobalID
  def self.app : String
    ENV["CRAILS_APP_NAME"]? || "app"
  end

  # Parsed gid: model name + id, the app segment is not restricted (the gem
  # parses any gid; app mismatch only matters for SignedGlobalID).
  struct Reference
    getter model_name : String
    getter model_id : Int64

    def initialize(@model_name : String, @model_id : Int64)
    end

    def self.parse?(gid_param : String) : self?
      padded = gid_param.tr("-_", "+/")
      padded = padded + "=" * ((4 - padded.size % 4) % 4)
      decoded = begin
        Base64.decode_string(padded)
      rescue
        return nil
      end
      return nil unless match = decoded.match(/\Agid:\/\/[\w-]+\/([\w:]+)\/(\d+)\z/)
      new(match[1], match[2].to_i64)
    end
  end

  module Locator
    # locate("Z2lk...") → record of whatever class the gid names, or nil.
    def self.locate(gid_param : String) : ActiveRecord::Base?
      ref = Reference.parse?(gid_param)
      return nil unless ref
      if (klass = resolve_model(ref.model_name))
        klass.find?(ref.model_id)
      end
    end

    # locate("Z2lk...", only: Room) → the record if it is a Room (or an STI
    # descendant of Room), else nil — the gem's `only:` restriction.
    def self.locate(gid_param : String, only : T.class) : T? forall T
      ref = Reference.parse?(gid_param)
      return nil unless ref
      klass = resolve_model(ref.model_name)
      return nil unless klass
      return nil unless klass <= T || klass.table_name == T.table_name
      T.find?(ref.model_id)
    end

    # Model class by name — full ("Rooms::Open") or short STI spelling
    # ("Open"); ambiguous short names resolve to the first registered.
    def self.resolve_model(model_name : String) : ActiveRecord::Base.class | Nil
      case model_name
      when "ActiveRecord::Base", "ApplicationRecord" then nil
      else
        __lookup_model(model_name)
      end
    end

    # Overwritten by the end-of-program codegen below (the model registry
    # is only complete once every class is parsed).
    def self.__lookup_model(model_name : String) : ActiveRecord::Base.class | Nil
      nil
    end
  end
end

# End-of-program codegen: name → class table over the registered models.
macro finished
  module GlobalID
    module Locator
      def self.__lookup_model(model_name : String) : ActiveRecord::Base.class | Nil
        case model_name
        {% for m in ::ActiveRecord::MODELS %}
          {% unless m.abstract? %}
            {% short = m.name.stringify.split("::").last %}
            when {{ m.name.stringify }} then {{ m.id }}
            {% if short != m.name.stringify %}
              when {{ short }} then {{ m.id }}
            {% end %}
          {% end %}
        {% end %}
        else
          nil
        end
      end
    end
  end
end
