# ActionController::Parameters → ActiveRecord attribute assignment (Rails'
# record.update!(params): controllers pass their permitted strong-params
# filter straight to update!/update/assign_attributes).
#
# Not required by active_record_cr.cr — this file references
# ActionController::Parameters from action_pack_cr, so programs using both
# shards opt in explicitly:
#
#   require "railties_cr"        # pulls in action_pack_cr
#   require "active_record_cr"
#   require "active_record_cr/parameters"

module ActiveRecord
  extend self

  # Parameters → attribute hash. `to_h` is the permit checkpoint: unpermitted
  # parameters raise UnfilteredParameters (Rails raises
  # ActiveModel::ForbiddenAttributesError at the same point).
  #
  # Nested hashes/arrays (e.g. permit(settings: {})) convert to JSON::Any —
  # the in-memory type of json/jsonb columns; scalars pass through (Int32
  # widens to Int64, as in ActiveRecord::Value).
  def parameters_to_attributes(params : ActionController::Parameters) : Hash(String, ActiveRecord::Value)
    attributes = {} of String => ActiveRecord::Value
    params.to_h.each do |name, value|
      attributes[name] = param_to_attribute(value)
    end
    attributes
  end

  private def param_to_attribute(value : ActionController::Parameters::Value) : ActiveRecord::Value
    case value
    when ActionController::Parameters then JSON::Any.new(parameters_to_json(value))
    when Array                        then JSON::Any.new(value.map { |e| scalar_to_json(e) })
    when Int32                        then value.to_i64
    when Nil, Bool, Int64, Float64, String then value
    when ActionController::UploadedFile
      raise ArgumentError.new("can't assign an uploaded file through parameters " \
                               "(files attach via has_*_attached setters)")
    else
      raise ArgumentError.new("can't assign #{value.class} from parameters")
    end
  end

  private def parameters_to_json(params : ActionController::Parameters) : Hash(String, JSON::Any)
    json = {} of String => JSON::Any
    # Nested hashes were allowed by an explicit `key => {}` filter, so the
    # permit checkpoint already passed; read them unsafely (nested Parameters
    # never carry the permitted flag).
    params.to_unsafe_h.each do |key, value|
      json[key] = case value
                  when ActionController::Parameters then JSON::Any.new(parameters_to_json(value))
                  when Array                        then JSON::Any.new(value.map { |e| scalar_to_json(e) })
                  when ActionController::UploadedFile
                    raise ArgumentError.new("can't assign an uploaded file through parameters " \
                                             "(files attach via has_*_attached setters)")
                  else                                   scalar_to_json(value)
                  end
    end
    json
  end

  private def scalar_to_json(value : ActionController::Parameters::Scalar) : JSON::Any
    case value
    when Int32 then JSON::Any.new(value.to_i64)
    else            JSON::Any.new(value)
    end
  end
end

class ActiveRecord::Base
  # update!/update/assign_attributes accept ActionController::Parameters
  # (a controller's permitted strong-params filter), 1:1 with Rails.
  def update(values : ActionController::Parameters) : Bool
    assign_attributes(values)
    save
  end

  def update!(values : ActionController::Parameters) : Bool
    assign_attributes(values)
    save || raise RecordInvalid.new(self)
  end

  def assign_attributes(values : ActionController::Parameters) : Nil
    assign_attributes(ActiveRecord.parameters_to_attributes(values))
  end
end
