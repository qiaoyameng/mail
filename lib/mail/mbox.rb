# frozen_string_literal: true

require "stringio"

module Mail
  # = Mail Mboxrd Reader
  #
  # A single-pass, streaming reader for mboxrd archives as described by
  # RFC 4155.
  #
  # The reader scans the input once: a line beginning with the exact
  # sequence +"From "+ starts a new message, mboxrd quoting (>From ,
  # >>From , ...) in message bodies is removed one leading +>+ at a time,
  # and the resulting RFC 5322 message is handed to the existing Mail
  # parser.  The envelope sender and date stay on the record as archive
  # metadata and are never injected into the RFC headers.
  #
  # Because only +gets+ is used, non-seekable inputs (pipes, sockets) are
  # supported, and stopping early (e.g. with +break+) never closes an IO
  # owned by the caller.
  #
  #   Mail::Mbox.foreach("inbox.mbox") do |record|
  #     record.mail.subject
  #     record.envelope_from   #=> "mikel@test.lindsaar.net"
  #     record.envelope_date   #=> #<DateTime ...>
  #     record.start_offset    #=> byte offset of the "From " line
  #   end
  #
  # A per-message byte cap may be passed; see MessageTooLarge for the
  # continuation strategy when a message exceeds it.
  class Mbox

    # Base error for mbox parsing problems.
    class Error < StandardError; end

    # Raised when bytes that are neither blank lines nor an envelope
    # separator are found before the first message.
    class MalformedMbox < Error
      # Byte offset at which the unexpected content was found.
      attr_reader :offset

      def initialize(message, offset)
        @offset = offset
        super(message)
      end
    end

    # Raised (or passed to the +on_message_too_large+ callback) when a
    # message grows past the configured +max_message_size+.
    #
    # The reader has, by the time this is raised, already scanned forward
    # to the start of the next message (or end of input), so #start_offset
    # and #end_offset delimit the entire oversize message in the archive.
    #
    # Two continuation strategies are available:
    #
    # * Rescue the exception and iterate again; reading resumes with the
    #   next message (the input is not rewound and need not be seekable):
    #
    #     reader = Mail::Mbox.new(io, max_message_size: 1024)
    #     loop do
    #       reader.each { |record| import(record) }
    #       break
    #     rescue Mail::Mbox::MessageTooLarge => error
    #       warn "skipping bytes #{error.start_offset}..#{error.end_offset}"
    #       retry
    #     end
    #
    # * Pass +on_message_too_large:+ returning +:skip+ to drop the message
    #   and continue, or +:stop+ to stop the iteration.
    class MessageTooLarge < Error
      # Zero-based index of the oversize message in the archive.
      attr_reader :index

      # Byte offset of the message's "From " line.
      attr_reader :start_offset

      # Byte offset of the start of the next message, or total archive
      # size when the oversize message is last.
      attr_reader :end_offset

      # The configured byte limit.
      attr_reader :limit

      # Number of RFC message bytes accumulated so far.
      attr_reader :bytesize

      # Envelope sender from the "From " line, or nil if unparseable.
      attr_reader :envelope_from

      # Envelope date from the "From " line, or nil when absent.
      attr_reader :envelope_date

      def initialize(index:, start_offset:, end_offset:, limit:, bytesize:,
                     envelope_from:, envelope_date:)
        @index = index
        @start_offset = start_offset
        @end_offset = end_offset
        @limit = limit
        @bytesize = bytesize
        @envelope_from = envelope_from
        @envelope_date = envelope_date
        super("message #{index} starting at byte #{start_offset} is " \
              "#{bytesize} bytes, exceeding the limit of #{limit}")
      end
    end

    # A single message extracted from the archive.
    class Record
      # Zero-based position of the message within the archive.
      attr_reader :index

      # Byte offset of the envelope "From " line.
      attr_reader :start_offset

      # Byte offset immediately after the message's last byte, i.e. the
      # offset of the next "From " line or the total archive size.
      attr_reader :end_offset

      # Raw sender text following "From ", with no parsing applied.
      attr_reader :envelope_line

      # Envelope sender address, or nil if the envelope did not parse.
      attr_reader :envelope_from

      # Parsed envelope reception date, or nil when absent/unparseable.
      attr_reader :envelope_date

      # RFC 5322 message bytes, after mboxrd unquoting.
      attr_reader :raw_source

      # Mail::Message parsed from #raw_source.
      attr_reader :mail

      def initialize(index:, start_offset:, end_offset:, envelope_line:,
                     envelope_from:, envelope_date:, raw_source:, complete:)
        @index = index
        @start_offset = start_offset
        @end_offset = end_offset
        @envelope_line = envelope_line
        @envelope_from = envelope_from
        @envelope_date = envelope_date
        @raw_source = raw_source
        @complete = complete
        @mail = Mail.new(raw_source)
      end

      # Whether the message had a proper line ending before the next
      # separator or end of input. A trailing partial line (an archive
      # truncated mid-write) yields false.
      def complete?
        @complete
      end

      # Size of the RFC message content in bytes (without the "From " line).
      def bytesize
        @raw_source.bytesize
      end
    end

    ENVELOPE_PREFIX = "From ".b
    private_constant :ENVELOPE_PREFIX

    QUOTED_ENVELOPE_LINE = /\A>+From /.freeze
    private_constant :QUOTED_ENVELOPE_LINE

    BLANK_LINE = /\A\r?\n\z/.freeze
    private_constant :BLANK_LINE

    # Streams each record from +source+. A path is opened in binary mode
    # and closed afterwards; an IO is consumed as-is and left open.
    def self.foreach(source, **options, &block)
      return enum_for(:foreach, source, **options) unless block
      if source.is_a?(::String) && File.exist?(source)
        File.open(source, "rb") do |io|
          new(io, **options).each(&block)
        end
      else
        new(source, **options).each(&block)
      end
    end

    # +io+ may be an IO-like object responding to +gets+ or a String
    # containing the archive.
    #
    # +max_message_size+ caps the RFC message bytes (without the envelope
    # line); +on_message_too_large+ is called with the MessageTooLarge
    # error when the cap is exceeded and must return +:skip+ or +:stop+.
    # Without a callback, MessageTooLarge is raised instead.
    def initialize(io, max_message_size: nil, on_message_too_large: nil)
      io = StringIO.new(io) if io.is_a?(::String)
      unless io.respond_to?(:gets)
        raise ArgumentError, "mbox input must respond to #gets"
      end
      if max_message_size && (!max_message_size.is_a?(Integer) || max_message_size <= 0)
        raise ArgumentError, "max_message_size must be a positive integer"
      end

      @io = io
      @max_message_size = max_message_size
      @on_message_too_large = on_message_too_large
      @offset = 0
      @next_index = 0
      @state = :preamble
      @has_pushback = false
      @pushback = nil
      @pushback_offset = 0
    end

    # Yields each Record. Without a block, returns an Enumerator.
    #
    # After a MessageTooLarge raise the reader is already positioned at
    # the next message, so calling #each again (without rewinding the
    # input) continues there. If a previous iteration stopped while a
    # record was being consumed (for example with +break+ inside the
    # block), the next iteration resumes with the following message.
    def each(&block)
      return enum_for(:each) unless block
      return self if @state == :done

      in_message = false
      index = message_start = nil
      envelope_line = envelope_from = envelope_date = nil
      content = empty_buffer
      terminated = false
      content_size = 0

      line, line_start = take_line

      while line
        if separator?(line)
          if in_message
            # The separator belongs to the next message and has not been
            # consumed: make it available before yielding the completed
            # message, so an early exit (e.g. +break+) still resumes at
            # the start of that next message.
            push_back(line, line_start)
            yield_record(block, index, message_start, line_start, envelope_line,
                         envelope_from, envelope_date, content,
                         terminated || content.empty?)
            # Reached only when the block did not break: the separator
            # is processed inline below, so drop the saved copy.
            @has_pushback = false
          end

          index = @next_index
          @next_index += 1
          message_start = line_start
          envelope_line, envelope_from, envelope_date = parse_envelope(line)
          content = empty_buffer
          content_size = 0
          terminated = false
          in_message = true
          @state = :streaming
        elsif !in_message
          unless BLANK_LINE.match?(line)
            raise MalformedMbox.new(
              "found content before the first \"From \" separator at byte #{line_start}",
              line_start
            )
          end
        else
          unescaped = unquote(line)
          content << unescaped
          content_size += unescaped.bytesize
          terminated = line.end_with?("\n".b)

          if oversize?(content_size)
            separator_line, next_offset = scan_to_next_separator
            error = MessageTooLarge.new(
              index: index,
              start_offset: message_start,
              end_offset: next_offset,
              limit: @max_message_size,
              bytesize: content_size,
              envelope_from: envelope_from,
              envelope_date: envelope_date,
            )

            if @on_message_too_large
              action = @on_message_too_large.call(error)
              case action
              when :skip
                # continue from the next separator below
              when :stop
                park(separator_line, next_offset)
                return self
              else
                raise ArgumentError,
                      "on_message_too_large must return :skip or :stop, got #{action.inspect}"
              end
            else
              park(separator_line, next_offset)
              raise error
            end

            if separator_line.nil?
              @state = :done
              return self
            end
            line = separator_line
            line_start = next_offset
            in_message = false
            next
          end
        end

        line, line_start = take_line
      end

      if in_message
        yield_record(block, index, message_start, @offset, envelope_line,
                     envelope_from, envelope_date, content,
                     terminated || content.empty?)
      end
      @state = :done
      self
    end

    private

    def yield_record(block, index, start_offset, end_offset, envelope_line,
                     envelope_from, envelope_date, content, complete)
      record = Record.new(
        index: index,
        start_offset: start_offset,
        end_offset: end_offset,
        envelope_line: envelope_line,
        envelope_from: envelope_from,
        envelope_date: envelope_date,
        raw_source: content,
        complete: complete,
      )
      block.call(record)
    end

    def separator?(line)
      line.start_with?(ENVELOPE_PREFIX)
    end

    # mboxrd unquoting: remove exactly one leading '>' from a line that
    # starts with one or more '>' followed by "From ". Other lines are
    # returned untouched, including lines starting with '>' that are not
    # quoted envelope lines.
    def unquote(line)
      if line.start_with?(">".b) && QUOTED_ENVELOPE_LINE.match?(line)
        line.byteslice(1, line.bytesize - 1)
      else
        line
      end
    end

    def parse_envelope(line)
      rest = line.byteslice(ENVELOPE_PREFIX.bytesize,
                            line.bytesize - ENVELOPE_PREFIX.bytesize)
      rest = rest.sub(/\r?\n\z/, "".b)
      element = begin
          Mail::EnvelopeFromElement.new(rest)
        rescue StandardError
          nil
        end
      [rest, element && element.address, element && element.date_time]
    end

    # Consume input up to and including the next separator; returns the
    # separator line and its start offset, or [nil, total_offset] at EOF.
    def scan_to_next_separator
      while (line = @io.gets("\n"))
        line.force_encoding(Encoding::ASCII_8BIT)
        line_start = @offset
        @offset += line.bytesize
        return [line, line_start] if separator?(line)
      end
      [nil, @offset]
    end

    # Reads one physical line together with its start offset, replaying
    # a line previously stashed with #push_back first.
    def take_line
      if @has_pushback
        @has_pushback = false
        line = @pushback
        line_start = @pushback_offset
      else
        line = @io.gets("\n")
        if line
          line.force_encoding(Encoding::ASCII_8BIT)
          line_start = @offset
          @offset += line.bytesize
        end
      end
      [line, line_start]
    end

    # Hands a line (and its offset) back so the next #take_line returns
    # it without touching the IO.
    def push_back(line, line_start)
      @has_pushback = true
      @pushback = line
      @pushback_offset = line_start
    end

    # Positions reader state so a subsequent #each resumes after an
    # oversize message. A pending separator line is replayed first.
    def park(separator_line, next_offset)
      push_back(separator_line, next_offset)
      @state = :done if separator_line.nil?
    end

    def oversize?(content_size)
      @max_message_size && content_size > @max_message_size
    end

    def empty_buffer
      String.new(encoding: Encoding::ASCII_8BIT)
    end
  end
end
