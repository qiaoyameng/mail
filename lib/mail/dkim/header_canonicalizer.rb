# encoding: utf-8
# frozen_string_literal: true

module Mail
  module Dkim
    # = Header Canonicalizer
    #
    # Implements the RFC 6376 "simple" (section 3.4.1) and "relaxed"
    # (section 3.4.2) header canonicalization algorithms.
    #
    # The +value+ given here is the raw header field value as it appears
    # (or will appear) on the wire, including any folding whitespace, but
    # excluding the terminating CRLF.
    module HeaderCanonicalizer
      CRLF = "\r\n".b

      def self.canonicalize(name, value, mode = :relaxed)
        case mode
        when :simple
          simple(name, value)
        when :relaxed
          relaxed(name, value)
        else
          raise ArgumentError, "unknown DKIM header canonicalization: #{mode.inspect}"
        end
      end

      # "simple" tolerates no change: the field is hashed exactly as
      # presented, so the name and value are emitted byte for byte.
      def self.simple(name, value)
        "#{name}:#{value}#{CRLF}".b
      end

      # "relaxed" lowercases the field name, unfolds continuation lines,
      # collapses runs of whitespace to a single space and trims
      # whitespace around the colon and at the end of the value.
      def self.relaxed(name, value)
        "#{relax_name(name)}:#{relax_value(value)}#{CRLF}".b
      end

      def self.relax_name(name)
        name.to_s.b.sub(/[ \t]+\z/, "").downcase
      end

      def self.relax_value(value)
        value.to_s.b.
          gsub(/\r?\n(?=[ \t])/, "").
          gsub(/[ \t]+/, " ").
          sub(/\A /, "").
          sub(/ \z/, "")
      end
    end
  end
end
