# encoding: utf-8
# frozen_string_literal: true

module Mail
  # Structured reader for the body of a message/delivery-status part
  # (RFC 3464).
  #
  # A delivery status report is a sequence of header-like blocks separated
  # by blank lines: one per-message block (Reporting-MTA, Arrival-Date and
  # any per-message extension fields) followed by one block per recipient
  # (Final-Recipient, Action, Status, Diagnostic-Code, ...).
  #
  # Flattening those blocks into a single header loses the association
  # between fields of different recipients, so this class keeps each block
  # separate and preserves field order and extension fields within a block.
  #
  #   status = message.delivery_status
  #   status.message_block['reporting-mta']   #=> "dns; mail.example.com"
  #   status.recipient_blocks.map(&:status)   #=> ["5.1.1", "4.2.2"]
  class DeliveryStatus
    # A single header block of a delivery status report. Fields are kept
    # in the order they appear, including extension (X-*) fields.
    class Block
      include Enumerable

      def initialize(header_text)
        @header = Header.new(header_text.to_s)
      end

      # All fields of this block in the order they appear in the report.
      def fields
        @header.fields
      end

      def each(&block)
        fields.each(&block)
      end

      # The value of the first field with the given name, or nil if this
      # block does not contain such a field. Names are matched case
      # insensitively and may be given with dashes or underscores.
      def [](name)
        field = @header[Utilities.dasherize(name.to_s)]
        field = field.first if field.is_a?(Array)
        field.value if field
      end

      # The values of every field with the given name, in the order they
      # appear in this block. Useful for repeated optional fields.
      def values(name)
        case field = @header[Utilities.dasherize(name.to_s)]
        when nil   then []
        when Array then field.map(&:value)
        else [field.value]
        end
      end

      # True if this block contains at least one field with the given name.
      def key?(name)
        !@header[Utilities.dasherize(name.to_s)].nil?
      end
    end

    # The per-message block of the report (first block).
    class MessageBlock < Block
      def reporting_mta
        self['reporting-mta']
      end

      def arrival_date
        self['arrival-date']
      end
    end

    # One per-recipient block of the report. Each block diagnoses exactly
    # one recipient: a missing field or a malformed status code only makes
    # this block's diagnosis unknown, it never borrows values from a
    # neighbouring block.
    class RecipientBlock < Block
      # RFC 3463 status code: class (2, 4 or 5), subject and detail.
      STATUS_PATTERN = /\A[245]\.\d{1,3}\.\d{1,3}\z/

      def action
        self['action']
      end

      def status
        self['status']
      end

      def final_recipient
        self['final-recipient']
      end

      def diagnostic_code
        value = self['diagnostic-code']
        value unless value.nil? || value.strip.empty?
      end

      def remote_mta
        self['remote-mta']
      end

      # True if the Status field of this block holds a well formed
      # RFC 3463 status code.
      def valid_status?
        !!(status.to_s.strip =~ STATUS_PATTERN)
      end

      # Whether delivery to this recipient may be retried: true for a
      # transient (4.x.x) failure, false for a success (2.x.x) or a
      # permanent (5.x.x) failure, and nil when this block has no usable
      # status code to judge by.
      def retryable?
        return nil unless valid_status?
        status.strip.start_with?('4')
      end
    end

    # The per-message block holding fields that apply to the whole report.
    attr_reader :message_block

    # One RecipientBlock per recipient, in the order they appear in the
    # report.
    attr_reader :recipient_blocks

    def initialize(body)
      chunks = Utilities.to_crlf(body.to_s).split(/\r\n\r\n/).reject { |chunk| chunk !~ /\S/ }
      @message_block = MessageBlock.new(chunks.shift.to_s)
      @recipient_blocks = chunks.map { |chunk| RecipientBlock.new(chunk) }
    end

    alias_method :recipients, :recipient_blocks
  end
end
