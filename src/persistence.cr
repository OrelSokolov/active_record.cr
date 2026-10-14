# Persistence: save/create/update/destroy + dirty tracking.
# Oracle-verified against activerecord 8.1.4 (oracle/expected.yml).

module ActiveRecord
  class Base
    # --- dirty -----------------------------------------------------------

    def attribute_changed?(name : String, value : Value) : Bool
      if __original_attributes.has_key?(name)
        __original_attributes[name] != value
      else
        value != default_for(name)
      end
    end

    def changed_attribute?(name : String) : Bool
      __original_attributes.has_key?(name) && __original_attributes[name] != attributes[name]
    end

    def default_for(name : String) : Value
      defaults = self.class.__column_defaults
      defaults.has_key?(name) ? defaults[name] : nil
    end

    def changed? : Bool
      attributes.any? { |name, value| attribute_changed?(name, value) }
    end

    def changed : Array(String)
      attributes.select { |name, value| attribute_changed?(name, value) }.keys
    end

    def changes : Hash(String, Tuple(Value, Value))
      result = {} of String => Tuple(Value, Value)
      attributes.each do |name, value|
        if attribute_changed?(name, value)
          from = __original_attributes.has_key?(name) ? __original_attributes[name] : default_for(name)
          result[name] = {from.as(Value), value}
        end
      end
      result
    end

    # --- save / create ----------------------------------------------------

    def save(validate : Bool = true) : Bool
      return false if destroyed?
      raise ReadOnlyRecord.new("Cannot update a read-only record") if readonly?
      return false unless validate ? valid? : true
      tx_event : Symbol = new_record? ? :create : :update
      tx = Base.__current_tx
      Base.__register_in_transaction(self, tx_event)
      saved = false
      begin
        # Oracle-verified order (8.1.4): around_save wraps before_save and
        # the create/update chain; after_save runs after around_save exits.
        #
        # CODEGEN WORKAROUND (Crystal 1.21 / LLVM): when this closure's last
        # executed effect is a write to the captured `saved` local (i.e. the
        # write sits in tail position of the proc), the virtual call
        # `__wrap_around_save(0, ...)` is miscompiled for some receiver
        # classes: the call returns without ever entering the method, so the
        # action silently never runs and save() returns false with empty
        # errors (seen on STI subclasses like Rooms::Open). Any statement
        # after the captured write restores correct codegen — hence the
        # trailing `nil`. Do not make `saved = true` the last expression.
        __wrap_around_save(0, ->{
          if __run_before_save
            if new_record?
              __wrap_around_create(0, ->{
                changes_to_write = changes
                __write_timestamps_on_create
                id = __insert(changes_to_write.keys + (changes_to_write.keys & ["created_at", "updated_at"]))
                @id = id
                self.new_record = false
                @previous_changes = changes_to_write
                __snapshot_original!
              })
              __run_after_create
            else
              __wrap_around_update(0, ->{
                changes_to_write = __merge_updated_at_change(changes)
                # attr_readonly columns are silently dropped from updates.
                unless __readonly_attrs.empty?
                  changes_to_write = changes_to_write.reject { |k, _| __readonly_attrs.includes?(k) }
                end
                # Optimistic locking (lock_version column): increment in the
                # same UPDATE and fail on a stale row (0 rows affected).
                if __optimistic_locking?
                  old_lv = attributes["lock_version"]?.as?(Int64) || 0_i64
                  changes_to_write = changes_to_write.merge(
                    {"lock_version" => {old_lv.as(Value), old_lv + 1}})
                  assign_attributes({"lock_version" => old_lv + 1})
                end
                __update(changes_to_write) unless changes_to_write.empty?
                @previous_changes = changes_to_write
                __snapshot_original!
              })
              __run_after_update
            end
            saved = true
          end
          # keep this tail statement: see the codegen-workaround note above
          nil
        })
        if saved
          __run_after_save
          __run_after_commit(tx_event) unless tx
        end
        saved
      rescue ex : DB::Error | PQ::PQError
        __run_after_rollback(tx_event) unless tx
        raise RecordNotUnique.new(ex.message) if ex.message.try(&.includes?("duplicate key"))
        raise ex
      end
    end

    def save! : Bool
      save || raise RecordInvalid.new(self)
    end

    def self.create(values : Hash(String, Value) = {} of String => Value) : self
      record = new
      record.assign_attributes(values)
      record.save
      record
    end

    def self.create!(values : Hash(String, Value) = {} of String => Value) : self
      record = new
      record.assign_attributes(values)
      record.save || raise RecordInvalid.new(record)
      record
    end

    def update(values : Hash(String, Value)) : Bool
      assign_attributes(values)
      save
    end

    def update!(values : Hash(String, Value)) : Bool
      assign_attributes(values)
      save || raise RecordInvalid.new(self)
    end

    # Rails: skips validations, returns the save result (Bool, not self).
    def update_attribute(name : String, value : Value) : Bool
      assign_attributes({name => value})
      save(validate: false)
    end

    def update_attributes(values : Hash(String, Value)) : Bool
      update(values)
    end

    def self.update(id : Int64 | Int32, values : Hash(String, Value)) : self
      record = find(id)
      record.update(values) || raise ActiveRecordError.new("Failed to update #{self} #{id}")
      record
    end

    def self.update!(id : Int64 | Int32, values : Hash(String, Value)) : self
      record = find(id)
      record.update!(values)
      record
    end

    def self.destroy(id : Int64 | Int32) : self
      find(id).destroy
    end

    def self.delete(id : Int64 | Int32) : Int64
      Base.__session.exec(
        %(DELETE FROM #{quoted_table_name} WHERE "#{primary_key}" = $1), args: [id.to_i64]).rows_affected
    end

    # --- destroy ----------------------------------------------------------

    def destroy : self
      raise ReadOnlyRecord.new("Cannot destroy a read-only record") if readonly?
      unless destroyed?
        tx = Base.__current_tx
        # Oracle-verified order: around_destroy wraps before_destroy and the
        # DELETE; after_destroy runs after around_destroy exits.
        __wrap_around_destroy(0, ->{
          __run_before_destroy
          if (pk = @id)
            Base.__register_in_transaction(self, :destroy)
            __run_dependents
            Base.__session.exec(
              %(DELETE FROM #{self.class.quoted_table_name} WHERE "#{self.class.primary_key}" = $1), args: [pk])
          end
          self.destroyed = true
          self.new_record = false
        })
        __run_after_destroy
        __run_after_commit(:destroy) unless tx
      end
      self
    end

    # No real freeze in Crystal: `frozen?` mirrors post-destroy state.
    def frozen? : Bool
      destroyed?
    end

    # --- reload / attribute helpers (§6) -----------------------------------

    def reload : self
      pk = @id
      raise ActiveRecordError.new("cannot reload a new record") if pk.nil?
      fresh = self.class.find(pk)
      fresh.attributes.each do |k, v|
        assign_attributes({k => v}) unless k == self.class.primary_key
      end
      @original_attributes = fresh.__original_attributes
      self.new_record = false
      self.destroyed = false
      self
    end

    # Rails increment/decrement: in-memory only; the bang versions save
    # without validations and return the save result.
    def increment(attr : String, by : Int64 = 1) : self
      current = attributes[attr]?.as?(Int64) || 0_i64
      assign_attributes({attr => current + by})
      self
    end

    def increment!(attr : String, by : Int64 = 1) : Bool
      increment(attr, by)
      save(validate: false)
    end

    def decrement(attr : String, by : Int64 = 1) : self
      current = attributes[attr]?.as?(Int64) || 0_i64
      assign_attributes({attr => current - by})
      self
    end

    def decrement!(attr : String, by : Int64 = 1) : Bool
      decrement(attr, by)
      save(validate: false)
    end

    # Rails toggle: flips the attribute in memory, returns self; the bang
    # version saves and returns the save result.
    def toggle(attr : String) : self
      current = attributes[attr]?.as?(Bool) || false
      assign_attributes({attr => !current})
      self
    end

    def toggle!(attr : String) : Bool
      toggle(attr)
      save(validate: false)
    end

    # Reverts pending changes back to the loaded/saved values.
    def restore_attributes : Nil
      __original_attributes.each do |k, v|
        assign_attributes({k => v}) unless k == "id"
      end
    end

    def previous_changes : Hash(String, Tuple(Value, Value))
      saved_changes
    end

    # Rails cache_key: "<table>/<id>" (+ "-<updated_at compact>" when the
    # model has timestamps), "<table>/new" for new records.
    def cache_key : String
      if new_record?
        "#{self.class.table_name}/new"
      elsif self.class.__column_names.includes?("updated_at") &&
            (ua = attributes["updated_at"]?.as?(Time))
        "#{self.class.table_name}/#{id}-#{ua.to_utc.to_s("%Y%m%d%H%M%S")}"
      else
        "#{self.class.table_name}/#{id}"
      end
    end

    # Instance delete: no callbacks, no dependents (Rails `delete`).
    def delete : self
      if (pk = @id) && !destroyed?
        Base.__session.exec(
          %(DELETE FROM #{self.class.quoted_table_name} WHERE "#{self.class.primary_key}" = $1), args: [pk])
        self.destroyed = true
      end
      self
    end

    # Runtime class switch onto the same table row (STI-style becomes).
    def becomes(klass : U.class) : U forall U
      record = U.new(for_load: true)
      record.id = @id
      attributes.each do |k, v|
        record.assign_attributes({k => v}) unless k == self.class.primary_key
      end
      record.new_record = new_record?
      record.__snapshot_original! unless new_record?
      record
    end

    # --- low-level ----------------------------------------------------------

    def update_columns(values : Hash(String, Value)) : Nil
      raise ActiveRecordError.new("can't update_columns a new record") if new_record?
      raise ReadOnlyRecord.new("Cannot update a read-only record") if readonly?
      pk = @id.not_nil!
      assign_attributes(values)
      sets = values.keys.map { |k| %("#{k.gsub('"', "")}") }
      args = [] of DB::Any
      values.each_value { |v| args << v.as(DB::Any) }
      sql = %(UPDATE #{self.class.quoted_table_name} SET #{sets.map_with_index { |s, i| "#{s} = $#{i + 1}" }.join(", ")} WHERE "#{self.class.primary_key}" = $#{values.size + 1})
      args << pk
      Base.__session.exec(sql, args: args)
      __snapshot_original!
    end

    def touch : self
      touch("updated_at")
    end

    def touch(*columns : String) : self
      raise ActiveRecordError.new("can't touch a new record") if new_record?
      raise ReadOnlyRecord.new("Cannot touch a read-only record") if readonly?
      now = Time.utc
      cols = columns.empty? ? ["updated_at"] : columns.to_a
      assignments = cols.map { |c| %("#{c.gsub('"', "")}") }
      args = [] of DB::Any
      cols.each { |_c| args << now.as(DB::Any) }
      pk = @id.not_nil!
      sql = %(UPDATE #{self.class.quoted_table_name} SET #{assignments.map_with_index { |s, i| "#{s} = $#{i + 1}" }.join(", ")} WHERE "#{self.class.primary_key}" = $#{cols.size + 1})
      args << pk
      Base.__session.exec(sql, args: args)
      cols.each { |c| assign_attributes({c => now}) }
      __snapshot_original!
      __run_after_touch
      self
    end

    # --- bulk -----------------------------------------------------------

    def self.insert_all!(rows : Array(Hash(String, Value))) : Int64
      insert_all(rows, "") # "" → no conflict clause → raises on duplicates
    end

    def self.insert_all(rows : Array(Hash(String, Value)), conflict_clause : String = "DO NOTHING") : Int64
      return 0_i64 if rows.empty?
      # Rails fills created_at/updated_at on bulk inserts (touch semantics).
      if __column_names.includes?("created_at")
        now = Time.utc
        rows = rows.map do |row|
          dup = row.dup
          dup["created_at"] = now unless dup["created_at"]?
          dup["updated_at"] = now unless dup["updated_at"]?
          dup
        end
      end
      cols = rows.first.keys
      col_sql = cols.map { |c| %("#{c.gsub('"', "")}") }.join(", ")
      values_sql = [] of String
      args = [] of DB::Any
      rows.each do |row|
        placeholders = cols.map do |c|
          args << (row[c]?.as(DB::Any))
          "$#{args.size}"
        end
        values_sql << "(#{placeholders.join(", ")})"
      end
      tail = conflict_clause.empty? ? "" : " ON CONFLICT #{conflict_clause}"
      sql = "INSERT INTO #{quoted_table_name} (#{col_sql}) VALUES #{values_sql.join(", ")}#{tail}"
      Base.__session.exec(sql, args: args).rows_affected
    end

    def self.upsert_all(rows : Array(Hash(String, Value))) : Int64
      insert_all(rows, "DO NOTHING")
    end

    def self.quoted_table_name : String
      %("#{table_name.gsub('"', "")}")
    end

    # --- find_or_create ------------------------------------------------

    def self.find_or_create_by(where : Hash(String, Value), extra : Hash(String, Value) = {} of String => Value) : self
      found = where_clause_relation(where).first
      return found if found
      record = new
      record.assign_attributes(where.merge(extra))
      record.save
      record
    end

    def self.find_or_create_by!(where : Hash(String, Value), extra : Hash(String, Value) = {} of String => Value) : self
      found = where_clause_relation(where).first
      return found if found
      record = new
      record.assign_attributes(where.merge(extra))
      record.save || raise RecordInvalid.new(record)
      record
    end

    def self.where_clause_relation(where : Hash(String, Value))
      rel = all
      where.each do |k, v|
        rel = rel.where(%("#{k.gsub('"', "")}" = ?), v.as(DB::Any))
      end
      rel
    end

    # --- internals --------------------------------------------------------

    # Attribute value → SQL bind parameter. jsonb columns carry JSON::Any in
    # memory; crystal-pg binds them as a JSON string.
    private def __db_param(value : Value) : DB::Any
      case value
      when JSON::Any then value.to_json
      when Array then value.to_json
      when PG::Numeric then value.to_f
      else value
      end
    end

    def __insert(cols : Array(String)) : Int64
      attrs = attributes
      pk_name = self.class.primary_key
      col_names = cols.empty? ? (self.class.__column_names - [pk_name]) : cols.select { |c| c != pk_name }
      # timestamps are only written when the table has them
      col_names = (col_names + ["created_at", "updated_at"])
        .uniq.select { |c| self.class.__column_names.includes?(c) }
      args = [] of DB::Any
      placeholders = col_names.map do |c|
        args << __db_param(attrs[c]?)
        "$#{args.size}"
      end
      col_sql = col_names.map { |c| %("#{c.gsub('"', "")}") }.join(", ")
      sql = %(INSERT INTO #{self.class.quoted_table_name} (#{col_sql}) VALUES (#{placeholders.join(", ")}) RETURNING "#{pk_name}")
      Base.__session.query_one(sql, args: args, as: Int64)
    end

    def __optimistic_locking? : Bool
      self.class.__column_names.includes?("lock_version")
    end

    def __update(changes : Hash(String, Tuple(Value, Value))) : Nil
      pk = @id.not_nil!
      col_names = changes.keys
      args = [] of DB::Any
      sets = col_names.map_with_index do |c, i|
        args << __db_param(changes[c][1])
        %("#{c.gsub('"', "")}") + " = $#{i + 1}"
      end
      args << pk
      sql = %(UPDATE #{self.class.quoted_table_name} SET #{sets.join(", ")} WHERE "#{self.class.primary_key}" = $#{col_names.size + 1})
      if __optimistic_locking? && (lv = changes["lock_version"]?)
        sql += %( AND "lock_version" = $#{col_names.size + 2})
        args << lv[0].as(DB::Any)
      end
      result = Base.__session.exec(sql, args: args)
      if __optimistic_locking? && result.rows_affected == 0
        raise StaleObjectError.new(
          "Attempted to update a stale object: #{self.class.name} (#{pk})")
      end
    end

    def __write_timestamps_on_create : Nil
      now = Time.utc
      assign_attributes({"created_at" => now}) if self.class.__column_names.includes?("created_at") && attributes["created_at"]?.nil?
      assign_attributes({"updated_at" => now}) if self.class.__column_names.includes?("updated_at") && attributes["updated_at"]?.nil?
    end

    def __merge_updated_at_change(changes : Hash(String, Tuple(Value, Value))) : Hash(String, Tuple(Value, Value))
      if self.class.__column_names.includes?("updated_at")
        now = Time.utc
        merged = changes.dup
        merged["updated_at"] = {attributes["updated_at"]?.as(Value), now}
        assign_attributes({"updated_at" => now})
        merged
      else
        changes
      end
    end
  end

  class ActiveRecordError < Exception
  end

  class Errors
    struct Error
      getter attribute : String
      getter type : Symbol
      getter message : String?
      getter? strict : Bool
      getter detail_value : Value?

      def initialize(@attribute, @type, @message = nil, @strict = false, @detail_value = nil)
      end
    end

    include Enumerable(Error)

    @errors = [] of Error

    def add(attribute : String, message : String, type : Symbol = :invalid,
            strict : Bool = false, detail_value : Value? = nil) : Nil
      @errors << Error.new(attribute, type, message, strict, detail_value)
    end

    def add(attribute : String, type : Symbol) : Nil
      @errors << Error.new(attribute, type, default_message(type))
    end

    def clear : Nil
      @errors.clear
    end

    def empty? : Bool
      @errors.empty?
    end

    def size : Int32
      @errors.size
    end

    def each(& : Error ->) : Nil
      @errors.each { |e| yield e }
    end

    def where(attribute : String) : Array(Error)
      @errors.select { |e| e.attribute == attribute }
    end

    def where(attribute : String, type : Symbol) : Array(Error)
      @errors.select { |e| e.attribute == attribute && e.type == type }
    end

    # Rails errors.details: {attr => [{error: :type, value: ...}]}.
    def details : Hash(String, Array(Hash(Symbol, DetailValue)))
      result = {} of String => Array(Hash(Symbol, DetailValue))
      @errors.each do |e|
        entry = Hash(Symbol, DetailValue).new
        entry[:error] = e.type
        entry[:value] = e.detail_value if e.detail_value
        (result[e.attribute] ||= [] of Hash(Symbol, DetailValue)) << entry
      end
      result
    end

    def group_by_attribute : Hash(String, Array(Error))
      result = {} of String => Array(Error)
      @errors.each do |e|
        (result[e.attribute] ||= [] of Error) << e
      end
      result
    end

    def full_messages : Array(String)
      @errors.map { |e| "#{human_attribute(e.attribute)} #{e.message || default_message(e.type)}" }
    end

    def human_attribute(name : String) : String
      # dots too (autosave nested errors: "auto_comments.body" →
      # "Auto comments body", mirroring Rails' humanize)
      parts = name.gsub(".", "_").split("_")
      parts.map_with_index { |p, i| i == 0 ? p.capitalize : p }.join(" ")
    end

    private def default_message(type : Symbol) : String
      case type
      when :blank           then "can't be blank"
      when :too_long        then "is too long"
      when :not_a_number    then "is not a number"
      when :greater_than    then "must be greater than %{count}"
      when :less_than       then "must be less than %{count}"
      when :invalid         then "is invalid"
      when :taken           then "has already been taken"
      when :record_invalid  then "is invalid"
      else                       "is invalid"
      end
    end
  end
end
