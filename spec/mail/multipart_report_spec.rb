# encoding: utf-8
# frozen_string_literal: true
require 'spec_helper'

RSpec.describe "multipart/report emails" do
  
  it "should know if it is a multipart report type" do
    mail = read_fixture('emails', 'multipart_report_emails', 'report_422.eml')
    expect(mail).to be_multipart_report
  end

  describe "delivery-status reports" do

    it "should know if it is a deliver-status report" do
      mail = read_fixture('emails', 'multipart_report_emails', 'report_422.eml')
      expect(mail).to be_delivery_status_report
    end

    it "should find its message/delivery-status part" do
      mail = read_fixture('emails', 'multipart_report_emails', 'report_422.eml')
      expect(mail.delivery_status_part).not_to be_nil
    end

    it "should handle a report that has a human readable message/delivery-status" do
      mail = read_fixture('emails', 'multipart_report_emails', 'multipart_report_multiple_status.eml')
      expect(mail).to be_bounced
    end

    describe "delivery-status part in a non report email" do
      let(:mail){
        string = read_raw_fixture('emails', 'multipart_report_emails', 'report_422.eml')
        Mail.read_from_string(string.sub("multipart/report; report-type=delivery-status;", "multipart/mixed;"))
      }

      it "does not return a delivery_status_part" do
        expect(mail.delivery_status_part).to be_nil
      end
    end

    describe "multipart reports with more than one address" do
      it "should not crash" do
        mail1 = read_fixture('emails', 'multipart_report_emails', 'multi_address_bounce1.eml')
        mail2 = read_fixture('emails', 'multipart_report_emails', 'multi_address_bounce2.eml')
        expect { mail1.bounced? }.not_to raise_error
        expect { mail2.bounced? }.not_to raise_error
      end

      it "should not know that a multi address email was bounced" do
        mail1 = read_fixture('emails', 'multipart_report_emails', 'multi_address_bounce1.eml')
        mail2 = read_fixture('emails', 'multipart_report_emails', 'multi_address_bounce2.eml')
        expect(mail1).to be_bounced
        expect(mail2).to be_bounced
      end
    end

    describe "temporary failure" do

      before(:each) do
        @mail = read_fixture('emails', 'multipart_report_emails', 'report_422.eml')
      end

      it "should be bounced" do
        expect(@mail).not_to be_bounced
      end

      it "should say action 'delayed'" do
        expect(@mail.action).to eq 'delayed'
      end

      it "should give a final recipient" do
        expect(@mail.final_recipient).to eq 'RFC822; fraser@oooooooo.com.au'
      end

      it "should give an error code" do
        expect(@mail.error_status).to eq '4.2.2'
      end

      it "should give a diagostic code" do
        expect(@mail.diagnostic_code).to eq 'SMTP; 452 4.2.2 <fraser@oooooooo.com.au>... Mailbox full'
      end

      it "should give a remote-mta" do
        expect(@mail.remote_mta).to eq 'DNS; mail.oooooooo.com.au'
      end

      it "should be retryable" do
        expect(@mail).to be_retryable
      end
    end

    describe "permanent failure" do

      before(:each) do
        @mail = read_fixture('emails', 'multipart_report_emails', 'report_530.eml')
      end

      it "should be bounced" do
        expect(@mail).to be_bounced
      end

      it "should say action 'failed'" do
        expect(@mail.action).to eq 'failed'
      end

      it "should give a final recipient" do
        expect(@mail.final_recipient).to eq 'RFC822; edwin@zzzzzzz.com'
      end

      it "should give an error code" do
        expect(@mail.error_status).to eq '5.3.0'
      end

      it "should give a diagostic code" do
        expect(@mail.diagnostic_code).to eq 'SMTP; 553 5.3.0 <edwin@zzzzzzz.com>... Unknown E-Mail Address'
      end

      it "should give a remote-mta" do
        expect(@mail.remote_mta).to eq 'DNS; mail.zzzzzz.com'
      end

      it "should be retryable" do
        expect(@mail).not_to be_retryable
      end
    end

    describe "structured delivery status with multiple recipients" do
      let(:mail) do
        Mail.read_from_string(<<-EMAIL.gsub("\n", "\r\n"))
From: postmaster@example.com
To: sender@example.net
Subject: Delivery Status Notification
MIME-Version: 1.0
Content-Type: multipart/report; report-type=delivery-status; boundary="dsn-boundary"

--dsn-boundary
Content-Type: text/plain

This is a delivery status notification.

--dsn-boundary
Content-Type: message/delivery-status

Reporting-MTA: dns; mail.example.com
X-Postfix-Queue-ID: ABC123
Arrival-Date: Mon, 01 Jan 2024 00:00:00 +0000

Final-Recipient: rfc822; delivered@example.com
Action: delivered
Status: 2.0.0
Diagnostic-Code: smtp; 250 2.0.0 Ok

Final-Recipient: rfc822; delayed@example.com
Action: delayed
Status: 4.2.2
Remote-MTA: dns; mx1.example.com
Remote-MTA: dns; mx2.example.com
Diagnostic-Code: smtp; 452 4.2.2 Mailbox full

Final-Recipient: rfc822; failed@example.com
Action: failed
Status: 5.1.1

Final-Recipient: rfc822; broken@example.com
Action: failed
Status: garbage
Diagnostic-Code:

--dsn-boundary--
        EMAIL
      end

      let(:recipients) { mail.delivery_status.recipients }

      it "exposes the per-message block with its extension fields" do
        message_fields = mail.delivery_status.message_fields
        expect(message_fields['reporting-mta']).to eq 'dns; mail.example.com'
        expect(message_fields['x-postfix-queue-id']).to eq 'ABC123'
        expect(message_fields.field_names).to eq %w[Reporting-MTA X-Postfix-Queue-ID Arrival-Date]
      end

      it "returns one block per recipient, in order" do
        expect(recipients.map(&:final_recipient)).to eq [
          'rfc822; delivered@example.com',
          'rfc822; delayed@example.com',
          'rfc822; failed@example.com',
          'rfc822; broken@example.com'
        ]
        expect(recipients.map(&:action)).to eq %w[delivered delayed failed failed]
        expect(recipients.map(&:status)).to eq %w[2.0.0 4.2.2 5.1.1 garbage]
      end

      it "judges retryability per recipient, nil for the malformed status" do
        expect(recipients.map(&:retryable?)).to eq [false, true, false, nil]
      end

      it "keeps a missing diagnostic-code local to its own block" do
        expect(recipients[2].diagnostic_code).to be_nil
        expect(recipients[3].diagnostic_code).to eq ''
        expect(recipients[0].diagnostic_code).to eq 'smtp; 250 2.0.0 Ok'
        expect(recipients[1].diagnostic_code).to eq 'smtp; 452 4.2.2 Mailbox full'
      end

      it "keeps duplicate optional fields in order within their block" do
        expect(recipients[1].values('remote-mta')).to eq ['dns; mx1.example.com', 'dns; mx2.example.com']
        expect(recipients[0].values('remote-mta')).to eq []
      end

      it "keeps the legacy single-value and multi-value accessors working" do
        expect(mail.action).to eq %w[delivered delayed failed failed]
        expect(mail.error_status).to eq %w[2.0.0 4.2.2 5.1.1 garbage]
        expect(mail.final_recipient).to eq [
          'rfc822; delivered@example.com',
          'rfc822; delayed@example.com',
          'rfc822; failed@example.com',
          'rfc822; broken@example.com'
        ]
      end
    end

  end

end
