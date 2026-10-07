# encoding: utf-8
# frozen_string_literal: true

require 'mail/dkim/body_canonicalizer'

module Mail
  # = DKIM (RFC 6376) canonicalization
  #
  # Mail does not sign messages, verify signatures, query DNS, or hold
  # private keys. Those belong to the signing service. What Mail provides
  # here is the canonicalized byte stream that such a service hashes:
  #
  # * header canonicalization (+simple+ and +relaxed+, RFC 6376 3.4.1/3.4.2)
  #   with header selection driven by the DKIM +h=+ tag list
  # * body canonicalization (+simple+ and +relaxed+, RFC 6376 3.4.3/3.4.4),
  #   one-shot or streaming, with optional +l=+ body length limiting
  #
  # All entry points take the raw message bytes exactly as they were
  # received or will be transmitted. Do NOT pass Mail::Message#encoded
  # output here unless it is known to be byte-identical to the original:
  # re-rendering a message can reorder, refold, or add header fields and
  # would change the canonicalized form.
  #
  #   headers = Mail::DKIM.canonicalized_headers(raw, 'from:to:subject', mode: :relaxed)
  #   body    = Mail::DKIM.canonicalized_body(raw_body, mode: :relaxed)
  #
  #   # Streaming, straight into a digest:
  #   digest = Digest::SHA256.new
  #   canon  = Mail::DKIM::BodyCanonicalizer.new(:relaxed, sink: digest)
  #   canon.update(chunk1)
  #   canon.update(chunk2)
  #   canon.finish
  #   digest.hexdigest
  module DKIM
    CRLF = "\r\n".freeze

    module_function

    # Splits raw message bytes into [header_block, body] at the first
    # empty line. Accepts CRLF or bare LF line endings on input.
    def split_message(message)
      raw = message.to_s.b
      if (index = raw.index("\r\n\r\n"))
        [raw.byteslice(0...index), raw.byteslice(index + 4..-1) || String.new]
      elsif (index = raw.index("\n\n"))
        [raw.byteslice(0...index), raw.byteslice(index + 2..-1) || String.new]
      else
        [raw, String.new]
      end
    end

    # Returns the canonicalized form of the header fields named by
    # +h_list+, taken from the raw +message+ bytes.
    #
    # +h_list+ is the DKIM +h=+ tag value: an array of header names or a
    # colon-separated string. Names are matched case-insensitively. Each
    # name selects the bottommost occurrence of that field that has not
    # already been selected, so a repeated name signs multiple instances
    # from the bottom up and never reuses the same field. Names that do
    # not match any remaining field are ignored.
    #
    # +mode+ is :simple or :relaxed (default :relaxed).
    def canonicalized_headers(message, h_list, mode: :relaxed)
      header_block, = split_message(message)
      fields = parse_header_fields(header_block)
      select_fields(fields, h_list).map do |field|
        canonicalize_header(field, mode)
      end.join
    end

    # One-shot body canonicalization of raw +body+ bytes.
    #
    # +length+ is the DKIM +l=+ tag value: the canonicalized body is
    # truncated to that many bytes. The count applies to the
    # canonicalized output, never to the raw input.
    def canonicalized_body(body, mode: :simple, length: nil)
      canonicalizer = BodyCanonicalizer.new(mode, length: length)
      canonicalizer.update(body)
      canonicalizer.finish
    end

    # Convenience wrapper returning [canonicalized_headers, canonicalized_body]
    # for a raw message.
    def canonicalize(message, headers:, header_mode: :relaxed, body_mode: :relaxed, body_length: nil)
      header_block, body = split_message(message)
      fields = parse_header_fields(header_block)
      head = select_fields(fields, headers).map do |field|
        canonicalize_header(field, header_mode)
      end.join
      [head, canonicalized_body(body, mode: body_mode, length: body_length)]
    end

    # Splits a header block into individual header fields. Continuation
    # lines (starting with WSP) are folded back onto their field with
    # CRLF so each returned field is the raw header without its
    # terminating CRLF.
    def parse_header_fields(header_block)
      fields = []
      header_block.to_s.b.split(/\r\n|\n/).each do |line|
        if !fields.empty? && line.match?(/\A[ \t]/)
          fields[-1] = fields[-1] + CRLF + line
        else
          fields << line
        end
      end
      fields
    end

    def select_fields(fields, h_list)
      taken = Array.new(fields.length, false)
      normalize_h_list(h_list).each_with_object([]) do |name, chosen|
        index = (fields.length - 1).downto(0).find do |i|
          !taken[i] && field_name(fields[i]) == name
        end
        if index
          taken[index] = true
          chosen << fields[index]
        end
      end
    end

    def canonicalize_header(field, mode)
      case normalize_mode(mode)
      when :simple
        field + CRLF
      when :relaxed
        name, _colon, value = field.partition(":")
        name = name.downcase.sub(/[ \t]+\z/, "")
        value = value.gsub(/\r\n/, "")      # unfold, keeping WSP
        value = value.gsub(/[ \t]+/, " ")   # compress WSP runs to one SP
        value = value.sub(/\A /, "").sub(/ \z/, "")
        "#{name}:#{value}#{CRLF}"
      end
    end

    def normalize_mode(mode)
      normalized = mode.to_s.downcase.to_sym
      unless [:simple, :relaxed].include?(normalized)
        raise ArgumentError, "unknown DKIM canonicalization mode: #{mode.inspect}"
      end
      normalized
    end

    def normalize_h_list(h_list)
      list = h_list.is_a?(String) ? h_list.split(":") : Array(h_list)
      list.map { |name| name.to_s.strip.downcase }.reject(&:empty?)
    end

    def field_name(field)
      field.partition(":").first.strip.downcase
    end
  end
end
