# encoding: utf-8
# frozen_string_literal: true
require 'mail/constants'

module Mail
  # Structured reader for message/delivery-status bodies (RFC 3464).
  #
  # A delivery status body consists of a per-message block (Reporting-MTA,
  # Arrival-Date, ...) followed by one block per reported recipient.  The
  # legacy Mail::Part accessors flatten every block into a single header,
  # which loses the association between the fields of each recipient;
  # this class keeps the blocks separate while preserving field order and
  # any extension (X-*) fields inside each block.
  #
  #   status = Mail::DeliveryStatus.new(part.body.to_s)
  #   status.message_fields['reporting-mta']   #=> "dns; example.com"
  #   status.recipients.map(&:status)          #=> ["5.1.1", "4.2.2"]
  class DeliveryStatus
    # One header-like block of a delivery status report.  Fields are kept
    # in the order they appear and duplicate fields are preserved.
    class Block
      include Enumerable

      Field = Struct.new(:name, :value)

      attr_reader :fields

      def initialize(fields = [])
        @fields = fields
      end

      def each(&block)
        fields.each(&block)
      end

      # Value of the first field with this (case-insensitive) name, or nil.
      def [](name)
        field = fields.detect { |f| f.name.to_s.casecmp(name.to_s).zero? }
        field && field.value
      end

      # Values of every field with this name, in order of appearance.
      def values(name)
        fields.select { |f| f.name.to_s.casecmp(name.to_s).zero? }.map(&:value)
      end

      def key?(name)
        fields.any? { |f| f.name.to_s.casecmp(name.to_s).zero? }
      end

      def field_names
        fields.map(&:name)
      end

      def empty?
        fields.empty?
      end
    end

    # A per-recipient block of a delivery status report.  Missing or
    # malformed fields only affect this block; sibling recipient blocks
    # are never consulted to fill the gaps.
    class RecipientBlock < Block
      def action
        self['action']
      end

      def status
        self['status']
      end

      def final_recipient
        self['final-recipient']
      end

      def original_recipient
        self['original-recipient']
      end

      def diagnostic_code
        self['diagnostic-code']
      end

      def remote_mta
        self['remote-mta']
      end

      # True when the status field holds a syntactically valid x.y.z code.
      def valid_status?
        !!(status =~ /\A[2-5]\.\d{1,3}\.\d{1,3}\z/)
      end

      # True when the failure is transient (4.x.y), false for permanent
      # (5.x.y) or successful (2.x.y) outcomes, and nil when the status
      # is missing or invalid so this block cannot be diagnosed.
      def retryable?
        case status
        when /\A4\./ then true
        when /\A[25]\./ then false
        end
      end

      def bounced?
        !!(action =~ /failed/i)
      end
    end

    # Parses a message/delivery-status body.
    def self.parse(body)
      new(body)
    end

    def initialize(body)
      blocks = split_blocks(body.to_s)
      if blocks.any? && recipient_block?(blocks.first)
        @message_fields = Block.new
        recipient_blocks = blocks
      else
        @message_fields = Block.new(blocks.shift || [])
        recipient_blocks = blocks
      end
      @recipients = recipient_blocks.map { |fields| RecipientBlock.new(fields) }
    end

    # The per-message block (Reporting-MTA, Arrival-Date, ...).
    attr_reader :message_fields

    # One RecipientBlock per reported recipient, in order of appearance.
    attr_reader :recipients

    private

    RECIPIENT_FIELD_NAMES = %w[final-recipient action status].freeze

    def recipient_block?(fields)
      fields.any? { |f| RECIPIENT_FIELD_NAMES.include?(f.name.to_s.downcase) }
    end

    def split_blocks(body)
      body.split(/\r?\n[ \t]*\r?\n/).map { |chunk| parse_fields(chunk) }.reject(&:empty?)
    end

    def parse_fields(chunk)
      unfolded = chunk.gsub(Constants::UNFOLD_WS, ' ')
      unfolded.split(Constants::LAX_CRLF).map { |line| parse_field(line) }.compact
    end

    def parse_field(line)
      match = line.match(Constants::FIELD_SPLIT)
      match && Block::Field.new(match[1], (match[2] || '').strip)
    end
  end
end
