# encoding: utf-8
# frozen_string_literal: true
require "spec_helper"
require "digest"
require "base64"

RSpec.describe Mail::Dkim do
  # RFC 6376 Appendix A.1 example message body
  let(:rfc_body) { "Hi.\r\n\r\nWe lost the game. Are you hungry yet?\r\n\r\nJoe.\r\n" }

  def rfc_message(headers: nil, body: rfc_body)
    headers ||= [
      "From: Joe SixPack <joe@football.example.com>",
      "To: Suzie Q <suzie@shopping.example.net>",
      "Subject: Is dinner ready?",
      "Date: Fri, 11 Jul 2003 21:00:37 -0700 (PDT)",
      "Message-ID: <20030712040037.46341.5F8J@football.example.com>",
    ]
    headers.join("\r\n") + "\r\n\r\n" + body
  end

  describe "body canonicalization" do
    it "matches the RFC 6376 Appendix A relaxed body hash" do
      canonicalized = Mail::Dkim.canonicalize_body(rfc_body, :relaxed)
      expect(Base64.strict_encode64(Digest::SHA256.digest(canonicalized))).
        to eq("2jUSOH9NhtVGCQWNr9BrIAPreKQjO6Sn7XIkfJVOzv8=")
    end

    it "produces the same digest input when fed byte by byte" do
      canonicalizer = Mail::Dkim::BodyCanonicalizer.new(:relaxed)
      digest = Digest::SHA256.new
      rfc_body.each_byte { |byte| digest.update(canonicalizer.update(byte.chr.b)) }
      digest.update(canonicalizer.finish)
      expect(Base64.strict_encode64(digest.digest)).
        to eq("2jUSOH9NhtVGCQWNr9BrIAPreKQjO6Sn7XIkfJVOzv8=")
    end

    it "handles a CRLF split across chunk boundaries" do
      canonicalizer = Mail::Dkim::BodyCanonicalizer.new(:simple)
      output = canonicalizer.update("a\r") << canonicalizer.update("\nb\r\n")
      output << canonicalizer.finish
      expect(output).to eq("a\r\nb\r\n")
    end

    describe "simple" do
      it "leaves a well-formed body untouched" do
        expect(Mail::Dkim.canonicalize_body("a\r\nb\r\n", :simple)).to eq("a\r\nb\r\n")
      end

      it "ignores empty lines at the end of the body" do
        expect(Mail::Dkim.canonicalize_body("a\r\n\r\n\r\n", :simple)).to eq("a\r\n")
      end

      it "keeps empty lines in the middle of the body" do
        expect(Mail::Dkim.canonicalize_body("a\r\n\r\nb\r\n", :simple)).to eq("a\r\n\r\nb\r\n")
      end

      it "canonicalizes an empty body as a single CRLF" do
        expect(Mail::Dkim.canonicalize_body("", :simple)).to eq("\r\n")
        expect(Mail::Dkim.canonicalize_body("\r\n\r\n", :simple)).to eq("\r\n")
      end

      it "adds a CRLF to a body that does not end with one" do
        expect(Mail::Dkim.canonicalize_body("a", :simple)).to eq("a\r\n")
      end

      it "does not alter whitespace" do
        expect(Mail::Dkim.canonicalize_body("a \t  b \r\n", :simple)).to eq("a \t  b \r\n")
      end
    end

    describe "relaxed" do
      it "collapses runs of whitespace within a line to a single space" do
        expect(Mail::Dkim.canonicalize_body("a \t\t b\r\n", :relaxed)).to eq("a b\r\n")
      end

      it "removes whitespace at the end of lines" do
        expect(Mail::Dkim.canonicalize_body("a \t \r\n", :relaxed)).to eq("a\r\n")
      end

      it "reduces leading whitespace to a single space without removing it" do
        expect(Mail::Dkim.canonicalize_body(" \t a\r\n", :relaxed)).to eq(" a\r\n")
      end

      it "drops whitespace-only lines at the end of the body" do
        expect(Mail::Dkim.canonicalize_body("a\r\n \t\r\n\r\n", :relaxed)).to eq("a\r\n")
      end

      it "canonicalizes an empty body as an empty string" do
        expect(Mail::Dkim.canonicalize_body("", :relaxed)).to eq("")
        expect(Mail::Dkim.canonicalize_body("\r\n\r\n", :relaxed)).to eq("")
      end

      it "adds a CRLF to a body that does not end with one" do
        expect(Mail::Dkim.canonicalize_body("a", :relaxed)).to eq("a\r\n")
      end
    end

    describe "body length (l=)" do
      it "counts canonicalized bytes, not raw input bytes" do
        expect(Mail::Dkim.canonicalize_body("a   \r\n", :relaxed, length: 3)).to eq("a\r\n")
      end

      it "truncates the canonicalized body to the given length" do
        expect(Mail::Dkim.canonicalize_body("abcdef\r\n", :simple, length: 4)).to eq("abcd")
      end

      it "does not pad a canonicalized body shorter than the limit" do
        expect(Mail::Dkim.canonicalize_body("a\r\n\r\n\r\n", :simple, length: 100)).to eq("a\r\n")
      end

      it "canonicalizes an empty body before applying the limit" do
        expect(Mail::Dkim.canonicalize_body("", :simple, length: 5)).to eq("\r\n")
        expect(Mail::Dkim.canonicalize_body("", :simple, length: 1)).to eq("\r")
        expect(Mail::Dkim.canonicalize_body("", :simple, length: 0)).to eq("")
      end

      it "applies the limit when fed in chunks" do
        canonicalizer = Mail::Dkim::BodyCanonicalizer.new(:simple, length: 3)
        output = canonicalizer.update("ab") << canonicalizer.update("cdef\r\n")
        output << canonicalizer.finish
        expect(output).to eq("abc")
      end

      it "rejects a negative length" do
        expect { Mail::Dkim::BodyCanonicalizer.new(:simple, length: -1) }.
          to raise_error(ArgumentError)
      end
    end

    it "rejects an unknown mode" do
      expect { Mail::Dkim.canonicalize_body("a", :fancy) }.to raise_error(ArgumentError)
    end

    it "raises when updated after finish" do
      canonicalizer = Mail::Dkim::BodyCanonicalizer.new(:relaxed)
      canonicalizer.finish
      expect { canonicalizer.update("a") }.to raise_error(RuntimeError)
    end
  end

  describe "header canonicalization" do
    describe "simple" do
      it "emits the name and value byte for byte" do
        expect(Mail::Dkim.canonicalize_header("Subject", " A  B ", :simple)).
          to eq("Subject: A  B \r\n")
      end
    end

    describe "relaxed" do
      it "lowercases the field name" do
        expect(Mail::Dkim.canonicalize_header("SuBJeCT", "a", :relaxed)).
          to eq("subject:a\r\n")
      end

      it "removes whitespace around the colon" do
        expect(Mail::Dkim.canonicalize_header("Subject\t", "  a", :relaxed)).
          to eq("subject:a\r\n")
      end

      it "unfolds continuation lines and collapses whitespace" do
        expect(Mail::Dkim.canonicalize_header("Subject", "A\r\n\t B \t C ", :relaxed)).
          to eq("subject:A B C\r\n")
      end

      it "removes whitespace at the end of the value" do
        expect(Mail::Dkim.canonicalize_header("Subject", "a \t", :relaxed)).
          to eq("subject:a\r\n")
      end
    end

    it "rejects an unknown mode" do
      expect { Mail::Dkim.canonicalize_header("a", "b", :fancy) }.to raise_error(ArgumentError)
    end
  end

  describe "message canonicalization" do
    it "selects headers in h= list order" do
      result = Mail::Dkim.canonicalize(rfc_message,
                                       signed_headers: %w[Subject From],
                                       body: :simple)
      expect(result).to eq(
        "subject:Is dinner ready?\r\n" \
        "from:Joe SixPack <joe@football.example.com>\r\n" +
        rfc_body
      )
    end

    it "accepts a colon-separated h= list string" do
      result = Mail::Dkim.canonicalize(rfc_message,
                                       signed_headers: "Subject:From",
                                       body: :simple)
      expect(result).to start_with("subject:Is dinner ready?\r\nfrom:")
    end

    it "skips h= entries that are not present in the message" do
      result = Mail::Dkim.canonicalize(rfc_message,
                                       signed_headers: %w[Subject Missing From],
                                       body: :simple)
      expect(result).to start_with("subject:Is dinner ready?\r\nfrom:")
    end

    describe "with repeated header fields" do
      let(:message) do
        rfc_message(headers: [
                      "X-Test: one",
                      "From: Joe SixPack <joe@football.example.com>",
                      "X-Test: two",
                    ])
      end

      it "selects repeated fields from the bottom up" do
        result = Mail::Dkim.canonicalize(message, signed_headers: %w[X-Test], body: :simple)
        expect(result).to start_with("x-test:two\r\n")
      end

      it "does not reuse the same field instance for a name listed twice" do
        result = Mail::Dkim.canonicalize(message,
                                         signed_headers: %w[X-Test X-Test],
                                         body: :simple)
        expect(result).to start_with("x-test:two\r\nx-test:one\r\n")
      end

      it "ignores h= entries beyond the number of field instances" do
        result = Mail::Dkim.canonicalize(message,
                                         signed_headers: %w[X-Test X-Test X-Test],
                                         body: :simple)
        expect(result).to start_with("x-test:two\r\nx-test:one\r\n")
      end
    end

    describe "with simple header canonicalization" do
      it "emits the raw header bytes including folding and case" do
        message = rfc_message(headers: [
                                "Subject: A\r\n\t folded  subject",
                                "From: Joe SixPack <joe@football.example.com>",
                              ])
        result = Mail::Dkim.canonicalize(message,
                                         header: :simple,
                                         signed_headers: %w[Subject],
                                         body: :simple)
        expect(result).to eq("Subject: A\r\n\t folded  subject\r\n" + rfc_body)
      end
    end

    describe "with relaxed header canonicalization" do
      it "unfolds and normalizes the raw field" do
        message = rfc_message(headers: [
                                "Subject: A\r\n\t folded  subject ",
                                "From: Joe SixPack <joe@football.example.com>",
                              ])
        result = Mail::Dkim.canonicalize(message,
                                         header: :relaxed,
                                         signed_headers: %w[Subject],
                                         body: :simple)
        expect(result).to eq("subject:A folded subject\r\n" + rfc_body)
      end
    end

    it "does not reorder, rewrite or add headers" do
      result = Mail::Dkim.canonicalize(rfc_message,
                                       header: :simple,
                                       signed_headers: %w[From To Subject Date Message-ID],
                                       body: :simple)
      # The empty header/body separator line is not part of the hashed input.
      expect(result).to eq(rfc_message.sub("\r\n\r\n", "\r\n"))
    end

    it "handles a message without a header/body separator" do
      result = Mail::Dkim.canonicalize("From: a@b\r\n",
                                       signed_headers: %w[From],
                                       body: :relaxed)
      expect(result).to eq("from:a@b\r\n")
    end

    it "handles an empty body" do
      result = Mail::Dkim.canonicalize("From: a@b\r\n\r\n",
                                       signed_headers: %w[From],
                                       body: :simple)
      expect(result).to eq("from:a@b\r\n\r\n")
    end

    it "applies the l= limit to the canonicalized body" do
      result = Mail::Dkim.canonicalize(rfc_message(body: "a   \r\n"),
                                       signed_headers: %w[From],
                                       body: :relaxed,
                                       body_length: 3)
      expect(result).to eq("from:Joe SixPack <joe@football.example.com>\r\na\r\n")
    end

    it "rejects an unknown header mode" do
      expect { Mail::Dkim.canonicalize("a", header: :fancy) }.to raise_error(ArgumentError)
    end

    it "returns binary output for non-ASCII input" do
      result = Mail::Dkim.canonicalize(rfc_message(body: "caf\xC3\xA9\r\n".dup.force_encoding(Encoding::UTF_8)),
                                       signed_headers: %w[From],
                                       body: :simple)
      expect(result.encoding).to eq(Encoding::BINARY)
      expect(result).to eq("from:Joe SixPack <joe@football.example.com>\r\ncaf\xC3\xA9\r\n".b)
    end
  end
end
