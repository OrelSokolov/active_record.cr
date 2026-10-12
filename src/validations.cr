# Validations: validates ... presence/length/numericality/format/uniqueness
# (+ scope), inclusion/exclusion/acceptance/confirmation/comparison, and
# the options allow_nil/allow_blank/on:/strict:/condition:/unless_condition:
# + custom `validate` blocks/methods. Messages are 1:1 with Rails
# (verified against oracle/expected.yml, activerecord 8.1.4).
#
# Deviation: `if:`/`unless:` are Ruby keywords in kwargs position in
# Crystal — use `condition:`/`unless_condition:` with a method-name Symbol.

module ActiveRecord
  class Base
    def valid?(context : Symbol? = nil) : Bool
      ctx = context || (new_record? ? :create : :update)
      errors.clear
      return false unless __run_before_validation
      __run_validations(ctx)
      if strict_error = @errors.find(&.strict?)
        raise StrictValidationFailed.new(
          "#{errors.human_attribute(strict_error.attribute)} #{strict_error.message}")
      end
      errors.empty?
    end

    def invalid?(context : Symbol? = nil) : Bool
      !valid?(context)
    end

    def __run_validations(context : Symbol) : Nil
    end

    # `on:` filter: Symbol or Array(Symbol) splat from the macro.
    def __validation_on?(context : Symbol, on : Symbol | Array(Symbol)) : Bool
      on.is_a?(Array) ? on.includes?(context) : on == context
    end

    # --- DSL -------------------------------------------------------------
    # validates :title, presence: true, length: {maximum: 10}
    # validates :views, numericality: {greater_than_or_equal_to: 0, ...}, allow_nil: true
    # validates :email, format: {with: /.../}, uniqueness: {scope: :account_id}
    # validates :name, inclusion: {in: [...]}, exclusion: {in: [...]}
    # validates :terms, acceptance: true
    # validates :email, confirmation: true
    # validates :age, comparison: {greater_than_or_equal_to: 18}
    #   ... on: :update, strict: true, condition: :method, unless_condition: :method
    macro validates(*columns, presence = nil, length = nil, numericality = nil,
                    format = nil, uniqueness = nil, inclusion = nil,
                    exclusion = nil, acceptance = nil, confirmation = nil,
                    comparison = nil, on = nil, strict = false,
                    allow_nil = false, allow_blank = false,
                    condition = nil, unless_condition = nil)
      {% for col in columns %}
        {% n = @type.methods.select { |m| m.name.starts_with?("validation__") }.size %}
        {% cname = col.id %}
        {% if confirmation %}
          @{{cname}}_confirmation : String? = nil

          def {{cname}}_confirmation : String?
            @{{cname}}_confirmation
          end

          def {{cname}}_confirmation=(value : String?)
            @{{cname}}_confirmation = value
          end
        {% end %}

        def validation__{{cname}}__{{n}}(context : Symbol) : Nil
          {% if on %}
            return unless __validation_on?(context, {{on}})
          {% end %}
          {% if condition %}
            return unless {{condition.id}}
          {% end %}
          {% if unless_condition %}
            return if {{unless_condition.id}}
          {% end %}
          value = attributes[{{col.id.stringify}}]?
          {% if allow_nil %}
            return if value.nil?
          {% end %}
          {% if allow_blank %}
            return if value.nil? || (value.is_a?(String) && value.strip.empty?)
          {% end %}

          {% if presence %}
            if value.nil? || (value.is_a?(String) && value.strip.empty?)
              errors.add({{col.id.stringify}}, "can't be blank", :blank, strict: {{strict}})
            end
          {% end %}

          {% if length %}
            {% max = length[:maximum] %}
            {% min = length[:minimum] %}
            {% if max %}
              if value.is_a?(String) && value.size > {{max}}
                errors.add({{col.id.stringify}}, "is too long (maximum is {{max}} characters)", :too_long, strict: {{strict}})
              end
            {% end %}
            {% if min %}
              if value.is_a?(String) && value.size < {{min}}
                errors.add({{col.id.stringify}}, "is too short (minimum is {{min}} characters)", :too_short, strict: {{strict}})
              end
            {% end %}
          {% end %}

          {% if numericality %}
            {% gt = numericality[:greater_than] %}
            {% gte = numericality[:greater_than_or_equal_to] %}
            {% lt = numericality[:less_than] %}
            {% lte = numericality[:less_than_or_equal_to] %}
            case value
            when Int64, Int32, Float64
              {% if gt %}
                errors.add({{col.id.stringify}}, "must be greater than {{gt}}", :greater_than, strict: {{strict}}) if value.to_f <= {{gt}}.to_f
              {% end %}
              {% if gte %}
                errors.add({{col.id.stringify}}, "must be greater than or equal to {{gte}}", :greater_than_or_equal_to, strict: {{strict}}) if value.to_f < {{gte}}.to_f
              {% end %}
              {% if lt %}
                errors.add({{col.id.stringify}}, "must be less than {{lt}}", :less_than, strict: {{strict}}) if value.to_f >= {{lt}}.to_f
              {% end %}
              {% if lte %}
                errors.add({{col.id.stringify}}, "must be less than or equal to {{lte}}", :less_than_or_equal_to, strict: {{strict}}) if value.to_f > {{lte}}.to_f
              {% end %}
            else
              errors.add({{col.id.stringify}}, "is not a number", :not_a_number, strict: {{strict}})
            end
          {% end %}

          {% if comparison %}
            {% cgt = comparison[:greater_than] %}
            {% cgte = comparison[:greater_than_or_equal_to] %}
            {% clt = comparison[:less_than] %}
            {% clte = comparison[:less_than_or_equal_to] %}
            {% ceq = comparison[:equal_to] %}
            {% cne = comparison[:other_than] %}
            case value
            when Int64, Int32, Float64
              {% if cgt %}
                errors.add({{col.id.stringify}}, "must be greater than {{cgt}}", :greater_than, strict: {{strict}}) if value.to_f <= {{cgt}}.to_f
              {% end %}
              {% if cgte %}
                errors.add({{col.id.stringify}}, "must be greater than or equal to {{cgte}}", :greater_than_or_equal_to, strict: {{strict}}) if value.to_f < {{cgte}}.to_f
              {% end %}
              {% if clt %}
                errors.add({{col.id.stringify}}, "must be less than {{clt}}", :less_than, strict: {{strict}}) if value.to_f >= {{clt}}.to_f
              {% end %}
              {% if clte %}
                errors.add({{col.id.stringify}}, "must be less than or equal to {{clte}}", :less_than_or_equal_to, strict: {{strict}}) if value.to_f > {{clte}}.to_f
              {% end %}
              {% if ceq %}
                errors.add({{col.id.stringify}}, "must be equal to {{ceq}}", :equal_to, strict: {{strict}}) if value.to_f != {{ceq}}.to_f
              {% end %}
              {% if cne %}
                errors.add({{col.id.stringify}}, "must be other than {{cne}}", :other_than, strict: {{strict}}) if value.to_f == {{cne}}.to_f
              {% end %}
            end
          {% end %}

          {% if format %}
            {% pattern = format[:with] %}
            unless value.is_a?(String) && value.match({{pattern}})
              errors.add({{col.id.stringify}}, "is invalid", :invalid, strict: {{strict}})
            end
          {% end %}

          {% if inclusion %}
            {% in_list = inclusion[:in] %}
            unless value.nil? || {{in_list}}.map(&.to_s).includes?(value.to_s)
              errors.add({{col.id.stringify}}, "is not included in the list", :inclusion, strict: {{strict}}, detail_value: value)
            end
          {% end %}

          {% if exclusion %}
            {% ex_list = exclusion[:in] %}
            unless value.nil? || !{{ex_list}}.map(&.to_s).includes?(value.to_s)
              errors.add({{col.id.stringify}}, "is reserved", :exclusion, strict: {{strict}}, detail_value: value)
            end
          {% end %}

          {% if acceptance %}
            # Rails 8: acceptance skips nil values (only present-but-not
            # accepted fails).
            unless value.nil? || value == true || value == "1"
              errors.add({{col.id.stringify}}, "must be accepted", :accepted, strict: {{strict}})
            end
          {% end %}

          {% if confirmation %}
            if (conf = {{cname}}_confirmation) && conf != value
              errors.add({{col.id.stringify}} + "_confirmation", "doesn't match {{col.id.stringify.capitalize.id}}", :confirmation, strict: {{strict}})
            end
          {% end %}

          {% if uniqueness %}
            # `{scope: :x}` parses as a NamedTupleLiteral (or HashLiteral
            # when written with `=>`) — accept both.
            {% scope = nil %}
            {% if uniqueness.is_a?(NamedTupleLiteral) || uniqueness.is_a?(HashLiteral) %}
              {% scope = uniqueness[:scope] %}
            {% end %}
            unless value.nil?
              {% if scope %}
                taken = self.class
                  .where({{col.id.stringify}} + " = ?", value)
                  .where(%({{scope.id}} = ?), attributes[{{scope.id.stringify}}]?)
                  .exists?
              {% else %}
                taken = self.class.where({{col.id.stringify}} + " = ?", value).exists?
              {% end %}
              if taken && !(persisted? && __original_attributes[{{col.id.stringify}}]? == value)
                errors.add({{col.id.stringify}}, "has already been taken", :taken, strict: {{strict}})
              end
            end
          {% end %}
          nil
        end
      {% end %}
    end

    # Custom validations: `validate :check_name` or `validate do ... end`.
    macro validate(method_name = nil, &block)
      {% n = @type.methods.select { |m| m.name.starts_with?("validation__") }.size %}
      {% if method_name %}
        def validation__custom__{{n}}(context : Symbol) : Nil
          {{method_name.id}}
          nil
        end
      {% else %}
        def validation__custom__{{n}}(context : Symbol) : Nil
          {{block.body}}
          nil
        end
      {% end %}
    end

    # %(...) placeholder rendering for error messages with %{count} etc.
    def self.__render_message(template : String, **vars) : String
      result = template
      vars.each { |k, v| result = result.gsub("%{#{k}}", v.to_s) }
      result
    end
  end
end
