# encoding: utf-8
# frozen_string_literal: true

module Mail
  # Single-pass reader for mboxrd mailboxes, intended for archive imports.
  #
  # The reader recognizes genuine envelope "From " separator lines, reverses
  # mboxrd escaping of body lines (a single ">" is removed only from lines
  # matching /^>+From/), and hands each message to the regular Mail parser.
  #
  # Envelope sender and date are exposed as archive metadata on each entry;
  # they are never injected into the RFC 5322 headers of the parsed message.
  #
  # The input is consumed with #gets only, so non-seekable IO objects work,
  # and the reader never closes the caller-owned IO, even when the consumer
  # stops iterating early.
  #
  # Usage:
  #
  #   Mail::MboxReader.new(io).each do |entry|
  #     entry.envelope_sender #=> "alice@example.com"
  #     entry.envelope_date   #=> "Sat Oct  3 12:00:00 2026"
  #     entry.offset          #=> byte offset of the "From " separator line
  #     entry.complete?       #=> false if the final message was truncated
  #     entry.mail            #=> Mail::Message built from the message source
  #   end
  class MboxReader
    # Raised when a message exceeds the configured byte limit and the
    # continuation policy is :raise.
    class MessageTooLargeError < StandardError
      attr_reader :start_offset, :end_offset, :bytes, :policy

      def initialize(oversize)
        @start_offset = oversize.start_offset
        @end_offset   = oversize.end_offset
        @bytes        = oversize.bytes
        @policy       = oversize.policy
        super("mbox message at bytes #{@start_offset}...#{@end_offset} " \
              "exceeds the per-message byte limit (#{@bytes} bytes read)")
      end
    end

    # Describes a message that exceeded the byte limit. Passed to the
    # :on_oversize callback and carried by MessageTooLargeError.
    OversizeMessage = Struct.new(:start_offset, :end_offset, :bytes, :policy)

    # One message read from the mailbox.
    class Entry
      # Byte offset of this message's "From " separator line.
      attr_reader :offset

      # Bytes from the separator line up to the next separator (or EOF).
      attr_reader :length

      # Sender taken from the envelope "From " line (archive metadata,
      # not part of the RFC 5322 headers).
      attr_reader :envelope_sender

      # Date string taken from the envelope "From " line (archive metadata,
      # not part of the RFC 5322 headers).
      attr_reader :envelope_date

      # Unescaped message source, exactly as read (a truncated final
      # message is never padded with a synthetic line ending).
      attr_reader :source

      def initialize(offset:, length:, envelope_sender:, envelope_date:, source:, complete:)
        @offset          = offset
        @length          = length
        @envelope_sender = envelope_sender
        @envelope_date   = envelope_date
        @source          = source
        @complete        = complete
      end

      # False when the mailbox ended in the middle of this message's
      # final line, i.e. the message has no proper terminating newline.
      def complete?
        @complete
      end

      # Parses the message source with the regular Mail parser.
      def mail
        Mail.new(source)
      end
    end

    SEPARATOR = /\AFrom /.freeze
    ESCAPED_FROM = /\A>+From/.freeze
    ENVELOPE = /\AFrom[ \t]+(\S+)[ \t]*(.*?)[\r\n]*\z/.freeze

    LIMIT_POLICIES = [:skip, :stop, :raise].freeze

    attr_reader :message_bytes_limit, :on_limit_exceeded

    # io::                 any object responding to #gets (need not be seekable)
    # message_bytes_limit:: maximum bytes allowed for a single message's
    #                       content (nil means unlimited)
    # on_limit_exceeded::  what to do when a message exceeds the limit:
    #                      :skip (default) drops the oversize message and
    #                      continues with the next one, :stop ends iteration,
    #                      :raise raises MessageTooLargeError
    # on_oversize::        optional callable invoked with an OversizeMessage
    #                      (start/end offsets, byte count, policy) whenever a
    #                      message exceeds the limit
    def initialize(io, message_bytes_limit: nil, on_limit_exceeded: :skip, on_oversize: nil)
      unless LIMIT_POLICIES.include?(on_limit_exceeded)
        raise ArgumentError, "on_limit_exceeded must be one of #{LIMIT_POLICIES.inspect}"
      end
      @io = io
      @message_bytes_limit = message_bytes_limit
      @on_limit_exceeded = on_limit_exceeded
      @on_oversize = on_oversize
    end

    # Yields an Entry for each message in the mailbox. The caller's IO is
    # never closed, even if the block exits early.
    def each
      return enum_for(:each) unless block_given?

      io = @io
      io.set_encoding(Encoding::BINARY) if io.respond_to?(:set_encoding)

      offset = 0
      current = nil

      while (line = io.gets)
        line_offset = offset
        offset += line.bytesize

        if line =~ SEPARATOR
          yield build_entry(current, line_offset) if current
          current = start_message(line, line_offset)
        elsif current
          if oversize?(current, line)
            current, offset = handle_oversize(io, current, line, offset)
            return if current == :halted
          else
            current[:bytes] += line.bytesize
            current[:source] << unescape(line)
            current[:ended_with_newline] = line.end_with?("\n")
          end
        end
        # Lines before the first "From " separator are not part of any
        # message and are skipped.
      end

      yield build_entry(current, offset) if current
      nil
    end

    # Yields the parsed Mail::Message for each entry.
    def each_message(&block)
      return enum_for(:each_message) unless block_given?
      each { |entry| yield entry.mail }
    end

    private

    def start_message(separator_line, offset)
      sender = date = nil
      if separator_line =~ ENVELOPE
        sender = $1
        date = $2 unless $2.empty?
      end
      {
        offset: offset,
        envelope_sender: sender,
        envelope_date: date,
        source: String.new,
        bytes: 0,
        ended_with_newline: true
      }
    end

    def build_entry(state, end_offset)
      Entry.new(
        offset: state[:offset],
        length: end_offset - state[:offset],
        envelope_sender: state[:envelope_sender],
        envelope_date: state[:envelope_date],
        source: state[:source],
        complete: state[:ended_with_newline]
      )
    end

    # mboxrd unescaping: remove exactly one leading ">" from lines of the
    # form ">...>From". Other ">"-quoted lines are left untouched so the
    # original body round-trips.
    def unescape(line)
      line =~ ESCAPED_FROM ? line[1..-1] : line
    end

    def oversize?(state, line)
      @message_bytes_limit && state[:bytes] + line.bytesize > @message_bytes_limit
    end

    # Scans ahead (single pass, discarding content) to locate the end of the
    # oversize message, reports it, then applies the continuation policy.
    # Returns [next_message_state_or_:halted, new_offset].
    def handle_oversize(io, state, triggering_line, offset)
      bytes = state[:bytes] + triggering_line.bytesize
      end_offset = offset
      next_line = nil

      while (line = io.gets)
        if line =~ SEPARATOR
          next_line = line
          break
        end
        bytes += line.bytesize
        end_offset += line.bytesize
      end

      oversize = OversizeMessage.new(state[:offset], end_offset, bytes, @on_limit_exceeded)
      @on_oversize.call(oversize) if @on_oversize

      case @on_limit_exceeded
      when :raise
        raise MessageTooLargeError, oversize
      when :stop
        return :halted, end_offset
      else # :skip
        if next_line
          [start_message(next_line, end_offset), end_offset + next_line.bytesize]
        else
          [nil, end_offset]
        end
      end
    end
  end
end
