# Active Storage-style single attachment preloading (CRails port).
#
# The app's attachment models are plain ActiveRecord models over the
# Rails-schema tables (active_storage_attachments / active_storage_blobs).
# This macro wires a `#{name}_attachment` reader into the preloading
# machinery (kind as_one in the ASSOCIATIONS registry, see base.cr
# __preload_assoc) so that `includes(:"#{name}_attachment")` — and nested
# paths like `preload(creator: :avatar_attachment)` — batch-load the
# attachment rows in one query.
#
# Generated API (mirrors Rails has_one_attached naming):
#   attachment_attachment / avatar_attachment → ActiveStorageAttachment?
#   attachment_blob / avatar_blob             → Blob? (via attachment row)
#   with_attached_attachment / with_attached_avatar → scope (includes)

class ActiveRecord::Base
  macro preloadable_attachment(name, attachment_class = "ActiveStorageAttachment",
                               blob_class = "ActiveStorageBlob")
    {% assoc_name = name.id.stringify + "_attachment" %}
    {% ActiveRecord::ASSOCIATIONS << { @type.name.stringify, assoc_name, "as_one",
                                       attachment_class.id, "record_id", name.id.stringify } %}

    def {{name.id}}_attachment : {{attachment_class.id}}?
      if (cached = __cached_assoc_record({{assoc_name}}))
        return cached.as({{attachment_class.id}})
      end
      return nil unless (oid = id)
      rec = {{attachment_class.id}}
        .where("record_type = ? AND record_id = ? AND name = ?",
               {{@type.name.stringify}}, oid, {{name.id.stringify}})
        .take
      rec.try { |r| __cache_assoc({{assoc_name}}, r) }
      rec
    end

    def {{name.id}}_blob : {{blob_class.id}}?
      {{name.id}}_attachment.try do |attachment|
        {{blob_class.id}}.find(attachment.blob_id.not_nil!)
      end
    end

    def self.with_attached_{{name.id}}
      all.includes({{assoc_name.id.symbolize}})
    end
  end
end
