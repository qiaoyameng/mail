# encoding: utf-8
# frozen_string_literal: true

module Mail
  module Dkim
    # = Body Canonicalizer
    #
    # Implements the RFC 6376 "simple" (section 3.4.3) and "relaxed"
    # (section 3.4.4) body canonicalization algorithms.
    #
    # Input may be fed in arbitrarily sized chunks; a CRLF split across a
    # chunk boundary is handled, so byte-by-byte feeding produces the same
    # canonicalized output as a single pass. Trailing empty lines are held
    # back until more content arrives or the input is finished, at which
    # point they are dropped.
    #
    # When +length+ (the DKIM "l=" tag) is given, output is capped at that
    # many *canonicalized* bytes; the raw input is never truncated.
    #
    #   canonicalizer = Mail::Dkim::BodyCanonicalizer.new(:relaxed)
    #   digest = Digest::SHA256.new
    #   body.each_slice(1024) { |chunk| digest.update(canonicalizer.update(chunk)) }
    #   digest.update(canonicalizer.finish)
    class BodyCanonicalizer
      CRLF = "\r\n".b

      def self.canonicalize(body, mode = :relaxed, length: nil)
        canonicalizer = new(mode, length: length)
        canonicalizer.update(body) << canonicalizer.finish
      end

      def initialize(mode = :relaxed, length: nil)
        unless [:simple, :relaxed].include?(mode)
          raise ArgumentError, "unknown DKIM body canonicalization: #{mode.inspect}"
        end
        if length && (!length.is_a?(Integer) || length < 0)
          raise ArgumentError, "body length must be a non-negative Integer or nil"
        end

        @mode = mode
        @remaining = length
        @buffer = +"".b
        @output = +"".b
        @pending_empty_lines = 0
        @wrote_content = false
        @finished = false
      end

      # Feeds a chunk of the raw body and returns the canonicalized output
      # produced so far (possibly an empty string).
      def update(chunk)
        raise "cannot update a finished BodyCanonicalizer" if @finished

        @buffer << chunk.to_str.b
        drain_lines
        take_output
      end

      # Signals end of input and returns the remaining canonicalized output.
      def finish
        return +"".b if @finished

        @finished = true
        process_line(@buffer.slice!(0, @buffer.bytesize)) unless @buffer.empty?
        @pending_empty_lines = 0
        append_output(CRLF) if @mode == :simple && !@wrote_content
        take_output
      end

      private

      def drain_lines
        while (index = @buffer.index(CRLF))
          process_line(@buffer.slice!(0, index))
          @buffer.slice!(0, 2)
        end
      end

      def process_line(line)
        line = relax_line(line) if @mode == :relaxed
        if line.empty?
          @pending_empty_lines += 1
        else
          @pending_empty_lines.times { append_output(CRLF) }
          @pending_empty_lines = 0
          @wrote_content = true
          append_output(line)
          append_output(CRLF)
        end
      end

      def relax_line(line)
        line.gsub(/[ \t]+/, " ").sub(/ +\z/, "")
      end

      def append_output(string)
        return if @remaining == 0

        if @remaining
          string = string.byteslice(0, @remaining)
          @remaining -= string.bytesize
        end
        @output << string
      end

      def take_output
        @output.slice!(0, @output.bytesize)
      end
    end
  end
end
