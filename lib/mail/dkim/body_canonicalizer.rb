# encoding: utf-8
# frozen_string_literal: true

module Mail
  module DKIM
    # Streaming body canonicalizer (RFC 6376 3.4.3 "simple" and
    # 3.4.4 "relaxed").
    #
    # Feed the raw body in any chunking you like; a CRLF may be split
    # across chunks. Trailing empty lines are held back and only emitted
    # once a non-empty line follows, so they can be dropped at #finish
    # as the RFC requires.
    #
    #   canon = Mail::DKIM::BodyCanonicalizer.new(:relaxed)
    #   canon.update("Hello \r")
    #   canon.update("\nWorld\r\n\r\n")
    #   canon.finish # => "Hello\r\nWorld\r\n"
    #
    # Pass +length:+ to apply the DKIM +l=+ tag. The limit counts
    # canonicalized output bytes, not raw input bytes.
    #
    # Pass +sink:+ (anything responding to <<, e.g. a Digest instance)
    # to stream canonicalized bytes straight into a hash instead of
    # buffering them; #finish then returns the sink.
    class BodyCanonicalizer
      def initialize(mode = :simple, length: nil, sink: nil)
        @mode = DKIM.normalize_mode(mode)
        @limit = length && Integer(length)
        raise ArgumentError, "length must be >= 0" if @limit && @limit < 0
        @sink = sink
        @output = @sink ? nil : String.new
        @written = 0
        @pending_empty_lines = 0
        @partial_line = String.new
        @saw_content = false
        @finished = false
      end

      def update(chunk)
        raise "cannot update a finished BodyCanonicalizer" if @finished
        data = @partial_line + chunk.to_s.b
        offset = 0
        while (match = /\r\n|\n/.match(data, offset))
          process_line(data.byteslice(offset...match.begin(0)))
          offset = match.end(0)
        end
        @partial_line = data.byteslice(offset..-1) || String.new
        self
      end
      alias << update

      # Returns the canonicalized body (or the sink, if one was given).
      # A final line without a terminating CRLF still counts as a line.
      # Per RFC 6376, an empty or all-empty-lines body canonicalizes to
      # a single CRLF for "simple" and to the empty string for "relaxed".
      def finish
        return @sink || @output if @finished
        process_line(@partial_line) unless @partial_line.empty?
        @partial_line = nil
        emit(DKIM::CRLF) if !@saw_content && @mode == :simple
        @finished = true
        @sink || @output
      end

      private

      def process_line(line)
        line = reduce(line) if @mode == :relaxed
        if line.empty?
          @pending_empty_lines += 1
        else
          flush_pending_empty_lines
          @saw_content = true
          emit(line)
          emit(DKIM::CRLF)
        end
      end

      # Relaxed body reduction: compress WSP runs to a single SP, then
      # delete trailing WSP. Whitespace-only lines become empty lines.
      def reduce(line)
        line.gsub(/[ \t]+/, " ").sub(/ \z/, "")
      end

      def flush_pending_empty_lines
        emit(DKIM::CRLF * @pending_empty_lines) if @pending_empty_lines > 0
        @pending_empty_lines = 0
      end

      def emit(string)
        if @limit
          remaining = @limit - @written
          return if remaining <= 0
          string = string.byteslice(0, remaining)
        end
        @written += string.bytesize
        if @sink
          @sink << string
        else
          @output << string
        end
      end
    end
  end
end
