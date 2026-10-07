# frozen_string_literal: true
require 'digest'
require 'json'

module Mail
  class PreparedDelivery
    FORMAT = 'mail-prepared-delivery'
    VERSION = 1

    attr_reader :envelope, :message

    def initialize(envelope_from, envelope_to, message)
      @envelope = Mail::SmtpEnvelope.new(envelope_from, envelope_to, message)

      @message = @envelope.message.dup.force_encoding(Encoding::BINARY).freeze
      @envelope.freeze
    end

    def self.restore(data)
      hash = parse_data(data)
      message = decode_message(hash)

      new(hash.fetch('from'), hash.fetch('to', []), message)
    rescue KeyError, JSON::ParserError, TypeError, ArgumentError => error
      raise error if error.is_a?(ArgumentError)

      raise ArgumentError, 'Invalid prepared delivery snapshot'
    end

    class << self
      alias_method :load, :restore
    end

    def from
      envelope.from
    end

    def to
      envelope.to
    end

    def ==(other)
      other.is_a?(PreparedDelivery) &&
        other.from == from &&
        other.to == to &&
        other.message == message
    end

    alias_method :eql?, :==

    def smtp_envelope_from
      from
    end

    def smtp_envelope_to
      to
    end

    def encoded
      message
    end

    alias_method :bytes, :message
    alias_method :to_s, :encoded

    def delivery_method(method = nil, settings = {})
      if method
        @delivery_method = Configuration.instance.lookup_delivery_method(method).new(settings)
      else
        @delivery_method || Mail.delivery_method.dup
      end
    end

    def deliver!
      delivery_method.deliver!(self)
    end

    def deliver
      deliver!
      self
    end

    def save
      JSON.generate(
        'format' => FORMAT,
        'version' => VERSION,
        'from' => from,
        'to' => to,
        'message' => [message].pack('m0'),
        'message_length' => message.bytesize,
        'message_digest' => Digest::SHA256.hexdigest(message),
      )
    end

    alias_method :dump, :save

    class << self
      private

      def parse_data(data)
        raise ArgumentError, 'Invalid prepared delivery snapshot' unless data.is_a?(String)

        hash = JSON.parse(data)
        raise ArgumentError, 'Invalid prepared delivery snapshot' unless hash.is_a?(Hash)
        raise ArgumentError, 'Invalid prepared delivery snapshot' unless hash['format'] == FORMAT
        raise ArgumentError, 'Invalid prepared delivery snapshot' unless hash['version'] == VERSION
        raise ArgumentError, 'Invalid prepared delivery snapshot' unless hash['from'].is_a?(String)
        unless hash['to'].is_a?(Array) && hash['to'].all? { |address| address.is_a?(String) }
          raise ArgumentError, 'Invalid prepared delivery snapshot'
        end

        hash
      end

      def decode_message(hash)
        encoded_message = hash['message']
        raise ArgumentError, 'Invalid prepared delivery snapshot' unless encoded_message.is_a?(String)

        message = encoded_message.unpack1('m0').force_encoding(Encoding::BINARY)
        expected_length = hash['message_length']
        expected_digest = hash['message_digest']

        unless encoded_message.match?(%r{\A[A-Za-z0-9+/]+={0,2}\z}) &&
               encoded_message.bytesize.modulo(4).zero? &&
               [message].pack('m0') == encoded_message
          raise ArgumentError, 'Prepared delivery encoding is invalid'
        end

        unless expected_length.is_a?(Integer) && expected_length.positive? && message.bytesize == expected_length
          raise ArgumentError, 'Prepared delivery length does not match'
        end

        actual_digest = Digest::SHA256.hexdigest(message)
        unless expected_digest.is_a?(String) &&
               expected_digest.match?(/\A[0-9a-f]{64}\z/) &&
               expected_digest.bytesize == actual_digest.bytesize &&
               expected_digest.bytes.each_with_index.all? { |byte, index| byte == actual_digest.bytes[index] }
          raise ArgumentError, 'Prepared delivery digest does not match'
        end

        message
      end
    end
  end

  DeliverySnapshot = PreparedDelivery
end
