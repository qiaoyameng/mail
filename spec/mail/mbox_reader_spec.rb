# encoding: utf-8
# frozen_string_literal: true
require 'spec_helper'

RSpec.describe Mail::MboxReader do
  def reader_for(string, **options)
    Mail::MboxReader.new(StringIO.new(string), **options)
  end

  def entries_for(string, **options)
    reader_for(string, **options).each.to_a
  end

  describe "splitting messages on envelope From lines" do
    it "reads each message and hands it to the Mail parser" do
      mbox = +"From alice@example.com Sat Oct  3 12:00:00 2026\n"
      mbox << "From: alice@example.com\r\nSubject: One\r\n\r\nfirst body\r\n"
      mbox << "From bob@example.com Sun Oct  4 09:30:00 2026\n"
      mbox << "From: bob@example.com\r\nSubject: Two\r\n\r\nsecond body\r\n"

      entries = entries_for(mbox)
      expect(entries.size).to eq 2
      expect(entries[0].mail.subject).to eq "One"
      expect(entries[1].mail.subject).to eq "Two"
      expect(entries.map { |e| e.mail.body.decoded.strip }).to eq ["first body", "second body"]
    end

    it "records the raw byte offset and length of each message" do
      first_separator  = "From alice@example.com Sat Oct  3 12:00:00 2026\n"
      first_message    = "Subject: One\n\nbody\n"
      second_separator = "From bob@example.com Sun Oct  4 09:30:00 2026\n"
      second_message   = "Subject: Two\n\nbody\n"
      mbox = first_separator + first_message + second_separator + second_message

      entries = entries_for(mbox)
      expect(entries[0].offset).to eq 0
      expect(entries[0].length).to eq (first_separator + first_message).bytesize
      expect(entries[1].offset).to eq (first_separator + first_message).bytesize
      expect(entries[1].length).to eq (second_separator + second_message).bytesize
    end

    it "handles a message with no body" do
      mbox = +"From alice@example.com Sat Oct  3 12:00:00 2026\n"
      mbox << "Subject: empty\n\n"
      mbox << "From bob@example.com Sun Oct  4 09:30:00 2026\n"
      mbox << "Subject: full\n\nbody\n"

      entries = entries_for(mbox)
      expect(entries.size).to eq 2
      expect(entries[0].mail.subject).to eq "empty"
      expect(entries[0].mail.body.decoded).to eq ""
      expect(entries[1].mail.subject).to eq "full"
    end

    it "handles mixed LF and CRLF line endings" do
      mbox = +"From alice@example.com Sat Oct  3 12:00:00 2026\r\n"
      mbox << "Subject: mixed\r\n\r\nline one\nline two\r\n"
      mbox << "From bob@example.com Sun Oct  4 09:30:00 2026\n"
      mbox << "Subject: plain\n\nbody\n"

      entries = entries_for(mbox)
      expect(entries.size).to eq 2
      expect(entries[0].mail.subject).to eq "mixed"
      expect(entries[0].mail.body.decoded).to include("line one")
      expect(entries[1].mail.subject).to eq "plain"
    end

    it "ignores garbage before the first separator" do
      mbox = +"random junk\n"
      mbox << "From alice@example.com Sat Oct  3 12:00:00 2026\n"
      mbox << "Subject: One\n\nbody\n"

      entries = entries_for(mbox)
      expect(entries.size).to eq 1
      expect(entries[0].offset).to eq "random junk\n".bytesize
    end
  end

  describe "mboxrd unescaping" do
    it "does not treat escaped >From lines as separators" do
      mbox = +"From alice@example.com Sat Oct  3 12:00:00 2026\n"
      mbox << "Subject: escapes\n\n"
      mbox << ">From not a separator\n"
      mbox << ">>From deeper quote\n"
      mbox << ">From\n"
      mbox << "From bob@example.com Sun Oct  4 09:30:00 2026\n"
      mbox << "Subject: Two\n\nbody\n"

      entries = entries_for(mbox)
      expect(entries.size).to eq 2
      expect(entries[1].mail.subject).to eq "Two"
    end

    it "removes exactly one > from >+From lines and leaves other > lines alone" do
      mbox = +"From alice@example.com Sat Oct  3 12:00:00 2026\n"
      mbox << "Subject: escapes\n\n"
      mbox << ">From stored once\n"
      mbox << ">>From stored twice\n"
      mbox << ">>>From stored thrice\n"
      mbox << ">just a quoted line\n"
      mbox << ">> quoted deeper\n"
      mbox << "plain\n"

      body = entries_for(mbox).first.mail.body.decoded
      expect(body).to include("From stored once\n")
      expect(body).to include(">From stored twice\n")
      expect(body).to include(">>From stored thrice\n")
      expect(body).to include(">just a quoted line\n")
      expect(body).to include(">> quoted deeper\n")
      expect(body).to include("plain\n")
    end
  end

  describe "envelope metadata" do
    it "keeps envelope sender and date as metadata without touching RFC headers" do
      mbox = +"From alice@example.com Sat Oct  3 12:00:00 2026\n"
      mbox << "Subject: meta\n\nbody\n"

      entry = entries_for(mbox).first
      expect(entry.envelope_sender).to eq "alice@example.com"
      expect(entry.envelope_date).to eq "Sat Oct  3 12:00:00 2026"
      expect(entry.mail.from).to be_nil
      expect(entry.mail.date).to be_nil
      expect(entry.mail.header['From']).to be_nil
    end

    it "handles a separator line without a date" do
      mbox = +"From MAILER-DAEMON\n"
      mbox << "Subject: bounce\n\nbody\n"

      entry = entries_for(mbox).first
      expect(entry.envelope_sender).to eq "MAILER-DAEMON"
      expect(entry.envelope_date).to be_nil
    end
  end

  describe "per-message byte limit" do
    let(:mbox) do
      m = +"From alice@example.com Sat Oct  3 12:00:00 2026\n"
      m << "Subject: small\n\nok\n"
      m << "From bob@example.com Sun Oct  4 09:30:00 2026\n"
      m << "Subject: huge\n\n" << ("x" * 100) << "\n"
      m << "From carol@example.com Mon Oct  5 10:00:00 2026\n"
      m << "Subject: after\n\nok\n"
      m
    end

    it "skips the oversize message and reports its offsets with :skip" do
      oversize = []
      entries = entries_for(mbox, message_bytes_limit: 50,
                            on_limit_exceeded: :skip,
                            on_oversize: ->(o) { oversize << o })

      expect(entries.map { |e| e.mail.subject }).to eq ["small", "after"]
      expect(oversize.size).to eq 1
      expect(oversize[0].policy).to eq :skip
      expect(oversize[0].start_offset).to eq mbox.index("From bob@example.com")
      expect(oversize[0].end_offset).to eq mbox.index("From carol@example.com")
    end

    it "stops iteration with :stop" do
      oversize = []
      entries = entries_for(mbox, message_bytes_limit: 50,
                            on_limit_exceeded: :stop,
                            on_oversize: ->(o) { oversize << o })

      expect(entries.map { |e| e.mail.subject }).to eq ["small"]
      expect(oversize.size).to eq 1
      expect(oversize[0].policy).to eq :stop
    end

    it "raises MessageTooLargeError with offsets and policy with :raise" do
      error = nil
      begin
        entries_for(mbox, message_bytes_limit: 50, on_limit_exceeded: :raise)
      rescue Mail::MboxReader::MessageTooLargeError => e
        error = e
      end

      expect(error).not_to be_nil
      expect(error.policy).to eq :raise
      expect(error.start_offset).to eq mbox.index("From bob@example.com")
      expect(error.end_offset).to eq mbox.index("From carol@example.com")
      expect(error.bytes).to be > 50
    end

    it "rejects an unknown policy" do
      expect {
        reader_for("x", on_limit_exceeded: :explode)
      }.to raise_error(ArgumentError)
    end
  end

  describe "truncated final message" do
    it "flags an incomplete final message without inventing a normal ending" do
      mbox = +"From alice@example.com Sat Oct  3 12:00:00 2026\n"
      mbox << "Subject: whole\n\nbody\n"
      mbox << "From bob@example.com Sun Oct  4 09:30:00 2026\n"
      mbox << "Subject: cut off\n\npartial body with no newline"

      entries = entries_for(mbox)
      expect(entries.size).to eq 2
      expect(entries[0]).to be_complete
      expect(entries[1]).not_to be_complete
      expect(entries[1].source).not_to end_with("\n")
      expect(entries[1].source).to end_with("partial body with no newline")
    end
  end

  describe "IO handling" do
    it "reads from a non-seekable IO" do
      mbox = +"From alice@example.com Sat Oct  3 12:00:00 2026\n"
      mbox << "Subject: pipe\n\nbody\n"

      read_end, write_end = IO.pipe
      write_end.write(mbox)
      write_end.close

      entries = Mail::MboxReader.new(read_end).each.to_a
      expect(entries.size).to eq 1
      expect(entries[0].mail.subject).to eq "pipe"
      expect(entries[0].offset).to eq 0
    ensure
      read_end.close unless read_end.closed?
    end

    it "does not close the caller's IO when the consumer exits early" do
      mbox = +"From alice@example.com Sat Oct  3 12:00:00 2026\n"
      mbox << "Subject: one\n\nbody\n"
      mbox << "From bob@example.com Sun Oct  4 09:30:00 2026\n"
      mbox << "Subject: two\n\nbody\n"

      io = StringIO.new(mbox)
      Mail::MboxReader.new(io).each { |entry| break }
      expect(io).not_to be_closed
    end
  end

  describe "#each_message" do
    it "yields parsed Mail::Message objects" do
      mbox = +"From alice@example.com Sat Oct  3 12:00:00 2026\n"
      mbox << "Subject: one\n\nbody\n"

      messages = reader_for(mbox).each_message.to_a
      expect(messages.size).to eq 1
      expect(messages.first).to be_a(Mail::Message)
      expect(messages.first.subject).to eq "one"
    end
  end
end
