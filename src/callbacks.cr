# Callbacks: before_validation / before_save / before_destroy /
# after_create / after_update / after_save / after_destroy /
# after_commit / after_rollback / after_*_commit sugar, all with
# if:/unless: conditions (Symbol/String method name or -> {} lambda).
#
# Each declaration generates a hidden prefixed method; the `macro finished`
# in base.cr assembles them into `__run_<hook>` runners. A before-hook
# aborts the chain by returning false (the Rails `throw(:abort)`
# equivalent — symbols cannot be thrown in Crystal). A failing if:/unless:
# condition skips the callback without aborting the chain.

module ActiveRecord
  class Base
    # Runner defaults (overridden per model by the finished codegen).
    def __run_before_validation : Bool
      true
    end

    def __run_before_save : Bool
      true
    end

    def __run_before_create : Bool
      true
    end

    def __run_before_update : Bool
      true
    end

    def __run_before_destroy : Nil
    end

    def __run_after_create : Nil
    end

    def __run_after_update : Nil
    end

    def __run_after_save : Nil
    end

    def __run_after_destroy : Nil
    end

    def __run_dependents : Nil
    end

    def __run_after_commit(event : Symbol) : Nil
    end

    def __run_after_rollback(event : Symbol) : Nil
    end

    def __run_after_initialize : Nil
    end

    def __run_after_find : Nil
    end

    def __run_after_touch : Nil
    end

    # Around-callback chain walkers: default passes straight through; the
    # per-model codegen in base.cr overrides with a depth-dispatch case.
    def __wrap_around_save(depth : Int32, action : Proc(Nil)) : Nil
      action.call
    end

    def __wrap_around_create(depth : Int32, action : Proc(Nil)) : Nil
      action.call
    end

    def __wrap_around_update(depth : Int32, action : Proc(Nil)) : Nil
      action.call
    end

    def __wrap_around_destroy(depth : Int32, action : Proc(Nil)) : Nil
      action.call
    end

    # --- condition guards ---------------------------------------------------
    # Emit `return RET unless/skip-if COND`. The condition is a method name
    # (Symbol/String) or a -> {} lambda. Called from inside the emitted
    # callback methods; a false condition skips the callback only.

    macro __cb_skip_if(cond, ret)
      {% if cond %}
        {% if cond.is_a?(ProcLiteral) %}
          return {{ret.id}} if {{cond}}.call
        {% else %}
          return {{ret.id}} if {{cond.id}}
        {% end %}
      {% end %}
    end

    macro __cb_skip_unless(cond, ret)
      {% if cond %}
        {% if cond.is_a?(ProcLiteral) %}
          return {{ret.id}} unless {{cond}}.call
        {% else %}
          return {{ret.id}} unless {{cond.id}}
        {% end %}
      {% end %}
    end

    # --- DSL (flat definitions: a macro cannot be emitted by a macro) -------

    macro before_validation(method_name = nil, **opts, &block)
      {% n = @type.methods.select { |m| m.name.stringify.starts_with?("before_validation__cb_") }.size %}
      {% cond = opts["if"] %}
      {% not_cond = opts["unless"] %}
      def before_validation__cb_{{n.id}} : Bool
        __cb_skip_unless({{cond}}, true)
        __cb_skip_if({{not_cond}}, true)
        {% if method_name && method_name.is_a?(ProcLiteral) %}
          {{method_name}}.call
        {% elsif method_name %}
          {{method_name.id}}
        {% else %}
          ({{block.body}}) == false ? false : true
        {% end %}
        true
      end
    end

    macro before_save(method_name = nil, **opts, &block)
      {% n = @type.methods.select { |m| m.name.stringify.starts_with?("before_save__cb_") }.size %}
      {% cond = opts["if"] %}
      {% not_cond = opts["unless"] %}
      def before_save__cb_{{n.id}} : Bool
        __cb_skip_unless({{cond}}, true)
        __cb_skip_if({{not_cond}}, true)
        {% if method_name && method_name.is_a?(ProcLiteral) %}
          {{method_name}}.call
        {% elsif method_name %}
          {{method_name.id}}
        {% else %}
          ({{block.body}}) == false ? false : true
        {% end %}
        true
      end
    end

    macro before_create(method_name = nil, **opts, &block)
      {% n = @type.methods.select { |m| m.name.stringify.starts_with?("before_create__cb_") }.size %}
      {% cond = opts["if"] %}
      {% not_cond = opts["unless"] %}
      def before_create__cb_{{n.id}} : Bool
        __cb_skip_unless({{cond}}, true)
        __cb_skip_if({{not_cond}}, true)
        {% if method_name && method_name.is_a?(ProcLiteral) %}
          {{method_name}}.call
        {% elsif method_name %}
          {{method_name.id}}
        {% else %}
          ({{block.body}}) == false ? false : true
        {% end %}
        true
      end
    end

    macro before_update(method_name = nil, **opts, &block)
      {% n = @type.methods.select { |m| m.name.stringify.starts_with?("before_update__cb_") }.size %}
      {% cond = opts["if"] %}
      {% not_cond = opts["unless"] %}
      def before_update__cb_{{n.id}} : Bool
        __cb_skip_unless({{cond}}, true)
        __cb_skip_if({{not_cond}}, true)
        {% if method_name && method_name.is_a?(ProcLiteral) %}
          {{method_name}}.call
        {% elsif method_name %}
          {{method_name.id}}
        {% else %}
          ({{block.body}}) == false ? false : true
        {% end %}
        true
      end
    end

    macro before_destroy(method_name = nil, **opts, &block)
      {% n = @type.methods.select { |m| m.name.stringify.starts_with?("before_destroy__cb_") }.size %}
      {% cond = opts["if"] %}
      {% not_cond = opts["unless"] %}
      def before_destroy__cb_{{n.id}} : Nil
        __cb_skip_unless({{cond}}, "nil")
        __cb_skip_if({{not_cond}}, "nil")
        {% if method_name && method_name.is_a?(ProcLiteral) %}
          {{method_name}}.call
        {% elsif method_name %}
          {{method_name.id}}
        {% else %}
          {{block.body}}
        {% end %}
        nil
      end
    end

    macro after_create(method_name = nil, **opts, &block)
      {% n = @type.methods.select { |m| m.name.stringify.starts_with?("after_create__cb_") }.size %}
      {% cond = opts["if"] %}
      {% not_cond = opts["unless"] %}
      def after_create__cb_{{n.id}} : Nil
        __cb_skip_unless({{cond}}, "nil")
        __cb_skip_if({{not_cond}}, "nil")
        {% if method_name && method_name.is_a?(ProcLiteral) %}
          {{method_name}}.call
        {% elsif method_name %}
          {{method_name.id}}
        {% else %}
          {{block.body}}
        {% end %}
        nil
      end
    end

    macro after_update(method_name = nil, **opts, &block)
      {% n = @type.methods.select { |m| m.name.stringify.starts_with?("after_update__cb_") }.size %}
      {% cond = opts["if"] %}
      {% not_cond = opts["unless"] %}
      def after_update__cb_{{n.id}} : Nil
        __cb_skip_unless({{cond}}, "nil")
        __cb_skip_if({{not_cond}}, "nil")
        {% if method_name && method_name.is_a?(ProcLiteral) %}
          {{method_name}}.call
        {% elsif method_name %}
          {{method_name.id}}
        {% else %}
          {{block.body}}
        {% end %}
        nil
      end
    end

    macro after_save(method_name = nil, **opts, &block)
      {% n = @type.methods.select { |m| m.name.stringify.starts_with?("after_save__cb_") }.size %}
      {% cond = opts["if"] %}
      {% not_cond = opts["unless"] %}
      def after_save__cb_{{n.id}} : Nil
        __cb_skip_unless({{cond}}, "nil")
        __cb_skip_if({{not_cond}}, "nil")
        {% if method_name && method_name.is_a?(ProcLiteral) %}
          {{method_name}}.call
        {% elsif method_name %}
          {{method_name.id}}
        {% else %}
          {{block.body}}
        {% end %}
        nil
      end
    end

    macro after_destroy(method_name = nil, **opts, &block)
      {% n = @type.methods.select { |m| m.name.stringify.starts_with?("after_destroy__cb_") }.size %}
      {% cond = opts["if"] %}
      {% not_cond = opts["unless"] %}
      def after_destroy__cb_{{n.id}} : Nil
        __cb_skip_unless({{cond}}, "nil")
        __cb_skip_if({{not_cond}}, "nil")
        {% if method_name && method_name.is_a?(ProcLiteral) %}
          {{method_name}}.call
        {% elsif method_name %}
          {{method_name.id}}
        {% else %}
          {{block.body}}
        {% end %}
        nil
      end
    end

    # dependent: :destroy hooks for associations (associations.cr).
    macro __dependent_destroy(call)
      {% n = @type.methods.select { |m| m.name.stringify.starts_with?("dependent__cb_") }.size %}
      def dependent__cb_{{n.id}} : Nil
        {{ call }}
        nil
      end
    end

    # --- transaction callbacks (transactions.cr) -------------------------
    # Fires on the real COMMIT / any ROLLBACK (incl. savepoints). Without
    # an open transaction it fires per-op (implicit auto-commit tx).
    # `on:` filters by event: :create / :update / :destroy (Symbol or Array).

    macro after_commit(on = nil, method_name = nil, **opts, &block)
      {% n = @type.methods.select { |m| m.name.stringify.starts_with?("after_commit__cb_") }.size %}
      {% cond = opts["if"] %}
      {% not_cond = opts["unless"] %}
      {% if method_name %}
        def after_commit__cb_{{n.id}}(event : Symbol) : Nil
          {% if on %}return unless __tx_event_match?(event, {{on}}){% end %}
          __cb_skip_unless({{cond}}, "nil")
          __cb_skip_if({{not_cond}}, "nil")
          {{method_name.id}}
          nil
        end
      {% else %}
        def after_commit__cb_{{n.id}}(event : Symbol) : Nil
          {% if on %}return unless __tx_event_match?(event, {{on}}){% end %}
          __cb_skip_unless({{cond}}, "nil")
          __cb_skip_if({{not_cond}}, "nil")
          {{block.body}}
          nil
        end
      {% end %}
    end

    macro after_rollback(on = nil, method_name = nil, **opts, &block)
      {% n = @type.methods.select { |m| m.name.stringify.starts_with?("after_rollback__cb_") }.size %}
      {% cond = opts["if"] %}
      {% not_cond = opts["unless"] %}
      {% if method_name %}
        def after_rollback__cb_{{n.id}}(event : Symbol) : Nil
          {% if on %}return unless __tx_event_match?(event, {{on}}){% end %}
          __cb_skip_unless({{cond}}, "nil")
          __cb_skip_if({{not_cond}}, "nil")
          {{method_name.id}}
          nil
        end
      {% else %}
        def after_rollback__cb_{{n.id}}(event : Symbol) : Nil
          {% if on %}return unless __tx_event_match?(event, {{on}}){% end %}
          __cb_skip_unless({{cond}}, "nil")
          __cb_skip_if({{not_cond}}, "nil")
          {{block.body}}
          nil
        end
      {% end %}
    end

    # Rails sugar: after_create_commit / after_update_commit /
    # after_destroy_commit / after_save_commit (method, -> {} lambda or
    # block, all with if:/unless:) — after_commit filtered by event.
    # after_save_commit fires on both :create and :update.

    macro after_create_commit(method_name = nil, **opts, &block)
      {% n = @type.methods.select { |m| m.name.stringify.starts_with?("after_commit__cb_") }.size %}
      {% cond = opts["if"] %}
      {% not_cond = opts["unless"] %}
      def after_commit__cb_{{n.id}}(event : Symbol) : Nil
        return unless event == :create
        __cb_skip_unless({{cond}}, "nil")
        __cb_skip_if({{not_cond}}, "nil")
        {% if method_name && method_name.is_a?(ProcLiteral) %}
          {{method_name}}.call
        {% elsif method_name %}
          {{method_name.id}}
        {% else %}
          {{block.body}}
        {% end %}
        nil
      end
    end

    macro after_update_commit(method_name = nil, **opts, &block)
      {% n = @type.methods.select { |m| m.name.stringify.starts_with?("after_commit__cb_") }.size %}
      {% cond = opts["if"] %}
      {% not_cond = opts["unless"] %}
      def after_commit__cb_{{n.id}}(event : Symbol) : Nil
        return unless event == :update
        __cb_skip_unless({{cond}}, "nil")
        __cb_skip_if({{not_cond}}, "nil")
        {% if method_name && method_name.is_a?(ProcLiteral) %}
          {{method_name}}.call
        {% elsif method_name %}
          {{method_name.id}}
        {% else %}
          {{block.body}}
        {% end %}
        nil
      end
    end

    macro after_destroy_commit(method_name = nil, **opts, &block)
      {% n = @type.methods.select { |m| m.name.stringify.starts_with?("after_commit__cb_") }.size %}
      {% cond = opts["if"] %}
      {% not_cond = opts["unless"] %}
      def after_commit__cb_{{n.id}}(event : Symbol) : Nil
        return unless event == :destroy
        __cb_skip_unless({{cond}}, "nil")
        __cb_skip_if({{not_cond}}, "nil")
        {% if method_name && method_name.is_a?(ProcLiteral) %}
          {{method_name}}.call
        {% elsif method_name %}
          {{method_name.id}}
        {% else %}
          {{block.body}}
        {% end %}
        nil
      end
    end

    macro after_save_commit(method_name = nil, **opts, &block)
      {% n = @type.methods.select { |m| m.name.stringify.starts_with?("after_commit__cb_") }.size %}
      {% cond = opts["if"] %}
      {% not_cond = opts["unless"] %}
      def after_commit__cb_{{n.id}}(event : Symbol) : Nil
        return unless event == :create || event == :update
        __cb_skip_unless({{cond}}, "nil")
        __cb_skip_if({{not_cond}}, "nil")
        {% if method_name && method_name.is_a?(ProcLiteral) %}
          {{method_name}}.call
        {% elsif method_name %}
          {{method_name.id}}
        {% else %}
          {{block.body}}
        {% end %}
        nil
      end
    end

    # --- around callbacks (§4) --------------------------------------------
    # around_save { log1; yield; log2 } — block form (the spliced `yield`
    # forwards to the continuation), or method form: `around_save :m` where
    # `def m; ...; yield; ...; end`.
    # Order (oracle-verified on 8.1.4): around_save wraps before_save;
    # around_create/update exit BEFORE after_create/update; around_destroy
    # wraps before_destroy and exits before after_destroy.

    macro around_save(method_name = nil, **opts, &block)
      {% n = @type.methods.select { |m| m.name.stringify.starts_with?("around_save__cb_") }.size %}
      {% if method_name %}
        def around_save__cb_{{n.id}}(&inner : ->) : Nil
          {{method_name.id}}(&inner)
        end
      {% else %}
        def around_save__cb_{{n.id}} : Nil
          {{block.body}}
          nil
        end
      {% end %}
    end

    macro around_create(method_name = nil, **opts, &block)
      {% n = @type.methods.select { |m| m.name.stringify.starts_with?("around_create__cb_") }.size %}
      {% if method_name %}
        def around_create__cb_{{n.id}}(&inner : ->) : Nil
          {{method_name.id}}(&inner)
        end
      {% else %}
        def around_create__cb_{{n.id}} : Nil
          {{block.body}}
          nil
        end
      {% end %}
    end

    macro around_update(method_name = nil, **opts, &block)
      {% n = @type.methods.select { |m| m.name.stringify.starts_with?("around_update__cb_") }.size %}
      {% if method_name %}
        def around_update__cb_{{n.id}}(&inner : ->) : Nil
          {{method_name.id}}(&inner)
        end
      {% else %}
        def around_update__cb_{{n.id}} : Nil
          {{block.body}}
          nil
        end
      {% end %}
    end

    macro around_destroy(method_name = nil, **opts, &block)
      {% n = @type.methods.select { |m| m.name.stringify.starts_with?("around_destroy__cb_") }.size %}
      {% if method_name %}
        def around_destroy__cb_{{n.id}}(&inner : ->) : Nil
          {{method_name.id}}(&inner)
        end
      {% else %}
        def around_destroy__cb_{{n.id}} : Nil
          {{block.body}}
          nil
        end
      {% end %}
    end

    # --- lifecycle observers (§4) -------------------------------------------

    macro after_initialize(method_name = nil, **opts, &block)
      {% n = @type.methods.select { |m| m.name.stringify.starts_with?("after_initialize__cb_") }.size %}
      {% cond = opts["if"] %}
      {% not_cond = opts["unless"] %}
      def after_initialize__cb_{{n.id}} : Nil
        __cb_skip_unless({{cond}}, "nil")
        __cb_skip_if({{not_cond}}, "nil")
        {% if method_name && method_name.is_a?(ProcLiteral) %}
          {{method_name}}.call
        {% elsif method_name %}
          {{method_name.id}}
        {% else %}
          {{block.body}}
        {% end %}
        nil
      end
    end

    macro after_find(method_name = nil, **opts, &block)
      {% n = @type.methods.select { |m| m.name.stringify.starts_with?("after_find__cb_") }.size %}
      {% cond = opts["if"] %}
      {% not_cond = opts["unless"] %}
      def after_find__cb_{{n.id}} : Nil
        __cb_skip_unless({{cond}}, "nil")
        __cb_skip_if({{not_cond}}, "nil")
        {% if method_name && method_name.is_a?(ProcLiteral) %}
          {{method_name}}.call
        {% elsif method_name %}
          {{method_name.id}}
        {% else %}
          {{block.body}}
        {% end %}
        nil
      end
    end

    macro after_touch(method_name = nil, **opts, &block)
      {% n = @type.methods.select { |m| m.name.stringify.starts_with?("after_touch__cb_") }.size %}
      {% cond = opts["if"] %}
      {% not_cond = opts["unless"] %}
      def after_touch__cb_{{n.id}} : Nil
        __cb_skip_unless({{cond}}, "nil")
        __cb_skip_if({{not_cond}}, "nil")
        {% if method_name && method_name.is_a?(ProcLiteral) %}
          {{method_name}}.call
        {% elsif method_name %}
          {{method_name.id}}
        {% else %}
          {{block.body}}
        {% end %}
        nil
      end
    end
  end
end
