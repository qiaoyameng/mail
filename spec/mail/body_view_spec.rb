# frozen_string_literal: true

require "spec_helper"

RSpec.describe Mail::BodyView do
  def build_message(source)
    Mail.new(source.gsub(/\n/, "\r\n"))
  end

  it "selects a supported simple body and reports its tree path" do
    mail = build_message(<<~MESSAGE)
      Content-Type: text/plain

      plain body
    MESSAGE

    result = mail.body_view(%w[text/plain text/html])

    expect(result).to be_ok
    expect(result.part).to eq(mail)
    expect(result.path).to eq([])
    expect(result.mime_path).to eq("")
    expect(result.resources).to eq({})
  end

  it "chooses an alternative branch according to the preference order" do
    mail = build_message(<<~MESSAGE)
      Content-Type: multipart/alternative; boundary="ALT"

      --ALT
      Content-Type: text/plain

      plain body
      --ALT
      Content-Type: text/html

      <p>html body</p>
      --ALT--
    MESSAGE

    result = mail.body_view(%w[text/plain text/html], %w[text/html text/plain])

    expect(result).to be_ok
    expect(result.part.body.decoded).to eq("<p>html body</p>")
    expect(result.path).to eq([2])
    expect(result.mime_path).to eq("2")
  end

  it "maps the related resources referenced by the selected body" do
    mail = build_message(<<~MESSAGE)
      Content-Type: multipart/mixed; boundary="MIX"

      --MIX
      Content-Type: multipart/related; boundary="REL"

      --REL
      Content-Type: multipart/alternative; boundary="ALT"

      --ALT
      Content-Type: text/plain

      plain body
      --ALT
      Content-Type: text/html

      <img src="cid:image%20one">
      --ALT--
      --REL
      Content-Type: image/png
      Content-ID: <image one>

      png data
      --REL--
      --MIX
      Content-Type: application/pdf; name=document.pdf
      Content-Disposition: attachment; filename=document.pdf

      pdf data
      --MIX--
    MESSAGE

    result = mail.body_view(%w[text/html], %w[text/html])
    image = mail.parts[0].parts[1]

    expect(result).to be_ok
    expect(result.part).to eq(mail.parts[0].parts[0].parts[1])
    expect(result.path).to eq([1, 1, 2])
    expect(result.resources.keys).to eq(["cid:image%20one"])
    expect(result.resources["cid:image%20one"]).to eq(image)
    expect(result.resource_paths["cid:image%20one"]).to eq([1, 2])
    expect(result.resource_mime_paths["cid:image%20one"]).to eq("1.2")
  end

  it "uses the multipart/related start parameter to select the root part" do
    mail = build_message(<<~MESSAGE)
      Content-Type: multipart/related; boundary="REL"; start="<html@example.com>"

      --REL
      Content-Type: image/png
      Content-ID: <image@example.com>

      png data
      --REL
      Content-Type: text/html
      Content-ID: <html@example.com>

      <p>root</p>
      --REL--
    MESSAGE

    result = mail.body_view(%w[text/html])

    expect(result).to be_ok
    expect(result.part).to eq(mail.parts[1])
    expect(result.path).to eq([2])
    expect(result.resources).to eq({})
  end

  it "normalizes an encoded cid start target before matching Content-IDs" do
    mail = build_message(<<~MESSAGE)
      Content-Type: multipart/related; boundary="REL"; start="cid:image%20one"

      --REL
      Content-Type: image/png
      Content-ID: <image other>

      png data
      --REL
      Content-Type: text/html
      Content-ID: <image one>

      <p>root</p>
      --REL--
    MESSAGE

    result = mail.body_view(%w[text/html])

    expect(result).to be_ok
    expect(result.part).to eq(mail.parts[1])
    expect(result.path).to eq([2])
  end

  it "falls back to a supported alternative when no preferred type is available" do
    mail = build_message(<<~MESSAGE)
      Content-Type: multipart/alternative; boundary="ALT"

      --ALT
      Content-Type: text/enriched

      enriched body
      --ALT
      Content-Type: image/png

      png data
      --ALT--
    MESSAGE

    result = mail.body_view(%w[text/html text/enriched], %w[text/html])

    expect(result).to be_ok
    expect(result.part).to eq(mail.parts[0])
    expect(result.path).to eq([1])
  end

  it "keeps nested multipart/related Content-IDs in separate scopes" do
    mail = build_message(<<~MESSAGE)
      Content-Type: multipart/related; boundary="OUT"

      --OUT
      Content-Type: multipart/related; boundary="IN"

      --IN
      Content-Type: text/html

      <img src="cid:shared@example.com">
      --IN
      Content-Type: image/png
      Content-ID: <shared@example.com>

      inner image
      --IN--
      --OUT
      Content-Type: image/gif
      Content-ID: <shared@example.com>

      outer image
      --OUT--
    MESSAGE

    result = mail.body_view(%w[text/html])

    expect(result).to be_ok
    expect(result.path).to eq([1, 1])
    expect(result.resources["cid:shared@example.com"]).to eq(mail.parts[0].parts[1])
    expect(result.resource_paths["cid:shared@example.com"]).to eq([1, 2])
    expect(result.resource_mime_paths["cid:shared@example.com"]).to eq("1.2")
  end

  it "reports a missing related start target" do
    mail = build_message(<<~MESSAGE)
      Content-Type: multipart/related; boundary="REL"; start="<missing@example.com>"

      --REL
      Content-Type: text/html

      <p>root</p>
      --REL--
    MESSAGE

    result = mail.body_view(%w[text/html])

    expect(result).not_to be_ok
    expect(result.status).to eq(:missing_start)
    expect(result.scope_part).to eq(mail)
    expect(result.scope_path).to eq([])
    expect(result.content_id).to eq("missing@example.com")
    expect(result.part).to be_nil
  end

  it "reports duplicate resource Content-IDs within the related scope" do
    mail = build_message(<<~MESSAGE)
      Content-Type: multipart/related; boundary="REL"

      --REL
      Content-Type: text/html

      <img src="cid:image@example.com">
      --REL
      Content-Type: image/png
      Content-ID: <image@example.com>

      first
      --REL
      Content-Type: image/gif
      Content-ID: <image@example.com>

      second
      --REL--
    MESSAGE

    result = mail.body_view(%w[text/html])

    expect(result.status).to eq(:ambiguous_content_id)
    expect(result.scope_part).to eq(mail)
    expect(result.scope_path).to eq([])
    expect(result.content_id).to eq("image@example.com")
    expect(result.candidate_paths).to eq([[2], [3]])
    expect(result.part).to be_nil
  end

  it "reports ambiguity when the start parameter matches more than one part" do
    mail = build_message(<<~MESSAGE)
      Content-Type: multipart/related; boundary="REL"; start="<shared@example.com>"

      --REL
      Content-Type: text/html
      Content-ID: <shared@example.com>

      first
      --REL
      Content-Type: text/plain
      Content-ID: <shared@example.com>

      second
      --REL--
    MESSAGE

    result = mail.body_view(%w[text/plain text/html])

    expect(result.status).to eq(:ambiguous_start)
    expect(result.content_id).to eq("shared@example.com")
    expect(result.candidate_paths).to eq([[1], [2]])
  end

  it "returns an unsupported result when no displayable media type is available" do
    mail = build_message(<<~MESSAGE)
      Content-Type: multipart/mixed; boundary="MIX"

      --MIX
      Content-Type: application/json

      {}
      --MIX
      Content-Type: application/pdf; name=document.pdf
      Content-Disposition: attachment; filename=document.pdf

      pdf data
      --MIX--
    MESSAGE

    result = mail.body_view(%w[text/html text/plain])

    expect(result).not_to be_ok
    expect(result.status).to eq(:unsupported_media_type)
    expect(result.part).to be_nil
    expect(result.resources).to eq({})
  end

  it "does not select bodies or resources from an attached forwarded message" do
    mail = build_message(<<~MESSAGE)
      Content-Type: multipart/mixed; boundary="MIX"

      --MIX
      Content-Type: multipart/related; boundary="REL"

      --REL
      Content-Type: text/html

      <img src="cid:image@example.com">
      --REL
      Content-Type: image/png
      Content-ID: <image@example.com>

      outer image
      --REL--
      --MIX
      Content-Type: message/rfc822; name=forwarded.eml
      Content-Disposition: attachment; filename=forwarded.eml

      Content-Type: multipart/related; boundary="NREL"

      --NREL
      Content-Type: text/html

      <img src="cid:image@example.com">
      --NREL
      Content-Type: image/gif
      Content-ID: <image@example.com>

      nested image
      --NREL--
      --MIX--
    MESSAGE

    result = mail.body_view(%w[text/html])

    expect(result).to be_ok
    expect(result.part).to eq(mail.parts[0].parts[0])
    expect(result.resources.keys).to eq(["cid:image@example.com"])
    expect(result.resources["cid:image@example.com"]).to eq(mail.parts[0].parts[1])
    expect(result.resource_paths["cid:image@example.com"]).to eq([1, 2])
    expect(result.resource_mime_paths["cid:image@example.com"]).to eq("1.2")
  end

  it "is read-only with respect to parts and Content-IDs" do
    source = <<~MESSAGE
      Content-Type: multipart/related; boundary="REL"

      --REL
      Content-Type: multipart/alternative; boundary="ALT"

      --ALT
      Content-Type: text/plain

      plain
      --ALT
      Content-Type: text/html

      <p>html</p>
      --ALT--
      --REL
      Content-Type: image/png
      Content-ID: <image@example.com>

      png
      --REL--
    MESSAGE
    mail = build_message(source)

    expect {
      mail.body_view(%w[text/html])
    }.not_to change { [mail.parts.map(&:object_id), mail.to_s] }

    expect(mail.all_parts.none? { |part| part.header.has_content_id? && part.content_id.nil? }).to be(true)
  end
end
