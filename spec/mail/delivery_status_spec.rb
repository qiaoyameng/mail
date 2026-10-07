# encoding: utf-8
# frozen_string_literal: true
require 'spec_helper'

RSpec.describe Mail::DeliveryStatus do
  def parse(body)
    Mail::DeliveryStatus.new(body.gsub("\n", "\r\n"))
  end

  describe "block separation" do
    let(:status) do
      parse(<<~DSN)
        Reporting-MTA: dns; mail.example.com
        Arrival-Date: Mon, 01 Jan 2024 00:00:00 +0000

        Final-Recipient: rfc822; one@example.com
        Action: failed
        Status: 5.1.1

        Final-Recipient: rfc822; two@example.com
        Action: delayed
        Status: 4.2.2
      DSN
    end

    it "exposes the per-message block separately" do
      expect(status.message_fields['reporting-mta']).to eq 'dns; mail.example.com'
      expect(status.message_fields['arrival-date']).to eq 'Mon, 01 Jan 2024 00:00:00 +0000'
    end

    it "does not leak per-message fields into recipient blocks" do
      expect(status.recipients.first['reporting-mta']).to be_nil
    end

    it "returns one recipient block per recipient, in order" do
      expect(status.recipients.map(&:final_recipient)).to eq [
        'rfc822; one@example.com',
        'rfc822; two@example.com'
      ]
    end

    it "treats every block as a recipient block when there is no per-message block" do
      status = parse(<<~DSN)
        Final-Recipient: rfc822; one@example.com
        Action: failed
        Status: 5.1.1
      DSN

      expect(status.message_fields).to be_empty
      expect(status.recipients.size).to eq 1
    end
  end

  describe "field preservation" do
    it "keeps extension fields and their order inside a block" do
      status = parse(<<~DSN)
        Reporting-MTA: dns; mail.example.com
        X-Postfix-Queue-ID: 9B7841BC027
        X-Custom-Flag: yes

        Final-Recipient: rfc822; one@example.com
        X-Attempt: 1
        Action: failed
        Status: 5.1.1
        X-Remote-Queue: deferred
      DSN

      expect(status.message_fields.field_names).to eq %w[Reporting-MTA X-Postfix-Queue-ID X-Custom-Flag]
      recipient = status.recipients.first
      expect(recipient.field_names).to eq %w[Final-Recipient X-Attempt Action Status X-Remote-Queue]
      expect(recipient['x-attempt']).to eq '1'
      expect(recipient['x-remote-queue']).to eq 'deferred'
    end

    it "unfolds folded header lines" do
      status = parse(<<-DSN)
Reporting-MTA: dns; mail.example.com

Final-Recipient: rfc822; one@example.com
Action: failed
Status: 5.1.1
Diagnostic-Code: smtp; 550-5.1.1 The email account that you tried to
 reach does not exist
      DSN

      expect(status.recipients.first.diagnostic_code).to eq \
        'smtp; 550-5.1.1 The email account that you tried to reach does not exist'
    end

    it "keeps duplicate optional fields in order" do
      status = parse(<<~DSN)
        Reporting-MTA: dns; mail.example.com

        Final-Recipient: rfc822; one@example.com
        Action: failed
        Status: 5.1.1
        Remote-MTA: dns; mx1.example.com
        Remote-MTA: dns; mx2.example.com
      DSN

      recipient = status.recipients.first
      expect(recipient.values('remote-mta')).to eq ['dns; mx1.example.com', 'dns; mx2.example.com']
      expect(recipient.remote_mta).to eq 'dns; mx1.example.com'
    end

    it "distinguishes an empty diagnostic code from a missing one" do
      status = parse(<<~DSN)
        Reporting-MTA: dns; mail.example.com

        Final-Recipient: rfc822; one@example.com
        Action: failed
        Status: 5.1.1
        Diagnostic-Code:

        Final-Recipient: rfc822; two@example.com
        Action: failed
        Status: 5.1.1
      DSN

      expect(status.recipients[0].diagnostic_code).to eq ''
      expect(status.recipients[0].key?('diagnostic-code')).to be true
      expect(status.recipients[1].diagnostic_code).to be_nil
      expect(status.recipients[1].key?('diagnostic-code')).to be false
    end
  end

  describe "per-recipient diagnosis" do
    let(:status) do
      parse(<<~DSN)
        Reporting-MTA: dns; mail.example.com

        Final-Recipient: rfc822; ok@example.com
        Action: delivered
        Status: 2.0.0

        Final-Recipient: rfc822; slow@example.com
        Action: delayed
        Status: 4.2.2

        Final-Recipient: rfc822; gone@example.com
        Action: failed
        Status: 5.1.1
      DSN
    end

    it "reports action, status, final recipient and diagnostic code per recipient" do
      expect(status.recipients.map(&:action)).to eq %w[delivered delayed failed]
      expect(status.recipients.map(&:status)).to eq %w[2.0.0 4.2.2 5.1.1]
      expect(status.recipients.map(&:final_recipient)).to eq [
        'rfc822; ok@example.com',
        'rfc822; slow@example.com',
        'rfc822; gone@example.com'
      ]
    end

    it "judges retryability per recipient" do
      expect(status.recipients.map(&:retryable?)).to eq [false, true, false]
    end

    it "judges bounced per recipient" do
      expect(status.recipients.map(&:bounced?)).to eq [false, false, true]
    end
  end

  describe "missing or malformed fields" do
    it "does not borrow fields from the next block when one is incomplete" do
      status = parse(<<~DSN)
        Reporting-MTA: dns; mail.example.com

        Final-Recipient: rfc822; one@example.com
        Action: failed
        Status: 5.1.1

        Final-Recipient: rfc822; two@example.com
        Action: failed
        Status: 5.4.4
        Diagnostic-Code: smtp; 554 no route
      DSN

      expect(status.recipients[0].diagnostic_code).to be_nil
      expect(status.recipients[1].diagnostic_code).to eq 'smtp; 554 no route'
    end

    it "fails diagnosis only for the block with a missing status" do
      status = parse(<<~DSN)
        Reporting-MTA: dns; mail.example.com

        Final-Recipient: rfc822; one@example.com
        Action: failed

        Final-Recipient: rfc822; two@example.com
        Action: delayed
        Status: 4.2.2
      DSN

      expect(status.recipients[0].status).to be_nil
      expect(status.recipients[0].valid_status?).to be false
      expect(status.recipients[0].retryable?).to be_nil
      expect(status.recipients[1].retryable?).to be true
    end

    it "fails diagnosis only for the block with a malformed status" do
      status = parse(<<~DSN)
        Reporting-MTA: dns; mail.example.com

        Final-Recipient: rfc822; one@example.com
        Action: failed
        Status: not-a-status

        Final-Recipient: rfc822; two@example.com
        Action: failed
        Status: 5.1.1
      DSN

      expect(status.recipients[0].valid_status?).to be false
      expect(status.recipients[0].retryable?).to be_nil
      expect(status.recipients[1].valid_status?).to be true
      expect(status.recipients[1].retryable?).to be false
    end
  end
end
