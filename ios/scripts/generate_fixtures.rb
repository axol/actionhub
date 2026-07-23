#!/usr/bin/env ruby
require "rbnacl"
require "base64"
require "json"
require "openssl"

fixtures_directory = File.expand_path("../Tests/Fixtures", __dir__)

phone_seed = "\x01".b * 32
agent_seed = "\x02".b * 32
phone_signing_key = RbNaCl::SigningKey.new(phone_seed)
agent_signing_key = RbNaCl::SigningKey.new(agent_seed)
hmac_key = "fixture-hmac-key"

shared_secret = RbNaCl::GroupElement.new(phone_signing_key.verify_key.to_curve25519_public_key.to_bytes)
                                    .mult(agent_signing_key.to_curve25519_private_key).to_bytes
channel_id = OpenSSL::HMAC.hexdigest("SHA256", shared_secret, "canvas")

request_payload = {
  envelope_type: "request",
  type: "action",
  nonce: "deadbeefdeadbeef",
  title: "Ship the relay?",
  body: { content_type: "html", content: "<h1>Ship the relay?</h1><p>Deploy MessageStore to production — yes/no?</p>" },
  buttons: [
    { label: "Ship it", value: "ship" },
    { label: "Hold", value: "hold" }
  ]
}
request_payload_json = JSON.generate(request_payload)
request_id = OpenSSL::HMAC.hexdigest("SHA256", hmac_key, JSON.generate(request_payload, sort_keys: true))

request_envelope = {
  version: 1,
  signature: Base64.strict_encode64(agent_signing_key.sign(request_payload_json)),
  sender_public_key: Base64.strict_encode64(agent_signing_key.verify_key.to_bytes),
  payload: request_payload_json
}
request_blob = Base64.strict_encode64(
  RbNaCl::Boxes::Sealed.new(phone_signing_key.verify_key.to_curve25519_public_key)
                       .encrypt(JSON.generate(request_envelope))
)

signature_probe_message = "probe-payload-bytes"
phone_probe_signature = Base64.strict_encode64(phone_signing_key.sign(signature_probe_message))

biometric_p256_key = OpenSSL::PKey::EC.generate("prime256v1")
biometric_public_key = Base64.strict_encode64(biometric_p256_key.public_key.to_octet_string(:uncompressed))
biometric_message = ["actionhub-biometric-v1", request_id, "ship", "1702500000000", ""].join("\n")
biometric_signature = Base64.strict_encode64(biometric_p256_key.sign(OpenSSL::Digest.new("SHA256"), biometric_message))

vectors = {
  hmac_key: hmac_key,
  phone_seed: Base64.strict_encode64(phone_seed),
  phone_public_key: Base64.strict_encode64(phone_signing_key.verify_key.to_bytes),
  agent_seed: Base64.strict_encode64(agent_seed),
  agent_public_key: Base64.strict_encode64(agent_signing_key.verify_key.to_bytes),
  channel_id: channel_id,
  request_id: request_id,
  request_payload_json: request_payload_json,
  request_blob: request_blob,
  signature_probe_message: signature_probe_message,
  phone_probe_signature: phone_probe_signature,
  biometric_public_key: biometric_public_key,
  biometric_message: biometric_message,
  biometric_signature: biometric_signature
}

require "fileutils"
FileUtils.mkdir_p(fixtures_directory)
File.write(File.join(fixtures_directory, "vectors.json"), JSON.pretty_generate(vectors))
puts "wrote #{fixtures_directory}/vectors.json"
