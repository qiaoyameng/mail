# frozen_string_literal: true
require 'spec_helper'

RSpec.describe 'delivery snapshot' do
  after(:each) do
    Mail.defaults do
      delivery_method :smtp, { :address => 'localhost', :port => 25 }
    end
  end

  def freeze_generated_values
    fixed_time = DateTime.parse('2024-02-03 04:05:06 +0000')
    allow(Time).to receive(:now).and_return(Time.at(1_706_913_906, 123_456, :usec))
    allow(DateTime).to receive(:now).and_return(fixed_time)
    allow(Kernel).to receive(:rand).and_call_original
    allow(Kernel).to receive(:rand).with(255).and_return(123)
  end

  def build_mail
    Mail.new do
      from 'sender@example.com'
      to 'visible@example.com'
      cc 'copy@example.com'
      bcc ['blind@example.com', 'other-blind@example.com']
      subject 'Retry bytes'

      add_file :filename => 'hello.txt', :content => 'original attachment'

      text_part do
        body 'original text'
      end

      html_part do
        body '<p>original html</p>'
      end
    end
  end

  it 'freezes generated fields and exact bytes independently of the original message' do
    freeze_generated_values
    mail = build_mail

    snapshot = mail.prepare_delivery
    first_bytes = snapshot.message.dup
    boundary = snapshot.message[/boundary=(.*)\r\n/, 1]
    message_id = snapshot.message[/Message-ID: (.*)\r\n/, 1]
    date = snapshot.message[/Date: (.*)\r\n/, 1]

    mail.subject = 'changed subject'
    mail.to = ['changed@example.com']
    mail.cc = ['changed-copy@example.com']
    mail.bcc = ['changed-blind@example.com']
    mail.from = ['changed-sender@example.com']
    mail.attachments.first.body = 'changed attachment'
    mail.text_part.body = 'changed text'
    mail.html_part.body = '<p>changed html</p>'
    expect { snapshot.to.first << 'mutated@example.com' }.to raise_error(FrozenError)

    expect(snapshot.message).to eq(first_bytes)
    expect(snapshot.message).to include(boundary, message_id, date)
    expect(snapshot.message).not_to include('Bcc:')
    expect(snapshot.to).to eq(%w[
                             visible@example.com
                             copy@example.com
                             blind@example.com
                             other-blind@example.com
                           ])
    expect(snapshot.to).to be_frozen
    expect(snapshot.from).to eq('sender@example.com')
  end

  it 'does not encode or generate values when reading a prepared snapshot' do
    freeze_generated_values
    mail = build_mail
    snapshot = mail.prepare_delivery

    RSpec::Mocks.verify
    allow(DateTime).to receive(:now).and_raise('date generated')
    allow(Time).to receive(:now).and_raise('random source used')
    allow(Kernel).to receive(:rand).and_raise('random source used')

    expect(snapshot.message).to eq(snapshot.message)
    expect(snapshot.encoded).to eq(snapshot.message)
    expect(snapshot.to_s).to eq(snapshot.message)
    expect(snapshot.to).to eq(snapshot.to)
  end

  it 'retries with identical envelope and bytes through delivery methods' do
    freeze_generated_values
    mail = build_mail
    snapshot = mail.prepare_delivery

    Mail.defaults { delivery_method :smtp_connection, :connection => Net::SMTP.start('127.0.0.1', 25) }
    smtp = Mail.delivery_method.smtp
    snapshot.deliver!
    snapshot.deliver!

    first, second = MockSMTP.deliveries
    expect(second).to eq(first)
    expect(first).to eq([
      snapshot.message,
      'sender@example.com',
      %w[visible@example.com copy@example.com blind@example.com other-blind@example.com],
    ])
  ensure
    smtp&.finish
    Mail.defaults do
      delivery_method :smtp, { :address => 'localhost', :port => 25 }
    end
  end

  it 'builds an envelope from frozen prepared values without re-encoding a message' do
    message = 'From: sender@example.com
To: visible@example.com

hello'
    envelope = Mail::SmtpEnvelope.new('sender@example.com', ['visible@example.com'], message)

    expect(envelope.from).to eq('sender@example.com')
    expect(envelope.to).to eq(['visible@example.com'])
    expect(envelope.message).to eq(message)
    expect(envelope.message).to be_frozen
  end

  it 'saves and restores validated bytes without deserializing Ruby objects' do
    freeze_generated_values
    snapshot = build_mail.prepare_delivery

    restored = Mail::PreparedDelivery.restore(snapshot.save)
    expect(Mail::DeliverySnapshot.restore(snapshot.dump)).to eq(restored)

    expect(restored).to be_a(Mail::PreparedDelivery)
    expect(restored.from).to eq(snapshot.from)
    expect(restored.to).to eq(snapshot.to)
    expect(restored.message).to eq(snapshot.message)
    expect(restored.message).to be_frozen

    data = JSON.parse(snapshot.save)
    data['message_length'] = data['message_length'] + 1
    expect { Mail::PreparedDelivery.restore(JSON.dump(data)) }.to raise_error(ArgumentError)

    data = JSON.parse(snapshot.save)
    data['format'] = 'Marshal'
    expect { Mail::PreparedDelivery.restore(JSON.dump(data)) }.to raise_error(ArgumentError)

    data = JSON.parse(snapshot.save)
    data['to'] << 123
    expect { Mail::PreparedDelivery.restore(JSON.dump(data)) }.to raise_error(ArgumentError)
  end

  it 'prepares again only when explicitly requested' do
    freeze_generated_values
    mail = build_mail
    first = mail.prepare_delivery

    mail.subject = 'new subject'

    expect(mail.prepare_delivery.message).not_to eq(first.message)
    expect(first.message).to include('Subject: Retry bytes')
  end

  it 'does not mutate the original message when preparation fails' do
    freeze_generated_values
    mail = Mail.new(:from => 'sender@example.com', :subject => 'invalid body', :body => 'hello')

    allow_any_instance_of(Mail::Body).to receive(:encoded).and_raise(Encoding::UndefinedConversionError)

    expect { mail.prepare_delivery }.to raise_error(Encoding::UndefinedConversionError)
    expect(mail).not_to have_date
    expect(mail).not_to have_message_id
    expect(mail).not_to have_mime_version
    expect(mail.content_transfer_encoding).to be_nil
    expect(mail.subject).to eq('invalid body')
  end
end
