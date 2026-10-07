# encoding: utf-8
# frozen_string_literal: true

require 'spec_helper'
require 'digest'

RSpec.describe Mail::DKIM do
  describe "header canonicalization" do
    # RFC 6376 3.4.5 example message
    let(:message) { "A: X\r\nB : Y\r\n\tZ\r\n\r\nbody\r\n" }

    it "canonicalizes relaxed headers per RFC 6376 3.4.2" do
      expect(Mail::DKIM.canonicalized_headers(message, %w[a b], mode: :relaxed)).
        to eq "a:X\r\nb:Y Z\r\n"
    end

    it "keeps simple headers byte-for-byte, adding only the final CRLF" do
      expect(Mail::DKIM.canonicalized_headers(message, %w[a b], mode: :simple)).
        to eq "A: X\r\nB : Y\r\n\tZ\r\n"
    end

    it "accepts a colon-separated h= string" do
      expect(Mail::DKIM.canonicalized_headers(message, "a:b", mode: :relaxed)).
        to eq "a:X\r\nb:Y Z\r\n"
    end

    it "matches header names case-insensitively" do
      expect(Mail::DKIM.canonicalized_headers(message, %w[A B], mode: :relaxed)).
        to eq "a:X\r\nb:Y Z\r\n"
    end

    it "ignores h= names with no matching field" do
      expect(Mail::DKIM.canonicalized_headers(message, %w[a missing], mode: :relaxed)).
        to eq "a:X\r\n"
    end

    it "rejects unknown modes" do
      expect { Mail::DKIM.canonicalized_headers(message, %w[a], mode: :fancy) }.
        to raise_error(ArgumentError)
    end

    it "reads headers from raw bytes without touching Mail::Message" do
      expect(Mail::Message).not_to receive(:new)
      Mail::DKIM.canonicalized_headers(message, %w[a])
    end

    it "handles a message with no body separator" do
      expect(Mail::DKIM.canonicalized_headers("A: 1\r\nB: 2", %w[b a], mode: :relaxed)).
        to eq "b:2\r\na:1\r\n"
    end

    it "canonicalizes bare-LF input to CRLF output" do
      expect(Mail::DKIM.canonicalized_headers("A: 1\nB: 2\n\nbody\n", %w[a b], mode: :simple)).
        to eq "A: 1\r\nB: 2\r\n"
    end

    describe "duplicate header fields" do
      let(:message) do
        "X-Tag: first\r\nFrom: a@example.com\r\nX-Tag: second\r\n\r\nbody\r\n"
      end

      it "selects the bottommost occurrence first" do
        expect(Mail::DKIM.canonicalized_headers(message, %w[x-tag], mode: :simple)).
          to eq "X-Tag: second\r\n"
      end

      it "selects repeated names bottom-up without reusing a field" do
        expect(Mail::DKIM.canonicalized_headers(message, "x-tag:x-tag", mode: :simple)).
          to eq "X-Tag: second\r\nX-Tag: first\r\n"
      end

      it "stops when no unused occurrence remains" do
        expect(Mail::DKIM.canonicalized_headers(message, "x-tag:x-tag:x-tag", mode: :simple)).
          to eq "X-Tag: second\r\nX-Tag: first\r\n"
      end

      it "does not confuse identical fields with each other" do
        message = "X-Dup: same\r\nX-Dup: same\r\n\r\n"
        expect(Mail::DKIM.canonicalized_headers(message, "x-dup:x-dup", mode: :simple)).
          to eq "X-Dup: same\r\nX-Dup: same\r\n"
      end
    end

    describe "relaxed whitespace handling" do
      it "unfolds continuation lines and compresses WSP runs" do
        message = "X-Long: one\r\n\t two   \t three\r\n\r\n"
        expect(Mail::DKIM.canonicalized_headers(message, %w[x-long], mode: :relaxed)).
          to eq "x-long:one two three\r\n"
      end

      it "strips WSP around the colon but keeps case of the value" do
        message = "X-Mixed\t :  Keep CASE \r\n\r\n"
        expect(Mail::DKIM.canonicalized_headers(message, %w[x-mixed], mode: :relaxed)).
          to eq "x-mixed:Keep CASE\r\n"
      end

      it "preserves folding and case in simple mode" do
        message = "X-Mixed\t :  Keep\r\n\tCASE \r\n\r\n"
        expect(Mail::DKIM.canonicalized_headers(message, %w[x-mixed], mode: :simple)).
          to eq "X-Mixed\t :  Keep\r\n\tCASE \r\n"
      end
    end
  end

  describe "body canonicalization" do
    it "simple drops trailing empty lines" do
      expect(Mail::DKIM.canonicalized_body("Hello\r\n\r\n\r\n", mode: :simple)).
        to eq "Hello\r\n"
    end

    it "simple keeps whitespace-only lines and interior empty lines" do
      expect(Mail::DKIM.canonicalized_body("a\r\n \r\n\r\nb\r\n", mode: :simple)).
        to eq "a\r\n \r\n\r\nb\r\n"
    end

    it "simple maps an empty body to a single CRLF" do
      expect(Mail::DKIM.canonicalized_body("", mode: :simple)).to eq "\r\n"
      expect(Mail::DKIM.canonicalized_body("\r\n\r\n", mode: :simple)).to eq "\r\n"
    end

    it "simple adds a CRLF to a final unterminated line" do
      expect(Mail::DKIM.canonicalized_body("abc", mode: :simple)).to eq "abc\r\n"
    end

    it "relaxed reduces WSP per RFC 6376 3.4.5" do
      expect(Mail::DKIM.canonicalized_body(" C \r\nD \t E\r\n\r\n\r\n", mode: :relaxed)).
        to eq " C\r\nD E\r\n"
    end

    it "relaxed maps an empty body to the empty string" do
      expect(Mail::DKIM.canonicalized_body("", mode: :relaxed)).to eq ""
      expect(Mail::DKIM.canonicalized_body("  \t\r\n \r\n", mode: :relaxed)).to eq ""
    end

    it "relaxed turns whitespace-only lines into empty lines" do
      expect(Mail::DKIM.canonicalized_body("a\r\n   \r\nb\r\n", mode: :relaxed)).
        to eq "a\r\n\r\nb\r\n"
    end

    it "handles bare-LF bodies" do
      expect(Mail::DKIM.canonicalized_body("a\nb\n\n", mode: :simple)).to eq "a\r\nb\r\n"
    end
  end

  describe "streaming" do
    let(:body) { "line one \r\n\r\n\tline  two\r\n \r\n\r\n\r\n" }

    [:simple, :relaxed].each do |mode|
      it "produces the same #{mode} output when fed byte by byte" do
        whole = Mail::DKIM.canonicalized_body(body, mode: mode)
        canon = Mail::DKIM::BodyCanonicalizer.new(mode)
        body.each_char { |char| canon.update(char) }
        expect(canon.finish).to eq whole
      end

      it "produces the same #{mode} output for uneven chunk sizes" do
        whole = Mail::DKIM.canonicalized_body(body, mode: mode)
        (1..7).each do |size|
          canon = Mail::DKIM::BodyCanonicalizer.new(mode)
          body.scan(/.{1,#{size}}/m).each { |chunk| canon.update(chunk) }
          expect(canon.finish).to eq whole
        end
      end
    end

    it "handles a CRLF split across chunks" do
      canon = Mail::DKIM::BodyCanonicalizer.new(:simple)
      canon.update("abc\r")
      canon.update("\ndef")
      expect(canon.finish).to eq "abc\r\ndef\r\n"
    end

    it "streams canonicalized bytes into a digest sink" do
      whole = Mail::DKIM.canonicalized_body(body, mode: :relaxed)
      digest = Digest::SHA256.new
      canon = Mail::DKIM::BodyCanonicalizer.new(:relaxed, sink: digest)
      body.each_char { |char| canon << char }
      expect(canon.finish).to equal digest
      expect(digest.hexdigest).to eq Digest::SHA256.hexdigest(whole)
    end

    it "refuses updates after finish" do
      canon = Mail::DKIM::BodyCanonicalizer.new(:simple)
      canon.finish
      expect { canon.update("x") }.to raise_error(RuntimeError)
    end
  end

  describe "l= length limits" do
    it "truncates the canonicalized output" do
      expect(Mail::DKIM.canonicalized_body("abcd\r\nefgh\r\n", mode: :simple, length: 5)).
        to eq "abcd\r"
    end

    it "counts canonicalized bytes, not raw input bytes" do
      # raw is 9 bytes; canonicalized relaxed form is "a b\r\n" (5 bytes)
      expect(Mail::DKIM.canonicalized_body("a  \t b\r\n", mode: :relaxed, length: 4)).
        to eq "a b\r"
    end

    it "applies the limit when streaming" do
      canon = Mail::DKIM::BodyCanonicalizer.new(:simple, length: 3)
      canon.update("hello\r\nworld\r\n")
      expect(canon.finish).to eq "hel"
    end

    it "treats l=0 as an empty body hash input" do
      expect(Mail::DKIM.canonicalized_body("hello\r\n", mode: :simple, length: 0)).to eq ""
      expect(Mail::DKIM.canonicalized_body("", mode: :simple, length: 0)).to eq ""
    end

    it "truncates the CRLF produced for an empty simple body" do
      expect(Mail::DKIM.canonicalized_body("", mode: :simple, length: 1)).to eq "\r"
    end
  end

  describe "message-level helpers" do
    let(:message) do
      "From: a@example.com\r\nTo: b@example.com\r\nSubject: hi\r\n\r\nBody \r\n\r\n"
    end

    it "splits a raw message into header block and body" do
      headers, body = Mail::DKIM.split_message(message)
      expect(headers).to eq "From: a@example.com\r\nTo: b@example.com\r\nSubject: hi"
      expect(body).to eq "Body \r\n\r\n"
    end

    it "canonicalizes headers and body together" do
      headers, body = Mail::DKIM.canonicalize(message, headers: "from:to:subject")
      expect(headers).to eq "from:a@example.com\r\nto:b@example.com\r\nsubject:hi\r\n"
      expect(body).to eq "Body\r\n"
    end

    it "handles a message without a body" do
      headers, body = Mail::DKIM.split_message("A: 1\r\n")
      expect(headers).to eq "A: 1\r\n"
      expect(body).to eq ""
    end
  end
end
