# frozen_string_literal: true

require "uri"

module Mail
  class BodyView
    Result = Struct.new(
      :status,
      :part,
      :path,
      :mime_path,
      :resources,
      :resource_paths,
      :resource_mime_paths,
      :scope_part,
      :scope_path,
      :content_id,
      :candidate_paths,
      keyword_init: true,
    ) do
      def ok?
        status == :ok
      end

      alias_method :success?, :ok?
    end

    def self.parse(message, supported_media_types, preferred_media_types = supported_media_types)
      new(message, supported_media_types, preferred_media_types).call
    end

    def self.call(message, supported_media_types, preferred_media_types = supported_media_types)
      parse(message, supported_media_types, preferred_media_types)
    end

    def initialize(message, supported_media_types, preferred_media_types = supported_media_types)
      @message = message
      @supported_media_types = normalize_media_types(supported_media_types)
      @preferred_media_types = normalize_media_types(preferred_media_types)

      @preferred_media_types.each do |media_type|
        unless supported_media_type?(media_type)
          raise ArgumentError, "unsupported preferred media type #{media_type.join("/")}"
        end
      end
    end

    def call
      result = resolve(@message, [])
      return build_result(result) unless result[:status] == :ok

      resources = referenced_resources(result[:part], result[:frames])
      result_without_frames = result.dup
      result_without_frames.delete(:frames)
      result_without_frames[:resources] = resources[:resources]
      result_without_frames[:resource_paths] = resources[:resource_paths]
      result_without_frames[:resource_mime_paths] = resources[:resource_mime_paths]
      build_result(result_without_frames)
    end

    private

    def resolve(part, path)
      if part.multipart?
        resolve_container(part, path)
      elsif selectable_leaf?(part)
        success(part, path, [])
      else
        unsupported_result
      end
    end

    def resolve_container(part, path)
      case part.sub_type.to_s.downcase
      when "related"
        resolve_related(part, path)
      when "alternative"
        resolve_preferred_children(part, path)
      else
        resolve_first_child(part, path)
      end
    end

    def resolve_first_child(part, path)
      structural_error = nil

      part.parts.each_with_index do |child, index|
        child_path = path + [index + 1]
        next if encapsulated_attachment?(child, child_path)

        result = resolve(child, child_path)
        return result if result[:status] == :ok
        structural_error ||= result unless result[:status] == :unsupported_media_type
      end

      structural_error || unsupported_result
    end

    def resolve_preferred_children(part, path)
      selected = nil
      structural_error = nil

      part.parts.each_with_index do |child, index|
        child_path = path + [index + 1]
        next if encapsulated_attachment?(child, child_path)

        result = resolve(child, child_path)
        if result[:status] == :ok
          if selected.nil? || choice_rank(result[:part]) < choice_rank(selected[:part])
            selected = result
          end
        elsif result[:status] != :unsupported_media_type && structural_error.nil?
          structural_error = result
        end
      end

      selected || structural_error || unsupported_result
    end

    def resolve_related(part, path)
      parameters = part.content_type_parameters || {}
      start = parameters["start"]
      entries = direct_entries(part, path)
      duplicates = entries.select { |entry| entry[:content_id] }.group_by { |entry| cid_url(entry[:content_id]) }
      duplicate = duplicates.values.detect { |group| group.length > 1 }

      root_index = nil
      root_part = nil
      root_path = nil

      if start
        start_content_id = normalize_start(start)
        matches = entries.select { |entry| entry[:content_id] == start_content_id }

        if matches.empty?
          return duplicate ? ambiguous_content_id(part, path, duplicate) : error_result(
                   :missing_start,
                   scope_part: part,
                   scope_path: path,
                   content_id: start_content_id,
                 )
        end

        return ambiguous_start(part, path, start_content_id, matches) if matches.length > 1
        return ambiguous_content_id(part, path, duplicate) if duplicate

        root_index = matches.first[:index]
        root_part = matches.first[:part]
        root_path = matches.first[:path]
      else
        return ambiguous_content_id(part, path, duplicate) if duplicate

        root = entries.first
        if root
          root_index = root[:index]
          root_part = root[:part]
          root_path = root[:path]
        end
      end

      return unsupported_result unless root_part

      resources = entries.reject { |entry| entry[:index] == root_index }.select { |entry| entry[:content_id] }

      result = resolve(root_part, root_path)
      return result unless result[:status] == :ok

      frame = {
        scope_part: part,
        scope_path: path,
        resources: resources,
      }
      success(result[:part], result[:path], result[:frames] + [frame])
    end

    def direct_entries(part, path)
      entries = []

      part.parts.each_with_index do |child, index|
        child_path = path + [index + 1]
        next if encapsulated_attachment?(child, child_path)

        entries << {
          index: index,
          part: child,
          path: child_path,
          content_id: content_id(child),
        }
      end

      entries
    end

    def ambiguous_content_id(scope_part, scope_path, entries)
      error_result(
        :ambiguous_content_id,
        scope_part: scope_part,
        scope_path: scope_path,
        content_id: entries.first[:content_id],
        candidate_paths: entries.map { |entry| entry[:path] },
      )
    end

    def ambiguous_start(scope_part, scope_path, content_id, entries)
      error_result(
        :ambiguous_start,
        scope_part: scope_part,
        scope_path: scope_path,
        content_id: content_id,
        candidate_paths: entries.map { |entry| entry[:path] },
      )
    end

    def referenced_resources(part, frames)
      referenced = referenced_cids(part)
      resources = {}
      resource_paths = {}
      resource_mime_paths = {}

      frames.each do |frame|
        frame[:resources].each do |resource|
          key = cid_url(resource[:content_id])
          next unless referenced.include?(key)

          resources[key] ||= resource[:part]
          resource_paths[key] ||= resource[:path]
          resource_mime_paths[key] ||= mime_path(resource[:path])
        end
      end

      { resources: resources, resource_paths: resource_paths, resource_mime_paths: resource_mime_paths }
    end

    def referenced_cids(part)
      body = part.body.decoded
      body = body.to_s unless body.is_a?(String)

      body.scan(%r{cid:([^\s"'<>)]+)}i).map do |(reference)|
        cid_url(Mail::Utilities.uri_unescape(reference))
      end
    rescue StandardError
      []
    end

    def selectable_leaf?(part)
      !part.attachment? && !part.multipart? && supported_rank(part)
    end

    def choice_rank(part)
      preference_rank(part) || [@preferred_media_types.length, supported_rank(part)]
    end

    def encapsulated_attachment?(part, path = [])
      return true if part.mime_type == "message/rfc822" && (path.any? || part.attachment?)
      return true if part.multipart? && part.attachment?

      false
    end

    def preference_rank(part)
      main_type, sub_type = media_type(part)
      @preferred_media_types.index do |preferred_main_type, preferred_sub_type|
        (preferred_main_type == "*" || preferred_main_type == main_type) &&
          (preferred_sub_type == "*" || preferred_sub_type == sub_type)
      end
    end

    def supported_rank(part)
      main_type, sub_type = media_type(part)
      @supported_media_types.index do |supported_main_type, supported_sub_type|
        (supported_main_type == "*" || supported_main_type == main_type) &&
          (supported_sub_type == "*" || supported_sub_type == sub_type)
      end
    end

    def supported_media_type?(media_type)
      @supported_media_types.any? do |supported_main_type, supported_sub_type|
        (supported_main_type == "*" || supported_main_type == media_type[0]) &&
          (supported_sub_type == "*" || supported_sub_type == media_type[1])
      end
    end

    def media_type(part)
      value = part.mime_type || "text/plain"
      value.to_s.downcase.split("/", 2)
    end

    def normalize_media_types(value)
      Array(value).map(&:to_s).flat_map { |media_type| media_type.split(",") }.map do |media_type|
        normalized = media_type.strip.downcase
        match = normalized.match(%r{\A([\w!#$%&^.+-]+|\*)/([\w!#$%&^.+-]+|\*)\z})
        raise ArgumentError, "invalid media type #{media_type.inspect}" unless match

        [match[1], match[2]]
      end
    end

    def content_id(part)
      field = part.header[:content_id]
      return unless field.respond_to?(:content_id)

      value = field.content_id
      value unless value.nil? || value.empty?
    end

    def normalize_start(value)
      normalized = value.to_s.strip
      normalized = $1 if normalized.match(%r{\Acid:(.*)\z}i)
      normalized = Mail::Utilities.uri_unescape(normalized)
      Mail::Utilities.unbracket(normalized)
    end

    def cid_url(content_id)
      "cid:#{Mail::Utilities.uri_escape(content_id)}"
    end

    def mime_path(path)
      path.join(".")
    end

    def success(part, path, frames)
      {
        status: :ok,
        part: part,
        path: path,
        frames: frames,
      }
    end

    def unsupported_result
      { status: :unsupported_media_type }
    end

    def error_result(status, options = {})
      { status: status }.merge(options)
    end

    def build_result(attributes)
      Result.new(
        status: attributes[:status],
        part: attributes[:part],
        path: attributes[:path] || [],
        mime_path: mime_path(attributes[:path] || []),
        resources: attributes[:resources] || {},
        resource_paths: attributes[:resource_paths] || {},
        resource_mime_paths: attributes[:resource_mime_paths] || {},
        scope_part: attributes[:scope_part],
        scope_path: attributes[:scope_path] || [],
        content_id: attributes[:content_id],
        candidate_paths: attributes[:candidate_paths] || [],
      )
    end
  end
end
