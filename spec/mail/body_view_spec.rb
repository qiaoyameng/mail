# encoding: utf-8
# frozen_string_literal: true

require "spec_helper"

RSpec.describe Mail::BodyView do
  def mail_for(raw)
    Mail.new(raw.gsub("\n", "\r\n"))
  end

  let(:alternative_mail) do
    mail_for(<<~MAIL)
      Content-Type: multipart/alternative; boundary=alt

      --alt
      Content-Type: text/plain

      plain body
      --alt
      Content-Type: text/html

      <b>html body</b>
      --alt--
    MAIL
  end

  describe "body selection" do
    it "selects the message itself for a single part text mail" do
      mail = mail_for("Content-Type: text/plain\n\nhello")
      view = described_class.select(mail)
      expect(view.status).to eq :ok
      expect(view).to be_ok
      expect(view.part).to eq mail
      expect(view.path).to eq []
      expect(view.mime_path).to eq %w[text/plain]
      expect(view.resources).to eq({})
    end

    it "treats a missing Content-Type as text/plain" do
      mail = mail_for("Subject: hi\n\nhello")
      view = described_class.select(mail)
      expect(view).to be_ok
      expect(view.part).to eq mail
      expect(view.mime_path).to eq %w[text/plain]
    end

    it "prefers text/html over text/plain by default" do
      view = described_class.select(alternative_mail)
      expect(view.part).to eq alternative_mail.parts[1]
      expect(view.path).to eq [1]
      expect(view.mime_path).to eq %w[multipart/alternative text/html]
    end

    it "honours an explicit preference order" do
      view = described_class.select(alternative_mail, prefer: %w[text/plain text/html])
      expect(view.part).to eq alternative_mail.parts[0]
      expect(view.path).to eq [0]
    end

    it "uses the supported order as the default preference" do
      view = described_class.select(alternative_mail, supported: %w[text/plain text/html])
      expect(view.part).to eq alternative_mail.parts[0]
    end

    it "skips branches with unsupported types" do
      view = described_class.select(alternative_mail, supported: %w[text/plain])
      expect(view.part).to eq alternative_mail.parts[0]
    end

    it "returns a decidable unsupported result when nothing is displayable" do
      view = described_class.select(alternative_mail, supported: %w[application/pdf])
      expect(view.status).to eq :unsupported
      expect(view).to be_unsupported
      expect(view.part).to be_nil
      expect(view.path).to be_nil
      expect(view.mime_path).to be_nil
      expect(view.resources).to eq({})
    end

    it "picks the first displayable branch of a multipart/mixed" do
      mail = mail_for(<<~MAIL)
        Content-Type: multipart/mixed; boundary=mix

        --mix
        Content-Type: application/pdf
        Content-Disposition: attachment; filename=doc.pdf

        PDFDATA
        --mix
        Content-Type: text/plain

        first text
        --mix
        Content-Type: text/html

        <b>second</b>
        --mix--
      MAIL
      view = described_class.select(mail)
      expect(view.part).to eq mail.parts[1]
      expect(view.path).to eq [1]
    end
  end

  describe "multipart/related" do
    let(:related_mail) do
      mail_for(<<~MAIL)
        Content-Type: multipart/related; boundary=rel; start="<root@example.com>"

        --rel
        Content-Type: image/png
        Content-ID: <logo@example.com>
        Content-Transfer-Encoding: base64

        aGVsbG8=
        --rel
        Content-Type: text/html
        Content-ID: <root@example.com>

        <html><body><img src="cid:logo@example.com"></body></html>
        --rel--
      MAIL
    end

    it "uses the start parameter to find the root part" do
      view = described_class.select(related_mail)
      expect(view).to be_ok
      expect(view.part).to eq related_mail.parts[1]
      expect(view.path).to eq [1]
      expect(view.mime_path).to eq %w[multipart/related text/html]
    end

    it "maps the related parts as addressable resources" do
      view = described_class.select(related_mail)
      expect(view.resources.keys).to match_array %w[logo@example.com root@example.com]
      expect(view.resources["logo@example.com"]).to eq related_mail.parts[0]
      expect(view.resource_paths["logo@example.com"]).to eq [0]
    end

    it "resolves cid URLs to resource parts" do
      view = described_class.select(related_mail)
      expect(view.resolve_cid("cid:logo@example.com")).to eq related_mail.parts[0]
      expect(view.resolve_cid("CID:logo@example.com")).to eq related_mail.parts[0]
      expect(view.resolve_cid("cid:unknown@example.com")).to be_nil
      expect(view.resolve_cid("https://example.com/x.png")).to be_nil
    end

    it "defaults the root to the first part when start is absent" do
      mail = mail_for(<<~MAIL)
        Content-Type: multipart/related; boundary=rel

        --rel
        Content-Type: text/html

        <b>root</b>
        --rel
        Content-Type: image/png
        Content-ID: <logo@example.com>

        PNG
        --rel--
      MAIL
      view = described_class.select(mail)
      expect(view).to be_ok
      expect(view.part).to eq mail.parts[0]
    end

    it "reports a start parameter that names no part and falls back to the first part" do
      mail = mail_for(<<~MAIL)
        Content-Type: multipart/related; boundary=rel; start="<missing@example.com>"

        --rel
        Content-Type: text/html

        <b>fallback root</b>
        --rel
        Content-Type: image/png
        Content-ID: <logo@example.com>

        PNG
        --rel--
      MAIL
      view = described_class.select(mail)
      expect(view.status).to eq :missing_start
      expect(view).to be_missing_start
      expect(view.part).to eq mail.parts[0]
      expect(view.path).to eq [0]
      expect(view.missing_starts.length).to eq 1
      expect(view.missing_starts.first.start).to eq "<missing@example.com>"
      expect(view.missing_starts.first.scope_path).to eq []
    end
  end

  describe "duplicate Content-IDs" do
    let(:duplicate_mail) do
      mail_for(<<~MAIL)
        Content-Type: multipart/related; boundary=rel

        --rel
        Content-Type: text/html
        Content-ID: <root@example.com>

        <b>root</b>
        --rel
        Content-Type: image/png
        Content-ID: <dup@example.com>

        PNG
        --rel
        Content-Type: image/gif
        Content-ID: <dup@example.com>

        GIF
        --rel--
      MAIL
    end

    it "reports the ambiguity within its scope instead of silently picking the first" do
      view = described_class.select(duplicate_mail)
      expect(view.ambiguities.length).to eq 1
      ambiguity = view.ambiguities.first
      expect(ambiguity.content_id).to eq "dup@example.com"
      expect(ambiguity.scope_path).to eq []
      expect(ambiguity.paths).to eq [[1], [2]]
    end

    it "excludes ambiguous ids from the resource map" do
      view = described_class.select(duplicate_mail)
      expect(view.resources.keys).to eq %w[root@example.com]
    end

    it "raises when resolving an ambiguous cid URL" do
      view = described_class.select(duplicate_mail)
      expect { view.resolve_cid("cid:dup@example.com") }.
        to raise_error(Mail::BodyView::AmbiguousContentIdError, /dup@example\.com/)
      expect(view.resolve_cid("cid:root@example.com")).to eq duplicate_mail.parts[0]
    end
  end

  describe "cid URL escaping" do
    it "escapes and unescapes ids by a well defined round trip" do
      mail = mail_for(<<~MAIL)
        Content-Type: multipart/related; boundary=rel

        --rel
        Content-Type: text/html

        <b>root</b>
        --rel
        Content-Type: image/png
        Content-ID: <bildüö@example.com>

        PNG
        --rel--
      MAIL
      part = mail.parts[1]
      url = described_class.cid_url_for(part)
      expect(url).to eq "cid:bild%C3%BC%C3%B6@example.com"
      expect(described_class.cid_url_to_id(url)).to eq "bildüö@example.com"

      view = described_class.select(mail)
      expect(view.resolve_cid(url)).to eq part
    end

    it "returns nil from cid_url_for without generating a Content-ID" do
      part = Mail::Part.new(content_type: "image/png")
      expect(described_class.cid_url_for(part)).to be_nil
      expect(part.has_content_id?).to be false
    end

    it "returns nil for non cid URLs" do
      expect(described_class.cid_url_to_id("http://example.com")).to be_nil
      expect(described_class.cid_url_to_id(nil)).to be_nil
    end
  end

  describe "nested structures with a forwarded message attachment" do
    let(:nested_mail) do
      mail_for(<<~MAIL)
        Content-Type: multipart/mixed; boundary=mix

        --mix
        Content-Type: multipart/related; boundary=rel

        --rel
        Content-Type: multipart/alternative; boundary=alt

        --alt
        Content-Type: text/plain

        plain body
        --alt
        Content-Type: text/html

        <html><body><img src="cid:logo@example.com"></body></html>
        --alt--
        --rel
        Content-Type: image/png
        Content-ID: <logo@example.com>

        PNG
        --rel--
        --mix
        Content-Type: message/rfc822
        Content-Disposition: attachment

        Content-Type: multipart/related; boundary=fwdrel
        Subject: forwarded

        --fwdrel
        Content-Type: text/html

        <html><body><img src="cid:inner-img@example.com"></body></html>
        --fwdrel
        Content-Type: image/png
        Content-ID: <inner-img@example.com>

        INNERPNG
        --fwdrel--
        --mix--
      MAIL
    end

    it "selects the outer body with its full MIME path" do
      view = described_class.select(nested_mail)
      expect(view).to be_ok
      expect(view.part).to eq nested_mail.parts[0].parts[0].parts[1]
      expect(view.path).to eq [0, 0, 1]
      expect(view.mime_path).to eq %w[multipart/mixed multipart/related multipart/alternative text/html]
    end

    it "collects only the resources of the outer related scope" do
      view = described_class.select(nested_mail)
      expect(view.resources.keys).to eq %w[logo@example.com]
      expect(view.resources["logo@example.com"]).to eq nested_mail.parts[0].parts[1]
    end

    it "does not leak Content-IDs from the forwarded message into the outer scope" do
      view = described_class.select(nested_mail)
      expect(view.resolve_cid("cid:inner-img@example.com")).to be_nil
      expect(view.resources).not_to have_key("inner-img@example.com")
    end

    it "never selects a nested message/rfc822 as the body" do
      mail = mail_for(<<~MAIL)
        Content-Type: multipart/mixed; boundary=mix

        --mix
        Content-Type: text/plain

        outer plain
        --mix
        Content-Type: message/rfc822
        Content-Disposition: attachment

        Content-Type: text/html

        <b>forwarded html</b>
        --mix--
      MAIL
      view = described_class.select(mail, supported: %w[text/html text/plain message/rfc822])
      expect(view.part).to eq mail.parts[0]
      expect(view.path).to eq [0]
    end
  end

  describe "nested related scopes" do
    it "lets the innermost scope win without reporting an ambiguity" do
      mail = mail_for(<<~MAIL)
        Content-Type: multipart/related; boundary=outer

        --outer
        Content-Type: multipart/related; boundary=inner
        Content-ID: <shared@example.com>

        --inner
        Content-Type: text/html

        <b>root</b>
        --inner
        Content-Type: image/png
        Content-ID: <shared@example.com>

        INNER
        --inner--
        --outer
        Content-Type: image/gif
        Content-ID: <outer-only@example.com>

        GIF
        --outer--
      MAIL
      view = described_class.select(mail)
      expect(view.ambiguities).to be_empty
      expect(view.resources["shared@example.com"]).to eq mail.parts[0].parts[1]
      expect(view.resources["outer-only@example.com"]).to eq mail.parts[1]
    end
  end

  describe "read only behaviour" do
    it "does not reorder parts, generate Content-IDs or change the message" do
      mail = mail_for(<<~MAIL)
        Content-Type: multipart/related; boundary=rel

        --rel
        Content-Type: text/html

        <b>root</b>
        --rel
        Content-Type: image/png

        PNG
        --rel--
      MAIL
      part_without_id = mail.parts[1]
      encoded_before = mail.encoded
      order_before = mail.all_parts.map(&:object_id)

      described_class.select(mail)

      expect(mail.all_parts.map(&:object_id)).to eq order_before
      expect(part_without_id.header.has_content_id?).to be false
      expect(mail.encoded).to eq encoded_before
    end
  end

  describe "Mail::Message#body_view" do
    it "is a convenience wrapper around BodyView.select" do
      view = alternative_mail.body_view(prefer: %w[text/html])
      expect(view).to be_a Mail::BodyView::Result
      expect(view.part).to eq alternative_mail.parts[1]
    end
  end
end
