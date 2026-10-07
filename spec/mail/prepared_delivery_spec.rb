# encoding: utf-8
# frozen_string_literal: true
require 'spec_helper'

RSpec.describe Mail::PreparedDelivery do

  def build_mail
    Mail.new do
      to      'you@test.lindsaar.net'
      from    'mikel@test.lindsaar.net'
      bcc     'hidden@test.lindsaar.net'
      subject 'snapshot test'
      body    'hello there'
    end
  end

  def build_multipart_mail
    mail = build_mail
    mail.add_file :filename => 'test.txt', :content => 'attachment bytes'
    mail
  end

  describe "preparing a delivery" do
    it "returns an immutable snapshot of the envelope and encoded message" do
      snapshot = build_mail.prepare_delivery

      expect(snapshot).to be_frozen
      expect(snapshot.envelope_from).to eq 'mikel@test.lindsaar.net'
      expect(snapshot.envelope_to).to eq ['you@test.lindsaar.net', 'hidden@test.lindsaar.net']
      expect(snapshot.message).to be_frozen
      expect(snapshot.envelope_to).to be_frozen
      expect(snapshot.envelope_to.all?(&:frozen?)).to be_truthy
      expect(snapshot.to_s).to eq snapshot.message
    end

    it "keeps Bcc recipients in the envelope but out of the visible headers" do
      snapshot = build_mail.prepare_delivery

      expect(snapshot.envelope_to).to include('hidden@test.lindsaar.net')
      expect(snapshot.message).not_to include('hidden@test.lindsaar.net')
      expect(snapshot.message).not_to match(/^Bcc:/i)
    end

    it "fixes auto generated Date, Message-ID, MIME boundary and transfer encoding on first prepare" do
      mail = build_multipart_mail
      expect(mail.has_date?).to be_falsey
      expect(mail.has_message_id?).to be_falsey
      expect(mail.has_content_transfer_encoding?).to be_falsey

      snapshot = mail.prepare_delivery

      expect(mail.has_date?).to be_truthy
      expect(mail.has_message_id?).to be_truthy
      expect(mail.has_content_transfer_encoding?).to be_truthy
      expect(mail.body.boundary).not_to be_nil

      expect(snapshot.message).to include(mail[:date].value)
      expect(snapshot.message).to include(mail[:message_id].value)
      expect(snapshot.message).to include(mail.body.boundary)
    end

    it "produces byte identical snapshots on repeated prepares of an unchanged message" do
      mail = build_multipart_mail
      first = mail.prepare_delivery
      second = mail.prepare_delivery

      expect(second.message).to eq first.message
      expect(second.digest).to eq first.digest
      expect(second).to eq first
    end

    it "lets the original message encode to the same bytes after preparing" do
      mail = build_multipart_mail
      snapshot = mail.prepare_delivery
      expect(mail.encoded).to eq snapshot.message
    end

    it "is not affected by later changes to the message, attachments or address arrays" do
      mail = build_multipart_mail
      snapshot = mail.prepare_delivery
      digest = snapshot.digest

      mail.subject = 'changed subject'
      mail.body = 'changed body'
      mail.to << 'extra@test.lindsaar.net'
      mail.attachments['test.txt'].body = 'changed attachment'

      expect(snapshot.message).not_to include('changed')
      expect(snapshot.envelope_to).to eq ['you@test.lindsaar.net', 'hidden@test.lindsaar.net']
      expect(snapshot.digest).to eq digest
    end

    it "only picks up new content when prepare_delivery is called again" do
      mail = build_mail
      first = mail.prepare_delivery

      mail.subject = 'a brand new subject'
      second = mail.prepare_delivery

      expect(first.message).not_to include('a brand new subject')
      expect(second.message).to include('a brand new subject')
      expect(second.digest).not_to eq first.digest
    end

    it "leaves the original message untouched when preparation fails" do
      mail = Mail.new { to 'you@test.lindsaar.net'; subject 'no from' }
      fields_before = mail.header.fields.map(&:name)

      expect { mail.prepare_delivery }.to raise_error(ArgumentError)
      expect(mail.header.fields.map(&:name)).to eq fields_before
      expect(mail.has_date?).to be_falsey
      expect(mail.has_message_id?).to be_falsey
      expect(mail.has_content_transfer_encoding?).to be_falsey
    end

    it "does not call encoders or random generators when the snapshot is read" do
      snapshot = build_multipart_mail.prepare_delivery

      expect(Mail).not_to receive(:random_tag)
      expect(Mail::Encodings).not_to receive(:decode_encode)
      expect_any_instance_of(Mail::Message).not_to receive(:ready_to_send!)

      snapshot.envelope_from
      snapshot.envelope_to
      snapshot.message
      snapshot.digest
      snapshot.bytesize
      snapshot.to_s
      snapshot.dump
    end

    it "keeps the digest stable across repeated prepares even as a counting clock advances" do
      clock = 0
      allow(DateTime).to receive(:now) do
        clock += 1
        DateTime.new(2026, 10, 7, 12, 0, clock, '+08:00')
      end

      mail = build_multipart_mail
      first = mail.prepare_delivery
      second = mail.prepare_delivery

      expect(clock).to eq 1
      expect(second.digest).to eq first.digest
      expect(second.message).to eq first.message
    end

    it "produces matching digests for identical messages with a fixed clock and random source" do
      fixed_time = DateTime.new(2026, 10, 7, 12, 0, 0, '+08:00')
      allow(DateTime).to receive(:now).and_return(fixed_time)
      allow(Mail).to receive(:random_tag).and_return('fixedrandomtag')

      first = build_multipart_mail.prepare_delivery
      second = build_multipart_mail.prepare_delivery

      expect(first.digest).to eq second.digest
      expect(first.message).to eq second.message
    end
  end

  describe "serialization" do
    it "round trips through dump and restore" do
      snapshot = build_multipart_mail.prepare_delivery
      restored = Mail::PreparedDelivery.restore(snapshot.dump)

      expect(restored).to eq snapshot
      expect(restored.digest).to eq snapshot.digest
      expect(restored).to be_frozen
    end

    it "does not deserialize arbitrary Ruby objects" do
      snapshot = build_mail.prepare_delivery
      expect { Mail::PreparedDelivery.restore(Marshal.dump(snapshot)) }.to raise_error(Mail::PreparedDelivery::RestoreError)
      expect { Mail::PreparedDelivery.restore(snapshot.message.to_yaml) }.to raise_error(Mail::PreparedDelivery::RestoreError)
    end

    it "rejects payloads that are not strings" do
      expect { Mail::PreparedDelivery.restore(nil) }.to raise_error(Mail::PreparedDelivery::RestoreError)
      expect { Mail::PreparedDelivery.restore(42) }.to raise_error(Mail::PreparedDelivery::RestoreError)
    end

    it "rejects payloads that are not JSON objects in the expected format" do
      expect { Mail::PreparedDelivery.restore('not json at all') }.to raise_error(Mail::PreparedDelivery::RestoreError)
      expect { Mail::PreparedDelivery.restore('[1, 2, 3]') }.to raise_error(Mail::PreparedDelivery::RestoreError)
      expect { Mail::PreparedDelivery.restore('{"format":"other"}') }.to raise_error(Mail::PreparedDelivery::RestoreError)
    end

    it "rejects payloads with an unsupported version" do
      payload = JSON.parse(build_mail.prepare_delivery.dump)
      payload['version'] = 999
      expect { Mail::PreparedDelivery.restore(JSON.generate(payload)) }.to raise_error(Mail::PreparedDelivery::RestoreError)
    end

    it "rejects payloads whose component types are wrong" do
      payload = JSON.parse(build_mail.prepare_delivery.dump)
      payload['envelope_to'] = 'you@test.lindsaar.net'
      expect { Mail::PreparedDelivery.restore(JSON.generate(payload)) }.to raise_error(Mail::PreparedDelivery::RestoreError)

      payload = JSON.parse(build_mail.prepare_delivery.dump)
      payload['envelope_to'] = []
      expect { Mail::PreparedDelivery.restore(JSON.generate(payload)) }.to raise_error(Mail::PreparedDelivery::RestoreError)

      payload = JSON.parse(build_mail.prepare_delivery.dump)
      payload['message'] = 12_345
      expect { Mail::PreparedDelivery.restore(JSON.generate(payload)) }.to raise_error(Mail::PreparedDelivery::RestoreError)
    end

    it "rejects payloads whose declared lengths do not match" do
      payload = JSON.parse(build_mail.prepare_delivery.dump)
      payload['lengths']['message'] += 1
      expect { Mail::PreparedDelivery.restore(JSON.generate(payload)) }.to raise_error(Mail::PreparedDelivery::RestoreError)

      payload = JSON.parse(build_mail.prepare_delivery.dump)
      payload.delete('lengths')
      expect { Mail::PreparedDelivery.restore(JSON.generate(payload)) }.to raise_error(Mail::PreparedDelivery::RestoreError)
    end

    it "rejects payloads whose digest does not match the message" do
      payload = JSON.parse(build_mail.prepare_delivery.dump)
      payload['message'] = "#{payload['message']}tampered"
      payload['lengths']['message'] = payload['message'].bytesize
      expect { Mail::PreparedDelivery.restore(JSON.generate(payload)) }.to raise_error(Mail::PreparedDelivery::RestoreError)

      payload = JSON.parse(build_mail.prepare_delivery.dump)
      payload['digest'] = '0' * 64
      expect { Mail::PreparedDelivery.restore(JSON.generate(payload)) }.to raise_error(Mail::PreparedDelivery::RestoreError)
    end
  end
end
