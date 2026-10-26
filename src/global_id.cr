# globalid-lite (Rails globalid gem): GlobalID.create(record) /
# GlobalID::Locator.locate(gid_param) build and resolve record gids —
# urlsafe-b64 of "gid://<app>/<Class>/<id>" (the same shape turbo_cr and
# serialize_broadcasting in action_cable_cr consume).
#
# Deviations from the gem:
#   * `GlobalID.create` returns a `Reference` struct, not a GlobalID
#     instance (module GlobalID already occupies the name); it carries
#     to_s/to_param, the only surface the reference app uses.
#   * `gid_model_name` is a port seam: the gem composes the gid from
#     `model.class.name`, here records of an STI table are loaded as the
#     base class, so models override the hook with the record's
#     type-column class (Room → "Rooms::Open").
#   * locate(..., only:) loads through the `only:` class when the gid names
#     an STI descendant of it: the port stores STI type columns in two
#     spellings ("Rooms::Open" from seeds, "Open" from the port), so a
#     subclass-scoped query would miss rows of the other spelling.

require "base64"

module GlobalID
  # App segment of gid:// URIs (gem: set once by the railtie; here —
  # ENV CRAILS_APP_NAME, default "app"; the app assigns it in config).
  class_property app : String { ENV["CRAILS_APP_NAME"]? || "app" }

  # A gid: app + model name + id. Parsed gids keep the app segment of
  # the URI, so to_s round-trips.
  struct Reference
    getter app : String
    getter model_name : String
    getter model_id : Int64

    def initialize(@model_name : String, @model_id : Int64, app : String? = nil)
      @app = app || GlobalID.app
    end

    def self.parse?(gid_param : String) : self?
      padded = gid_param.tr("-_", "+/")
      padded = padded + "=" * ((4 - padded.size % 4) % 4)
      decoded = begin
        Base64.decode_string(padded)
      rescue
        return nil
      end
      return nil unless match = decoded.match(/\Agid:\/\/([\w-]+)\/([\w:]+)\/(\d+)\z/)
      new(match[2], match[3].to_i64, app: match[1])
    end

    def to_s : String
      "gid://#{@app}/#{@model_name}/#{@model_id}"
    end

    def to_param : String
      Base64.urlsafe_encode(to_s, padding: false)
    end
  end

  # GlobalID.create(record) → Reference("gid://<app>/<Class>/<id>"); the
  # record's id must be present (unsaved records raise, as in the gem).
  def self.create(record : ActiveRecord::Base, app : String? = nil) : Reference
    Reference.new(record.gid_model_name, record.id.not_nil!, app)
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

# globalid-railtie surface: GlobalID::Identification included into
# ActiveRecord::Base — to_gid / to_gid_param built through GlobalID.create.
class ActiveRecord::Base
  def gid_model_name : String
    self.class.name
  end

  def to_gid : GlobalID::Reference
    GlobalID.create(self)
  end

  def to_gid_param : String
    to_gid.to_param
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
