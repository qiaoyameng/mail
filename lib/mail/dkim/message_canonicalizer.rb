# encoding: utf-8
# frozen_string_literal: true

module Mail
  module Dkim
    # = Message Canonicalizer
    #
    # Splits a raw RFC 5322 message into its header section and body and
    # produces the RFC 6376 canonicalized form that a signing service
    # feeds to its hash function.
    #
    # The message is used exactly as given: headers are never reordered,
    # rewritten or added, and the message is not round-tripped through
    # Mail::Message#encoded.
    #
    #   canonicalized = Mail::Dkim::MessageCanonicalizer.new(
    #     raw_message,
    #     header_mode: :relaxed,
    #     body_mode: :relaxed,
    #     signed_headers: %w[From To Subject Date Message-ID],
    #     body_length: nil
    #   )
    #   canonicalized.canonicalized_headers # headers selected by the h= list
    #   canonicalized.canonicalized_body    # canonicalized body (capped by l=)
    #   canonicalized.to_s                  # headers + body
    class MessageCanonicalizer
      CRLF = "\r\n".b
      LF = "\n".b

      # A single raw header field parsed from the message. +raw+ keeps the
      # field exactly as it appeared, folding and terminating CRLF
      # included, so "simple" canonicalization can emit it unchanged.
      class HeaderField
        attr_reader :name, :raw

        def initialize(name, raw)
          @name = name
          @raw = raw
        end

        def value
          @value ||= @raw.byteslice(@raw.index(":") + 1..-1).sub(/\r?\n\z/, "")
        end
      end

      attr_reader :canonicalized_headers, :canonicalized_body

      def initialize(message, header_mode: :relaxed, body_mode: :relaxed, signed_headers: [], body_length: nil)
        unless [:simple, :relaxed].include?(header_mode)
          raise ArgumentError, "unknown DKIM header canonicalization: #{header_mode.inspect}"
        end

        @header_mode = header_mode
        header_bytes, body_bytes = split_message(message.to_str.b)
        fields = select_fields(parse_fields(header_bytes), signed_headers)
        @canonicalized_headers = fields.map { |field| canonicalize_field(field) }.join.b

        body_canonicalizer = BodyCanonicalizer.new(body_mode, length: body_length)
        @canonicalized_body = body_canonicalizer.update(body_bytes) << body_canonicalizer.finish
      end

      def to_s
        canonicalized_headers + canonicalized_body
      end

      private

      def split_message(message)
        offset = 0
        message.each_line do |line|
          if line == CRLF || line == LF
            body = message.byteslice(offset + line.bytesize..-1) || +"".b
            return message.byteslice(0, offset), body
          end
          offset += line.bytesize
        end
        [message, +"".b]
      end

      def parse_fields(header_bytes)
        raws = []
        current = nil
        header_bytes.each_line do |line|
          if current && line.start_with?(" ", "\t")
            current << line
          else
            raws << current if current
            current = line
          end
        end
        raws << current if current

        fields = []
        raws.each do |raw|
          first_line = raw.each_line.first
          colon = first_line && first_line.index(":")
          fields << HeaderField.new(raw.byteslice(0, colon), raw) if colon
        end
        fields
      end

      # Selects the fields listed in the h= tag, in h= order. Each listed
      # name consumes the bottom-most field instance that has not been
      # selected yet, so a name listed twice signs two distinct fields.
      def select_fields(fields, signed_headers)
        available = fields.dup
        normalize_signed_headers(signed_headers).map do |name|
          index = available.rindex { |field| field.name.downcase == name }
          available.delete_at(index) if index
        end.compact
      end

      def normalize_signed_headers(signed_headers)
        names = signed_headers.is_a?(String) ? signed_headers.split(":") : signed_headers.to_a
        names.map { |name| name.to_s.strip.downcase }
      end

      def canonicalize_field(field)
        case @header_mode
        when :simple
          field.raw.end_with?(LF) ? field.raw : "#{field.raw}#{CRLF}".b
        when :relaxed
          HeaderCanonicalizer.relaxed(field.name, field.value)
        end
      end
    end
  end
end
