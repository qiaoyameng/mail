# encoding: utf-8
# frozen_string_literal: true
require 'spec_helper'

RSpec.describe Mail::DeliveryStatus do

  def crlf(text)
    text.gsub(/\r?\n/, "\r\n")
  end

  # A multipart/report with four recipients: one delivered, one delayed,
  # one failed without a Diagnostic-Code and one failed with an empty
  # Diagnostic-Code.
  let(:four_recipient_report) do
    Mail.new(crlf(<<~REPORT))
      From: MAILER-DAEMON@mail.example.com
      To: sender@example.com
      Subject: Delivery Status Notification
      MIME-Version: 1.0
      Content-Type: multipart/report; report-type=delivery-status;
      	boundary="dsn-boundary"

      --dsn-boundary
      Content-Type: text/plain

      This is the mail system at host mail.example.com.

      --dsn-boundary
      Content-Type: message/delivery-status

      Reporting-MTA: dns; mail.example.com
      X-Postfix-Queue-ID: 4C7D1
      Arrival-Date: Tue, 23 Feb 2010 22:16:15 -0800 (PST)

      Final-Recipient: rfc822; delivered@example.com
      Action: delivered
      Status: 2.0.0
      Remote-MTA: dns; mx.example.com
      Diagnostic-Code: smtp; 250 2.0.0 Ok: queued as
          4C7D1ABC123

      Final-Recipient: rfc822; delayed@example.com
      Action: delayed
      Status: 4.2.2
      Diagnostic-Code: smtp; 452 4.2.2 Mailbox full
      X-Retry-Count: 3
      X-Retry-Count: 5

      Final-Recipient: rfc822; unknown@example.com
      Action: failed
      Status: 5.1.1
      Remote-MTA: dns; mx.example.com

      Final-Recipient: rfc822; rejected@example.com
      Action: failed
      Status: 5.3.0
      Diagnostic-Code:

      --dsn-boundary--
    REPORT
  end

  let(:status) { four_recipient_report.delivery_status }

  it "is exposed on the message and on the delivery status part" do
    expect(four_recipient_report.delivery_status).to be_a Mail::DeliveryStatus
    expect(four_recipient_report.delivery_status_part.delivery_status).to be_a Mail::DeliveryStatus
  end

  it "is nil for messages without a delivery status report" do
    expect(Mail.new.delivery_status).to be_nil
    expect(Mail::Part.new.delivery_status).to be_nil
  end

  describe "per-message block" do
    it "keeps the report wide fields out of the recipient blocks" do
      expect(status.message_block.reporting_mta).to eq 'dns; mail.example.com'
      expect(status.message_block.arrival_date).to eq 'Tue, 23 Feb 2010 22:16:15 -0800 (PST)'
      expect(status.recipient_blocks.first['reporting-mta']).to be_nil
    end

    it "preserves extension fields and their order" do
      expect(status.message_block['x-postfix-queue-id']).to eq '4C7D1'
      expect(status.message_block.fields.map(&:name)).to eq %w(Reporting-MTA X-Postfix-Queue-ID Arrival-Date)
    end
  end

  describe "recipient blocks" do
    it "returns one block per recipient, in order" do
      expect(status.recipient_blocks.length).to eq 4
      expect(status.recipient_blocks.map(&:final_recipient)).to eq [
        'rfc822; delivered@example.com',
        'rfc822; delayed@example.com',
        'rfc822; unknown@example.com',
        'rfc822; rejected@example.com'
      ]
    end

    it "exposes action, status and diagnostic code per recipient" do
      expect(status.recipient_blocks.map(&:action)).to eq %w(delivered delayed failed failed)
      expect(status.recipient_blocks.map(&:status)).to eq %w(2.0.0 4.2.2 5.1.1 5.3.0)
    end

    it "judges retryability per recipient across success, transient and permanent failures" do
      expect(status.recipient_blocks.map(&:retryable?)).to eq [false, true, false, false]
    end

    it "unfolds folded field values" do
      expect(status.recipient_blocks[0].diagnostic_code).to match(/\Asmtp; 250 2\.0\.0 Ok: queued as\s+4C7D1ABC123\z/)
    end

    it "keeps repeated optional fields together in their block" do
      delayed = status.recipient_blocks[1]
      expect(delayed['x-retry-count']).to eq '3'
      expect(delayed.values('x-retry-count')).to eq %w(3 5)
      expect(delayed.fields.map(&:name)).to eq %w(Final-Recipient Action Status Diagnostic-Code X-Retry-Count X-Retry-Count)
    end

    it "does not borrow a diagnostic code from a neighbouring block when it is missing" do
      unknown, rejected = status.recipient_blocks[2], status.recipient_blocks[3]
      expect(unknown.diagnostic_code).to be_nil
      expect(unknown.status).to eq '5.1.1'
      expect(unknown.remote_mta).to eq 'dns; mx.example.com'
    end

    it "treats an empty diagnostic code as missing without shifting later blocks" do
      rejected = status.recipient_blocks[3]
      expect(rejected.key?('diagnostic-code')).to be true
      expect(rejected.diagnostic_code).to be_nil
      expect(rejected.final_recipient).to eq 'rfc822; rejected@example.com'
      expect(rejected.status).to eq '5.3.0'
      expect(rejected.retryable?).to be false
    end
  end

  describe "bad or missing status codes" do
    let(:report) do
      Mail.new(crlf(<<~REPORT))
        Content-Type: multipart/report; report-type=delivery-status;
        	boundary="dsn-boundary"

        --dsn-boundary
        Content-Type: message/delivery-status

        Reporting-MTA: dns; mail.example.com

        Final-Recipient: rfc822; broken@example.com
        Action: failed
        Status: not-a-status

        Final-Recipient: rfc822; nostatus@example.com
        Action: failed

        Final-Recipient: rfc822; fine@example.com
        Action: failed
        Status: 5.1.1

        --dsn-boundary--
      REPORT
    end

    it "only fails the diagnosis of the offending block" do
      broken, nostatus, fine = report.delivery_status.recipient_blocks

      expect(broken.valid_status?).to be false
      expect(broken.retryable?).to be_nil
      expect(broken.status).to eq 'not-a-status'

      expect(nostatus.valid_status?).to be false
      expect(nostatus.retryable?).to be_nil
      expect(nostatus.status).to be_nil

      expect(fine.valid_status?).to be true
      expect(fine.retryable?).to be false
      expect(fine.status).to eq '5.1.1'
    end
  end

  describe "single value convenience methods" do
    it "still work for a single recipient report" do
      mail = read_fixture('emails', 'multipart_report_emails', 'report_422.eml')
      expect(mail.action).to eq 'delayed'
      expect(mail.error_status).to eq '4.2.2'
      expect(mail.final_recipient).to eq 'RFC822; fraser@oooooooo.com.au'
      expect(mail.diagnostic_code).to eq 'SMTP; 452 4.2.2 <fraser@oooooooo.com.au>... Mailbox full'
      expect(mail).to be_retryable
    end

    it "return arrays in recipient order for multiple recipients" do
      expect(four_recipient_report.action).to eq %w(delivered delayed failed failed)
      expect(four_recipient_report.error_status).to eq %w(2.0.0 4.2.2 5.1.1 5.3.0)
      expect(four_recipient_report.final_recipient).to eq [
        'rfc822; delivered@example.com',
        'rfc822; delayed@example.com',
        'rfc822; unknown@example.com',
        'rfc822; rejected@example.com'
      ]
    end

    it "keeps the legacy bounced? semantics of judging only the first recipient" do
      # The first recipient was delivered, so the flattened report is not
      # considered bounced even though later recipients failed. Use
      # delivery_status.recipient_blocks for per-recipient results.
      expect(four_recipient_report).not_to be_bounced
      expect(four_recipient_report.delivery_status.recipient_blocks.map(&:action)).to include('failed')

      mail = read_fixture('emails', 'multipart_report_emails', 'multi_address_bounce1.eml')
      expect(mail).to be_bounced
    end
  end
end
