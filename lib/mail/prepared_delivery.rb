# frozen_string_literal: true
require 'json'
require 'digest'

module Mail
  # = Prepared Delivery
  #
  # A PreparedDelivery is an immutable snapshot of a Mail::Message captured by
  # Mail::Message#prepare_delivery.  It holds the SMTP envelope (sender and
  # recipients, including Bcc recipients) and the fully encoded message bytes
  # exactly as they should be handed to the transport.
  #
  # Because the message is encoded once, at preparation time, every retry of a
  # queued delivery can reuse the exact same bytes: auto generated values such
  # as the Date, Message-ID, MIME boundary and content transfer encoding are
  # fixed when the snapshot is taken, and reading the snapshot never triggers
  # encoding or random value generation again.
  #
  # Snapshots can be persisted with #dump and reloaded with
  # Mail::PreparedDelivery.restore.  The serialized form is plain JSON with
  # explicit byte lengths and a digest, so restoring never deserializes
  # arbitrary Ruby objects.
  #
  # Example:
  #
  #  snapshot = mail.prepare_delivery
  #  snapshot.envelope_from #=> 'mikel@test.lindsaar.net'
  #  snapshot.envelope_to   #=> ['you@test.lindsaar.net', 'bcc@test.lindsaar.net']
  #  snapshot.message       #=> "Date: ...\r\nFrom: ..." (no Bcc header)
  #  snapshot.digest        #=> '9f86d08...' (SHA-256 of the message bytes)
  #
  #  stored = snapshot.dump
  #  Mail::PreparedDelivery.restore(stored) == snapshot #=> true
  class PreparedDelivery
    # Identifies the serialized format produced by #dump.
    FORMAT = 'mail/prepared-delivery'.freeze

    # Version of the serialized format, validated on restore.
    VERSION = 1

    # Raised when a payload passed to ::restore fails validation.
    class RestoreError < ArgumentError; end

    attr_reader :envelope_from, :envelope_to, :message, :digest

    def initialize(envelope_from, envelope_to, message) #:nodoc:
      @envelope_from = self.class.validate_component_string('envelope_from', envelope_from).dup.freeze
      @envelope_to   = self.class.validate_component_envelope_to(envelope_to).map { |addr| addr.dup.freeze }.freeze
      @message       = self.class.validate_component_string('message', message).dup.freeze
      @digest        = Digest::SHA256.hexdigest(@message).freeze
      freeze
    end

    # The encoded message bytes, ready to be sent as-is.
    def to_s
      @message
    end

    # Size of the encoded message in bytes.
    def bytesize
      @message.bytesize
    end

    def ==(other)
      other.kind_of?(PreparedDelivery) &&
        envelope_from == other.envelope_from &&
        envelope_to == other.envelope_to &&
        message == other.message
    end
    alias eql? ==

    def hash
      [self.class, envelope_from, envelope_to, message].hash
    end

    # Serializes the snapshot to a JSON string.  The payload records the byte
    # length of every component plus a SHA-256 digest of the message so that
    # ::restore can verify the data without deserializing arbitrary objects.
    def dump
      JSON.generate(
        'format'        => FORMAT,
        'version'       => VERSION,
        'digest'        => @digest,
        'lengths'       => {
          'envelope_from' => @envelope_from.bytesize,
          'envelope_to'   => @envelope_to.map(&:bytesize),
          'message'       => @message.bytesize
        },
        'envelope_from' => @envelope_from,
        'envelope_to'   => @envelope_to,
        'message'       => @message
      )
    end

    # Rebuilds a snapshot from a string produced by #dump.
    #
    # Raises Mail::PreparedDelivery::RestoreError if the payload is not valid
    # JSON, does not match the expected format and version, contains values of
    # the wrong type, or has byte lengths or a digest that do not match the
    # embedded data.
    def self.restore(payload)
      unless payload.is_a?(String)
        raise RestoreError, "prepared delivery payload must be a String, got #{payload.class}"
      end

      data =
        begin
          JSON.parse(payload)
        rescue JSON::ParserError => e
          raise RestoreError, "invalid prepared delivery payload: #{e.message}"
        end

      unless data.is_a?(Hash)
        raise RestoreError, "prepared delivery payload must be a JSON object, got #{data.class}"
      end

      unless data['format'] == FORMAT
        raise RestoreError, "unrecognized prepared delivery format: #{data['format'].inspect}"
      end

      unless data['version'] == VERSION
        raise RestoreError, "unsupported prepared delivery version: #{data['version'].inspect}"
      end

      envelope_from = data['envelope_from']
      envelope_to   = data['envelope_to']
      message       = data['message']

      validate_component_string('envelope_from', envelope_from)
      validate_component_envelope_to(envelope_to)
      validate_component_string('message', message)
      validate_lengths(data['lengths'], envelope_from, envelope_to, message)
      validate_digest(data['digest'], message)

      new(envelope_from, envelope_to, message)
    end

    def self.validate_component_string(name, value) #:nodoc:
      unless value.is_a?(String) && !value.empty?
        raise RestoreError, "prepared delivery #{name} must be a non-empty String, got #{value.inspect}"
      end
      value
    end

    def self.validate_component_envelope_to(value) #:nodoc:
      unless value.is_a?(Array) && !value.empty? && value.all? { |addr| addr.is_a?(String) && !addr.empty? }
        raise RestoreError, "prepared delivery envelope_to must be an Array of non-empty Strings, got #{value.inspect}"
      end
      value
    end

    def self.validate_lengths(lengths, envelope_from, envelope_to, message) #:nodoc:
      unless lengths.is_a?(Hash)
        raise RestoreError, "prepared delivery lengths must be a JSON object, got #{lengths.inspect}"
      end

      expected = {
        'envelope_from' => envelope_from.bytesize,
        'envelope_to'   => envelope_to.map(&:bytesize),
        'message'       => message.bytesize
      }

      expected.each do |key, want|
        got = lengths[key]
        unless got == want
          raise RestoreError, "prepared delivery #{key} length mismatch: expected #{want.inspect}, got #{got.inspect}"
        end
      end
    end
    private_class_method :validate_lengths

    def self.validate_digest(digest, message) #:nodoc:
      unless digest.is_a?(String) && /\A[0-9a-f]{64}\z/.match?(digest)
        raise RestoreError, "prepared delivery digest must be a SHA-256 hex string, got #{digest.inspect}"
      end

      actual = Digest::SHA256.hexdigest(message)
      unless digest == actual
        raise RestoreError, "prepared delivery digest mismatch: expected #{actual}, got #{digest}"
      end
    end
    private_class_method :validate_digest
  end
end
