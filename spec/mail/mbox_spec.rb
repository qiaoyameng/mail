# frozen_string_literal: true
require "spec_helper"
require "stringio"
require "tmpdir"

RSpec.describe Mail::Mbox do
  def message_headers(from:, to:, subject:)
    "From: #{from}\r\nTo: #{to}\r\nSubject: #{subject}\r\n"
  end

  def envelope(sender, date = "Mon May  2 16:07:05 2005", ending = "\n")
    "From #{sender} #{date}#{ending}"
  end

  let(:two_message_mbox) do
    first = String.new
    first << message_headers(from: "alice@example.com", to: "bob@example.com", subject: "First")
    first << "\r\n"
    first << "Hello.\r\n"
    first << ">From (quoted) keeps one >\r\n"
    first << ">>From (double quoted) keeps two >\r\n"
    first << ">>>From (triple quoted) keeps three >\r\n"
    first << "> this is not a quoted separator\r\n"
    first << ">From in the middle of a body line stays\r\n"
    first << "leading text From later stays\r\n"
    first << "\r\n"

    second = String.new
    second << "From: carol@example.com\n"
    second << "To: dave@example.com\n"
    second << "Subject: Second\n"
    second << "\n"
    second << "Plain LF body\n"

    mbox = String.new
    mbox << envelope("mda@example.com", "Mon May  2 16:07:05 2005")
    mbox << first
    mbox << envelope("mda2@example.com", "Tue May  3 17:08:06 2005", "\r\n")
    mbox << second
    mbox
  end

  def read_all(source, **options)
    Mail::Mbox.new(source, **options).each.to_a
  end

  describe "parsing" do
    it "returns one record per envelope separator" do
      records = read_all(StringIO.new(two_message_mbox))
      expect(records.size).to eq(2)
    end

    it "yields a record with parsed mail content" do
      records = read_all(StringIO.new(two_message_mbox))

      expect(records[0].mail.from).to eq(["alice@example.com"])
      expect(records[0].mail.to).to eq(["bob@example.com"])
      expect(records[0].mail.subject).to eq("First")
      expect(records[1].mail.subject).to eq("Second")
    end

    it "removes exactly one quoting marker per mboxrd quoted From line" do
      record = read_all(StringIO.new(two_message_mbox)).first
      body = record.mail.body.raw_source

      expect(body).to include("From (quoted) keeps one >\r\n")
      expect(body).to include(">From (double quoted) keeps two >\r\n")
      expect(body).to include(">>From (triple quoted) keeps three >\r\n")
    end

    it "leaves other lines starting with > untouched" do
      record = read_all(StringIO.new(two_message_mbox)).first
      expect(record.mail.body.raw_source).to include("> this is not a quoted separator\r\n")
    end

    it "unquotes a quoted separator at the start of a body line" do
      record = read_all(StringIO.new(two_message_mbox)).first
      expect(record.mail.body.raw_source).to include("From in the middle of a body line stays\r\n")
    end

    it "leaves From not at the start of a line untouched" do
      record = read_all(StringIO.new(two_message_mbox)).first
      expect(record.mail.body.raw_source).to include("leading text From later stays\r\n")
    end

    it "does not turn the envelope line into an RFC header" do
      record = read_all(StringIO.new(two_message_mbox)).first
      expect(record.mail.header["Envelope-From"]).to be_nil
      expect(record.mail.from).to eq(["alice@example.com"])
      expect(record.raw_source).not_to start_with("From ")
    end

    it "accepts mixed LF and CRLF line endings" do
      records = read_all(StringIO.new(two_message_mbox))
      expect(records[0].raw_source).to end_with("\r\n")
      expect(records[1].raw_source).to end_with("\n")
      expect(records[1].mail.body.raw_source).to eq("Plain LF body\n")
    end

    it "handles a message with no body" do
      mbox = envelope("x@example.com") + "From: a@example.com\r\nSubject: headers only\r\n\r\n"
      record = read_all(StringIO.new(mbox)).first

      expect(record).to be_complete
      expect(record.mail.subject).to eq("headers only")
      expect(record.mail.body.to_s).to eq("")
    end

    it "handles an empty archive" do
      expect(read_all(StringIO.new(""))).to eq([])
    end

    it "tolerates leading blank lines" do
      mbox = "\n\r\n" + two_message_mbox
      expect(read_all(StringIO.new(mbox)).size).to eq(2)
    end

    it "flags an unterminated final message as incomplete without inventing an ending" do
      complete_part = two_message_mbox
      truncated = complete_part + "From last@example.com Wed May  4 18:09:07 2005\n" \
                                  "From: last@example.com\nSubject: cut off\n\npartial"
      records = read_all(StringIO.new(truncated))

      expect(records.size).to eq(3)
      expect(records.last).not_to be_complete
      expect(records.last.mail.subject).to eq("cut off")
      expect(records.last.mail.body.raw_source).to eq("partial")
      expect(records.last.raw_source).not_to end_with("\n")
    end

    it "marks a properly terminated final message complete" do
      mbox = envelope("x@example.com") + "Subject: ok\r\n\r\nbody\r\n"
      expect(read_all(StringIO.new(mbox)).first).to be_complete
    end

    it "unquotes separators carried in CRLF lines" do
      mbox = envelope("x@example.com") +
             "Subject: ok\r\n\r\n>From quoted CRLF\r\n>>From double CRLF\r\n"
      record = read_all(StringIO.new(mbox)).first
      expect(record.mail.body.raw_source).to eq("From quoted CRLF\r\n>From double CRLF\r\n")
    end

    it "round-trips all messages with exact offsets and content" do
      mbox = two_message_mbox
      records = read_all(StringIO.new(mbox))

      rebuilt = records.map { |record|
        mbox.byteslice(record.start_offset, record.end_offset - record.start_offset)
      }.join

      expect(rebuilt).to eq(mbox)
      expect(records.size).to eq(2)
      expect(records[0].mail.body.raw_source).to include("Hello.\r\n")
      expect(records[1].mail.subject).to eq("Second")
    end
  end

  describe "envelope metadata" do
    it "exposes the envelope sender and date separately from headers" do
      record = read_all(StringIO.new(two_message_mbox)).first

      expect(record.envelope_from).to eq("mda@example.com")
      expect(record.envelope_date).to eq(::DateTime.parse("Mon May  2 16:07:05 2005"))
      expect(record.envelope_line).to eq("mda@example.com Mon May  2 16:07:05 2005")
    end

    it "allows an envelope without a date" do
      mbox = "From mda@example.com\nSubject: x\r\n\r\nbody\r\n"
      record = read_all(StringIO.new(mbox)).first
      expect(record.envelope_from).to eq("mda@example.com")
      expect(record.envelope_date).to be_nil
    end

    it "keeps unparseable envelope text available but does not crash" do
      mbox = "From not an address or date!!\nSubject: x\r\n\r\nbody\r\n"
      record = read_all(StringIO.new(mbox)).first
      expect(record.envelope_line).to eq("not an address or date!!")
      expect(record.envelope_from).to be_nil
      expect(record.mail.subject).to eq("x")
    end
  end

  describe "offsets" do
    it "reports the start and end byte offsets of every message" do
      mbox = two_message_mbox
      records = read_all(StringIO.new(mbox))

      expect(records[0].start_offset).to eq(0)
      expect(mbox.byteslice(records[0].start_offset, 5)).to eq("From ")
      expect(records[1].start_offset).to eq(records[0].end_offset)
      expect(mbox.byteslice(records[1].start_offset, 5)).to eq("From ")
      expect(records.last.end_offset).to eq(mbox.bytesize)

      slices = records.map { |r| mbox.byteslice(r.start_offset, r.end_offset - r.start_offset) }
      expect(slices.first).to start_with("From mda@example.com")
      expect(slices.join).to eq(mbox)
    end

    it "assigns sequential indexes" do
      records = read_all(StringIO.new(two_message_mbox))
      expect(records.map(&:index)).to eq([0, 1])
    end
  end

  describe "size limit" do
    def oversized_archive
      first = envelope("small@example.com") + "Subject: small\r\n\r\nok\r\n"
      big_body = "x" * 200 + "\r\n"
      big = envelope("big@example.com") +
            "Subject: big\r\n\r\n" + big_body
      third = envelope("third@example.com") + "Subject: third\r\n\r\nfine\r\n"
      first + big + third
    end

    it "raises MessageTooLarge with precise offsets and limit metadata" do
      mbox = oversized_archive
      errors = []
      records = []
      reader = Mail::Mbox.new(StringIO.new(mbox), max_message_size: 100)

      loop do
        reader.each { |record| records << record }
        break
      rescue Mail::Mbox::MessageTooLarge => error
        errors << error
        retry
      end

      expect(records.map(&:index)).to eq([0, 2])
      expect(errors.size).to eq(1)
      error = errors.first
      expect(error.index).to eq(1)
      expect(error.limit).to eq(100)
      expect(error.bytesize).to be > 100
      expect(error.envelope_from).to eq("big@example.com")
      expect(mbox.byteslice(error.start_offset, 5)).to eq("From ")
      expect(error.start_offset).to eq(records.first.end_offset)
      expect(error.end_offset).to eq(records.last.start_offset)
    end

    it "reports end of input when the oversized message is the last one" do
      mbox = envelope("big@example.com") + "Subject: big\r\n\r\n" + ("z" * 150)
      error = nil
      reader = Mail::Mbox.new(StringIO.new(mbox), max_message_size: 50)
      begin
        reader.each.to_a
      rescue Mail::Mbox::MessageTooLarge => e
        error = e
      end
      expect(error.end_offset).to eq(mbox.bytesize)
    end

    it "supports a :skip continuation callback" do
      skipped = []
      records = Mail::Mbox.new(
        StringIO.new(oversized_archive),
        max_message_size: 100,
        on_message_too_large: ->(error) { skipped << error.index; :skip },
      ).each.to_a

      expect(skipped).to eq([1])
      expect(records.map(&:index)).to eq([0, 2])
    end

    it "supports a :stop continuation callback" do
      seen = []
      Mail::Mbox.new(
        StringIO.new(oversized_archive),
        max_message_size: 100,
        on_message_too_large: ->(_) { :stop },
      ).each { |record| seen << record.index }

      expect(seen).to eq([0])
    end

    it "rejects invalid continuation return values" do
      reader = Mail::Mbox.new(
        StringIO.new(oversized_archive),
        max_message_size: 100,
        on_message_too_large: ->(_) { :nope },
      )
      expect { reader.each.to_a }.to raise_error(ArgumentError)
    end

    it "rejects non-positive limits" do
      expect { Mail::Mbox.new(StringIO.new(""), max_message_size: 0) }.to raise_error(ArgumentError)
    end
  end

  describe "streaming" do
    it "accepts a String archive directly" do
      records = Mail::Mbox.new(two_message_mbox).each.to_a
      expect(records.size).to eq(2)
    end

    it "works with an IO that only implements gets (non-seekable)" do
      pipe = Class.new do
        def initialize(string)
          @io = StringIO.new(string)
        end

        def gets(*args)
          @io.gets(*args)
        end
      end.new(two_message_mbox)

      expect(read_all(pipe).size).to eq(2)
    end

    it "does not close an IO it does not own, including on early exit" do
      io = StringIO.new(two_message_mbox)
      allow(io).to receive(:close).and_call_original
      Mail::Mbox.new(io).each.first
      expect(io).not_to be_closed
    end

    it "resumes at the next message when the consumer exits early" do
      reader = Mail::Mbox.new(StringIO.new(two_message_mbox))
      first = reader.each.first
      rest = reader.each.to_a

      expect(first.index).to eq(0)
      expect(rest.map(&:index)).to eq([1])
    end

    it "keeps iterating when the block calls next" do
      seen = []
      Mail::Mbox.new(StringIO.new(two_message_mbox)).each do |record|
        next if record.index.zero?
        seen << record.index
      end
      expect(seen).to eq([1])
    end

    it "closes a file opened from a path but leaves the records intact" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "inbox.mbox")
        File.binwrite(path, two_message_mbox)
        records = Mail::Mbox.foreach(path).to_a
        expect(records.size).to eq(2)
        expect(records.first.mail.subject).to eq("First")
      end
    end
  end

  describe "Mail.read_mbox" do
    it "streams records from a string IO" do
      records = Mail.read_mbox(StringIO.new(two_message_mbox)).to_a
      expect(records.map { |r| r.mail.subject }).to eq(["First", "Second"])
    end

    it "supports the size limit options" do
      expect {
        Mail.read_mbox(StringIO.new(envelope("x@x") + ("z" * 50)),
                       max_message_size: 10).each.to_a
      }.to raise_error(Mail::Mbox::MessageTooLarge)
    end
  end

  describe "malformed input" do
    it "raises MalformedMbox with the offset of stray pre-separator content" do
      mbox = "garbage line\n" + two_message_mbox
      expect { read_all(StringIO.new(mbox)) }.to raise_error(Mail::Mbox::MalformedMbox) do |error|
        expect(error.offset).to eq(0)
      end
    end
  end
end
