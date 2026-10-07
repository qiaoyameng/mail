# encoding: utf-8
# frozen_string_literal: true

module Mail
  # = Dkim
  #
  # RFC 6376 (DKIM) canonicalization of raw message bytes.
  #
  # Mail only computes the canonicalized input to the signature hash;
  # DNS lookups and private key handling are left to the signing service.
  #
  #   Mail::Dkim.canonicalize(raw_message,
  #                           header: :relaxed, body: :relaxed,
  #                           signed_headers: %w[From To Subject],
  #                           body_length: nil)
  module Dkim
    require "mail/dkim/header_canonicalizer"
    require "mail/dkim/body_canonicalizer"
    require "mail/dkim/message_canonicalizer"

    # Canonicalizes a raw RFC 5322 message. +header+ and +body+ select the
    # "simple" or "relaxed" algorithm for each part, +signed_headers+ is
    # the h= list of header field names (an Array, or a colon-separated
    # String as found in a DKIM-Signature field), and +body_length+ is the
    # optional l= limit counted in canonicalized body bytes.
    def self.canonicalize(message, header: :relaxed, body: :relaxed, signed_headers: [], body_length: nil)
      MessageCanonicalizer.new(message,
                               header_mode: header,
                               body_mode: body,
                               signed_headers: signed_headers,
                               body_length: body_length).to_s
    end

    # Canonicalizes a single header field, e.g. a DKIM-Signature field
    # with an emptied b= value prepared by the signing service.
    def self.canonicalize_header(name, value, mode = :relaxed)
      HeaderCanonicalizer.canonicalize(name, value, mode)
    end

    # Canonicalizes a message body in one pass. See BodyCanonicalizer for
    # a streaming interface suitable for chunked hashing.
    def self.canonicalize_body(body, mode = :relaxed, length: nil)
      BodyCanonicalizer.canonicalize(body, mode, length: length)
    end
  end
end
