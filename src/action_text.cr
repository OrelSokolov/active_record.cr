# Action Text port: the `has_rich_text` macro (Rails'
# ActionText::ActiveRecord::HasOneRichTextRecord).
#
# Body rows live in a polymorphic table (default model ActionTextRichText,
# table action_text_rich_texts) keyed by (record_type, record_id, name).
# The macro registers a `rich_text_#{name}` association for preloading
# (kind has_one_poly, see base.cr __preload_assoc) and generates:
#
#   rich_text_body        → ActionTextRichText? (preloading-aware reader)
#   body                  → String? (the stored body text)
#   body=                 → String (write-through; persisted after save via
#                           an after_save hook — new records save the row
#                           after INSERT, existing rows upsert it)
#   with_rich_text_body   → scope: includes(:rich_text_body)
#   with_rich_text_body_and_embeds → alias (embeds/galleries processing is
#                           not ported)

class ActiveRecord::Base
  macro has_rich_text(name, class_name = "ActionTextRichText")
    {% assoc_name = "rich_text_" + name.id.stringify %}
    {% ActiveRecord::ASSOCIATIONS << { @type.name.stringify, assoc_name, "has_one_poly", class_name.id, "record_id" } %}

    @pending_rich_text_{{name.id}} : String?

    def rich_text_{{name.id}} : {{class_name.id}}?
      if (cached = __cached_assoc_record({{assoc_name}}))
        return cached.as({{class_name.id}})
      end
      return nil unless (oid = id)
      rec = {{class_name.id}}
        .where("record_type = ? AND record_id = ? AND name = ?",
               {{@type.name.stringify}}, oid, {{name.id.stringify}})
        .take
      rec.try { |r| __cache_assoc({{assoc_name}}, r) }
      rec
    end

    def {{name.id}} : String?
      rich_text_{{name.id}}.try(&.body)
    end

    def {{name.id}}=(value : String) : String
      @pending_rich_text_{{name.id}} = value
      value
    end

    # Runs after the record itself is saved (id assigned for new records):
    # upserts the body row. Replaced bodies rewrite the existing row.
    after_save __save_rich_text_{{name.id}}

    def __save_rich_text_{{name.id}} : Nil
      return unless (value = @pending_rich_text_{{name.id}})
      @pending_rich_text_{{name.id}} = nil
      oid = id.not_nil!
      if (existing = rich_text_{{name.id}})
        existing.body = value
        existing.save
      else
        {{class_name.id}}.create({
          "record_type" => {{@type.name.stringify}},
          "record_id"   => oid,
          "name"        => {{name.id.stringify}},
          "body"        => value,
        })
      end
      __cache_assoc({{assoc_name}}, rich_text_{{name.id}}.not_nil!)
    end

    # Rails: destroying the record destroys its rich_text rows
    # (ActionText's has_one rich_text, dependent: :destroy).
    after_destroy __destroy_rich_text_{{name.id}}

    def __destroy_rich_text_{{name.id}} : Nil
      return unless (oid = id)
      {{class_name.id}}
        .where("record_type = ? AND record_id = ? AND name = ?",
               {{@type.name.stringify}}, oid, {{name.id.stringify}})
        .delete_all
    end

    def self.with_rich_text_{{name.id}}
      all.includes({{assoc_name.id.symbolize}})
    end

    # Rails loads trix attachments (embeds) with this scope; processing is
    # not ported, so it preloads the rich text record itself.
    def self.with_rich_text_{{name.id}}_and_embeds
      all.includes({{assoc_name.id.symbolize}})
    end
  end
end
