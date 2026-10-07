# encoding: utf-8
# frozen_string_literal: true
require "mail/utilities"

module Mail
  # Mail::BodyView selects the body part of a message that is best suited
  # for display (for example in a mail preview), given a list of media
  # types the caller is able to display and an optional preference order.
  #
  #   view = Mail::BodyView.select(mail, supported: %w[text/html text/plain],
  #                                      prefer:    %w[text/html])
  #   view.status     #=> :ok
  #   view.part       #=> the Mail::Part chosen for display (or nil)
  #   view.path       #=> [0, 1]  (child indexes from the message root)
  #   view.mime_path  #=> ["multipart/alternative", "text/html"]
  #   view.resources  #=> { "logo@example.com" => #<Mail::Part> }
  #
  # Selection rules:
  #
  # * multipart/alternative - every branch is resolved to a displayable
  #   candidate and the branch whose leaf media type ranks best in the
  #   preference list wins. Ties are broken by document order.
  # * multipart/related - the +start+ parameter of the Content-Type header
  #   selects the root part by Content-ID. When +start+ is absent the first
  #   part is the root (RFC 2387). When +start+ names a Content-ID that no
  #   sibling part has, the result falls back to the first part and reports
  #   the miss via Result#status (:missing_start) and Result#missing_starts.
  # * any other multipart type - the first branch (in document order) that
  #   yields a displayable candidate wins.
  # * message/rfc822 parts are treated as opaque attachments: they are never
  #   descended into, never selected as the body, and Content-IDs inside
  #   them are never collected as resources of the outer message.
  # * a part without a Content-Type header is treated as text/plain
  #   (the RFC 2045 default).
  #
  # Resource (cid) resolution rules:
  #
  # * Every multipart/related on the path to the selected part contributes
  #   one scope consisting of its direct children that carry a Content-ID.
  # * A part's id is its Content-ID without angle brackets. A cid URL is
  #   matched by stripping the (case-insensitive) "cid:" scheme and
  #   URI-unescaping the remainder, then comparing for equality with the
  #   unescaped id. BodyView.cid_url_for produces the matching escaped URL.
  # * When several scopes are nested, the innermost scope wins.
  # * A Content-ID that appears more than once within a single scope is
  #   ambiguous: it is reported in Result#ambiguities (with the scope path
  #   and the conflicting part paths), excluded from Result#resources, and
  #   Result#resolve_cid raises AmbiguousContentIdError for it. The first
  #   occurrence is never silently chosen.
  #
  # BodyView is strictly read-only: it never reorders parts, never assigns
  # or generates Content-IDs and never modifies the message in any way.
  class BodyView
    # Media types considered displayable when the caller passes none.
    DEFAULT_SUPPORTED = %w[text/html text/plain].freeze

    # Raised by Result#resolve_cid when the requested Content-ID is
    # ambiguous within its multipart/related scope.
    class AmbiguousContentIdError < StandardError; end

    # Describes one duplicated Content-ID inside a single related scope.
    # +scope_path+ is the MIME path of the multipart/related container,
    # +paths+ are the MIME paths of every part sharing +content_id+.
    Ambiguity = Struct.new(:content_id, :scope_path, :paths)

    # Describes a multipart/related +start+ parameter that named a
    # Content-ID no sibling part carries.
    MissingStart = Struct.new(:start, :scope_path)

    # The outcome of a BodyView selection.
    class Result
      # :ok, :missing_start or :unsupported
      attr_reader :status

      # The selected part (a Mail::Message or Mail::Part), or nil when
      # nothing displayable was found.
      attr_reader :part

      # Child indexes from the message root to the selected part.
      # Empty when the message itself is the body. nil when unsupported.
      attr_reader :path

      # Media types along the path from the message root to the selected
      # part, e.g. ["multipart/mixed", "multipart/alternative", "text/html"].
      attr_reader :mime_path

      # Content-ID (unescaped, without angle brackets) => part, for every
      # multipart/related scope on the path to the selected part.
      attr_reader :resources

      # Content-ID => MIME path of the resource part.
      attr_reader :resource_paths

      # Array of Ambiguity for Content-IDs duplicated within one scope.
      attr_reader :ambiguities

      # Array of MissingStart for +start+ parameters with no matching part
      # on the path to the selected part.
      attr_reader :missing_starts

      def initialize(status:, part:, path:, mime_path:, resources:, resource_paths:, ambiguities:, missing_starts:)
        @status = status
        @part = part
        @path = path
        @mime_path = mime_path
        @resources = resources
        @resource_paths = resource_paths
        @ambiguities = ambiguities
        @missing_starts = missing_starts
      end

      def ok?
        status == :ok
      end

      # True when no displayable part could be selected at all.
      def unsupported?
        status == :unsupported
      end

      # True when a multipart/related +start+ parameter on the path to the
      # selected part named a Content-ID that does not exist. The first
      # part of the container was used as the root instead.
      def missing_start?
        !missing_starts.empty?
      end

      # Resolves a "cid:..." URL to a resource part of the selected body.
      #
      # Returns nil for non-cid URLs and for unknown ids. Raises
      # AmbiguousContentIdError when the id is duplicated within its scope
      # instead of silently returning the first match.
      def resolve_cid(url)
        id = BodyView.cid_url_to_id(url)
        return nil if id.nil?

        if (ambiguity = ambiguities.find { |a| a.content_id == id })
          raise AmbiguousContentIdError,
                "Content-ID #{id.inspect} is ambiguous in the multipart/related scope " \
                "at MIME path #{ambiguity.scope_path.inspect} " \
                "(#{ambiguity.paths.length} parts share it)"
        end

        resources[id]
      end
    end

    # Selects the displayable body part of +message+. See the class
    # documentation for the full selection and resource rules.
    #
    # +supported+ lists the media types the caller can display.
    # +prefer+ orders media types from most to least preferred; types not
    # listed rank below listed ones. Defaults to the +supported+ order.
    def self.select(message, supported: DEFAULT_SUPPORTED, prefer: nil)
      new(message, supported: supported, prefer: prefer).select
    end

    # Returns the "cid:..." URL that addresses +part+'s Content-ID, or nil
    # when the part carries no Content-ID. Never generates a Content-ID.
    #
    # The id is taken verbatim (without angle brackets) and URI-escaped,
    # mirroring Mail::Part#url but without side effects.
    def self.cid_url_for(part)
      id = content_id_of(part)
      id && "cid:#{Mail::Utilities.uri_escape(id)}"
    end

    # Converts a "cid:..." URL back to the unescaped Content-ID it names
    # (nil when +url+ is not a cid URL). This is the exact inverse of the
    # escaping done by cid_url_for.
    def self.cid_url_to_id(url)
      return nil unless url.is_a?(String) && /\Acid:/i.match?(url)

      Mail::Utilities.uri_unescape(url.sub(/\Acid:/i, ""))
    end

    # Returns the part's Content-ID without angle brackets, or nil when the
    # part has no Content-ID header. Read-only: never generates an id.
    def self.content_id_of(part)
      header = part.header
      return nil unless header && header.has_content_id?

      id = part.content_id
      id.nil? ? nil : Mail::Utilities.unbracket(id.to_s)
    end

    def initialize(message, supported: DEFAULT_SUPPORTED, prefer: nil)
      @message = message
      @supported = Array(supported).map { |t| t.to_s.downcase }
      @preference = Array(prefer || supported).map { |t| t.to_s.downcase }
      @missing_starts = []
    end

    def select
      candidate = walk(@message, [])

      if candidate.nil?
        return Result.new(status: :unsupported, part: nil, path: nil,
                          mime_path: nil, resources: {}, resource_paths: {},
                          ambiguities: [], missing_starts: [])
      end

      resources, resource_paths, ambiguities = collect_resources(candidate.path)
      relevant_misses = @missing_starts.select do |miss|
        path_prefix?(miss.scope_path, candidate.path)
      end
      status = relevant_misses.empty? ? :ok : :missing_start

      Result.new(status: status,
                 part: candidate.part,
                 path: candidate.path,
                 mime_path: mime_path_for(candidate.path),
                 resources: resources,
                 resource_paths: resource_paths,
                 ambiguities: ambiguities,
                 missing_starts: relevant_misses)
    end

    private

    Candidate = Struct.new(:part, :path, :mime_type)

    # Resolves the displayable candidate for +node+. Returns nil when the
    # subtree rooted at +node+ contains nothing the caller can display.
    def walk(node, path)
      return nil if encapsulated_message?(node, path)

      if multipart?(node)
        case sub_type_of(node)
        when "alternative"
          walk_alternative(node, path)
        when "related"
          walk_related(node, path)
        else
          walk_mixed(node, path)
        end
      elsif @supported.include?(mime_type_of(node))
        Candidate.new(node, path, mime_type_of(node))
      end
    end

    def walk_alternative(node, path)
      candidates = []
      node.parts.each_with_index do |child, index|
        candidate = walk(child, path + [index])
        candidates << candidate if candidate
      end
      candidates.min_by { |c| [preference_rank(c.mime_type), c.path] }
    end

    def walk_related(node, path)
      return nil if node.parts.empty?

      root_index = related_root_index(node, path)
      walk(node.parts[root_index], path + [root_index])
    end

    def walk_mixed(node, path)
      node.parts.each_with_index do |child, index|
        candidate = walk(child, path + [index])
        return candidate if candidate
      end
      nil
    end

    # The root of a multipart/related is the part named by the +start+
    # parameter, or the first part when +start+ is absent (RFC 2387). A
    # +start+ that names no sibling is recorded and deterministically
    # falls back to the first part.
    def related_root_index(node, path)
      params = node.content_type_parameters || {}
      start = params["start"]
      return 0 if start.nil?

      wanted = Mail::Utilities.unbracket(start.to_s.strip)
      index = node.parts.index { |part| BodyView.content_id_of(part) == wanted }
      if index.nil?
        @missing_starts << MissingStart.new(start.to_s, path)
        index = 0
      end
      index
    end

    # Builds the resource map for every multipart/related scope on the
    # selected path. Each related container contributes its direct
    # children; inner scopes override outer ones. message/rfc822 parts are
    # never entered, so their Content-IDs cannot leak into an outer scope.
    def collect_resources(path)
      resources = {}
      resource_paths = {}
      ambiguities = []

      node = @message
      path.each_with_index do |index, depth|
        if related?(node)
          scope_path = path[0...depth]
          scope = collect_scope(node, scope_path, ambiguities)
          scope.each do |id, child_path|
            resources[id] = node.parts[child_path.last]
            resource_paths[id] = child_path
          end
        end
        node = node.parts[index]
      end

      [resources, resource_paths, ambiguities]
    end

    # Maps Content-ID => child path for the direct children of one
    # multipart/related container. Ids occurring more than once are
    # reported as ambiguities and excluded from the returned map.
    def collect_scope(node, scope_path, ambiguities)
      paths_by_id = {}
      node.parts.each_with_index do |child, index|
        id = BodyView.content_id_of(child)
        next if id.nil?

        (paths_by_id[id] ||= []) << scope_path + [index]
      end

      scope = {}
      paths_by_id.each do |id, paths|
        if paths.length > 1
          ambiguities << Ambiguity.new(id, scope_path, paths)
        else
          scope[id] = paths.first
        end
      end
      scope
    end

    def mime_path_for(path)
      types = [mime_type_of(@message)]
      node = @message
      path.each do |index|
        node = node.parts[index]
        types << mime_type_of(node)
      end
      types
    end

    def preference_rank(mime_type)
      @preference.index(mime_type) || @preference.length
    end

    def path_prefix?(prefix, path)
      path[0, prefix.length] == prefix
    end

    def encapsulated_message?(node, path)
      !path.empty? && mime_type_of(node) == "message/rfc822"
    end

    def multipart?(node)
      node.multipart? && node.respond_to?(:parts)
    end

    def related?(node)
      multipart?(node) && sub_type_of(node) == "related"
    end

    def sub_type_of(node)
      node.sub_type.to_s.downcase
    end

    # A part without a Content-Type header defaults to text/plain
    # (RFC 2045, section 5.2).
    def mime_type_of(node)
      (node.mime_type || "text/plain").downcase
    end
  end
end
